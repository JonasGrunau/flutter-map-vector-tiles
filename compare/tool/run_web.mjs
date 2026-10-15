// Opens the app once per queued run, each time in a fresh browser context,
// until the lab server's queue is empty. Driven by run_web.sh.
import { chromium } from 'playwright';

const lab = process.argv[2] ?? 'http://localhost:8790';
const status = async () => (await fetch(`${lab}/_status`)).json();
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// Headed: headless Chrome renders on SwiftShader, which measures the CPU,
// not the GPU a user has.
const browser = await chromium.launch({ channel: 'chrome', headless: false });
try {
  for (;;) {
    const before = await status();
    if (before.pending.length === 0 && before.running.length === 0) break;
    if (before.pending.length === 0) {
      // Only a run whose page crashed is left; the lab server gives it up
      // after --run-timeout. A new page would find nothing to run.
      await sleep(2000);
      continue;
    }
    const context = await browser.newContext({
      viewport: { width: 1000, height: 800 },
      deviceScaleFactor: 2,
    });
    const page = await context.newPage();
    page.on('pageerror', (e) => console.error('pageerror:', e.message));
    await page.goto(`${lab}/app/?lab=${encodeURIComponent(lab)}`);
    // One page load is one run: wait until it is reported done, rather
    // than guessing how long the page takes to start.
    const deadline = Date.now() + 15 * 60 * 1000;
    while ((await status()).done.length === before.done.length) {
      if (Date.now() > deadline) throw new Error('run did not finish in 15 min');
      await sleep(2000);
    }
    await context.close();
  }
} finally {
  await browser.close();
}
