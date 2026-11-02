// Renders the fidelity cameras (scenarios.dart `shotPoses`) with MapLibre
// GL JS, through the lab server, at the web runs' viewport.
//
//   node tool/reference_shots.mjs <lab url> <shots dir>
//
// STYLE=<name> renders another style than Liberty, as the app's STYLE
// define does (the lab serves `liberty-heatmap` too).
//
// Keep the poses in sync with `shotPoses` in lib/src/scenarios.dart.
import { chromium } from 'playwright';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const [lab = 'http://localhost:8790', out = 'results/raw/maplibre/shots'] =
  process.argv.slice(2);
const munich = { lat: 48.1374, lon: 11.5755 };
const poses = {
  'munich-z14': { ...munich, zoom: 14 },
  'munich-z16': { ...munich, zoom: 16 },
  'munich-z16-rot45': { ...munich, zoom: 16, rotation: 45 },
  'munich-z17.5': { ...munich, zoom: 17.5 },
  'munich-z18': { ...munich, zoom: 18 },
};

const page = path.join(path.dirname(fileURLToPath(import.meta.url)), 'maplibre.html');
const browser = await chromium.launch({ channel: 'chrome', headless: false });
try {
  for (const [name, pose] of Object.entries(poses)) {
    const context = await browser.newContext({
      viewport: { width: 1000, height: 800 },
      deviceScaleFactor: 2,
    });
    const tab = await context.newPage();
    const params = new URLSearchParams({
      style: `${lab}/r/maplibre/ofm/styles/${process.env.STYLE ?? 'liberty'}`,
      lat: pose.lat,
      lon: pose.lon,
      zoom: pose.zoom,
      rotation: pose.rotation ?? 0,
    });
    await tab.goto(`file://${page}?${params}`);
    await tab.waitForFunction(() => document.title === 'idle', null, { timeout: 60000 });
    await tab.waitForTimeout(500);
    await tab.screenshot({ path: path.join(out, `maplibre-${name}.png`) });
    await context.close();
    console.log(`maplibre-${name}.png`);
  }
} finally {
  await browser.close();
}
