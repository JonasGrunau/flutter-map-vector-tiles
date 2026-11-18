// Takes the README and gallery screenshots of `shot_app.dart` in headless
// Chrome. Run through `capture.sh`, which builds the app first.
//
//     node capture.mjs [shot name ...]     # no names: every shot
//
// Raw PNGs land in `out/` (gitignored); plain shots are converted to
// `../readme/<name>.webp`, framed ones are left for `frame.mjs`.
import { execFileSync } from 'node:child_process';
import { createServer } from 'node:http';
import { mkdirSync, readFileSync, writeFileSync, existsSync } from 'node:fs';
import { dirname, extname, join, normalize } from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';

const here = dirname(fileURLToPath(import.meta.url));
const web = join(here, '../../example/build/web');
const out = join(here, 'out');
const readme = join(here, '../readme');
const port = 8123;

// Portrait shots are the iPhone 17 screen at 2x (1206x2622), the size of
// the bezel's cutout; plain ones are landscape crops for the README.
const phone = { width: 603, height: 1311 };
const plain = { width: 800, height: 500 };

const munich = { lat: 48.1373, lon: 11.5755 };
const manhattan = { lat: 40.7527, lon: -73.9772 };

const shots = [
  {
    name: 'buildings-3d',
    framed: true,
    view: phone,
    query: { style: 'liberty', ...manhattan, zoom: 16.4, extrusion: 'perspective' },
  },
  {
    name: '3d-flat',
    view: plain,
    query: { style: 'liberty', ...manhattan, zoom: 16.4 },
  },
  {
    name: '3d-perspective',
    view: plain,
    query: { style: 'liberty', ...manhattan, zoom: 16.4, extrusion: 'perspective' },
  },
  {
    name: 'heatmap',
    view: plain,
    query: { style: 'liberty-heatmap', ...munich, zoom: 14 },
  },
  {
    name: 'scripts',
    view: plain,
    // Tbilisi: Georgian is one of the scripts the style's glyphs cover.
    query: { style: 'liberty', lat: 41.6925, lon: 44.8075, zoom: 15.6 },
  },
  {
    name: 'query',
    view: plain,
    query: { style: 'liberty', lat: 48.1386, lon: 11.5733, zoom: 17 },
    // The Frauenkirche, at the centre of the view.
    click: { x: 400, y: 250 },
  },
  {
    name: 'label-screen',
    view: plain,
    query: { style: 'liberty', ...munich, zoom: 15, rot: 30 },
  },
  {
    name: 'label-tile',
    view: plain,
    query: { style: 'liberty', ...munich, zoom: 15, rot: 30, labels: 'tile' },
  },
];

// ---- styles: OpenFreeMap's, with compact attribution and the additions
// a shot needs.

const attribution = 'OpenMapTiles © OpenStreetMap';

async function baseStyle(name) {
  const response = await fetch(`https://tiles.openfreemap.org/styles/${name}`);
  if (!response.ok) throw new Error(`style ${name}: ${response.status}`);
  const style = await response.json();
  for (const source of Object.values(style.sources)) {
    source.attribution = source.type === 'vector' ? attribution : '';
  }
  return style;
}

/// A heatmap of the OpenMapTiles `poi` points, above the last layer that
/// is not a symbol layer (as `compare/tool/lab_server.dart` adds it).
function withPoiHeatmap(style) {
  let at = 0;
  style.layers.forEach((layer, i) => {
    if (layer.type !== 'symbol') at = i + 1;
  });
  style.layers.splice(at, 0, {
    id: 'poi-heatmap',
    type: 'heatmap',
    source: 'openmaptiles',
    'source-layer': 'poi',
    paint: {
      'heatmap-weight': ['interpolate', ['linear'], ['coalesce', ['get', 'rank'], 30], 1, 1, 30, 0.25],
      'heatmap-intensity': ['interpolate', ['linear'], ['zoom'], 12, 0.5, 17, 1.5],
      'heatmap-radius': ['interpolate', ['linear'], ['zoom'], 12, 14, 17, 40],
      'heatmap-opacity': 0.8,
    },
  });
  return style;
}

async function writeStyles() {
  const dir = join(web, 'styles');
  mkdirSync(dir, { recursive: true });
  const save = (name, style) =>
    writeFileSync(join(dir, `${name}.json`), JSON.stringify(style));
  save('liberty', await baseStyle('liberty'));
  save('fiord', await baseStyle('fiord'));
  save('liberty-heatmap', withPoiHeatmap(await baseStyle('liberty')));
}

// ---- static server for the web build

const types = {
  '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript',
  '.json': 'application/json', '.wasm': 'application/wasm', '.png': 'image/png',
  '.otf': 'font/otf', '.ttf': 'font/ttf', '.frag': 'application/octet-stream',
};

function serve() {
  return createServer((request, response) => {
    let path = normalize(decodeURIComponent(new URL(request.url, 'http://x').pathname));
    if (path.endsWith('/')) path += 'index.html';
    const file = join(web, path);
    if (!file.startsWith(web) || !existsSync(file)) {
      response.writeHead(404).end();
      return;
    }
    response.writeHead(200, {
      'Content-Type': types[extname(file)] ?? 'application/octet-stream',
    });
    response.end(readFileSync(file));
  }).listen(port);
}

// ---- capture

/// Resolves once no request has been in flight for [quiet] ms.
function networkQuiet(page, quiet, timeout) {
  return new Promise((resolve) => {
    let inflight = 0;
    let timer = setTimeout(resolve, quiet);
    const restart = () => {
      clearTimeout(timer);
      if (inflight <= 0) timer = setTimeout(resolve, quiet);
    };
    page.on('request', () => { inflight++; restart(); });
    const done = () => { inflight--; restart(); };
    page.on('requestfinished', done);
    page.on('requestfailed', done);
    setTimeout(resolve, timeout);
  });
}

async function capture(browser, shot) {
  const context = await browser.newContext({
    viewport: shot.view,
    deviceScaleFactor: 2,
  });
  const page = await context.newPage();
  page.on('console', (message) => {
    if (message.type() === 'error') console.log(`  [${shot.name}] ${message.text()}`);
  });
  const query = new URLSearchParams({
    ...shot.query,
    style: `styles/${shot.query.style}.json`,
  });
  const quiet = networkQuiet(page, 4000, 90000);
  await page.goto(`http://localhost:${port}/?${query}`);
  await quiet;
  if (shot.click) {
    await page.mouse.click(shot.click.x, shot.click.y);
    await page.waitForTimeout(2500);
  }
  // Label fades and the last tiles' cross-fades.
  await page.waitForTimeout(2500);
  const png = join(out, `${shot.name}.png`);
  await page.screenshot({ path: png });
  await context.close();
  if (!shot.framed) {
    execFileSync('cwebp', ['-quiet', '-q', '82', '-m', '6', png, '-o',
      join(readme, `${shot.name}.webp`)]);
  }
  console.log(`${shot.name} -> ${png}`);
}

const wanted = process.argv.slice(2);
const selected = wanted.length ? shots.filter((s) => wanted.includes(s.name)) : shots;
mkdirSync(out, { recursive: true });
mkdirSync(readme, { recursive: true });
await writeStyles();
const server = serve();
const browser = await chromium.launch({ channel: 'chrome', headless: true });
try {
  for (const shot of selected) await capture(browser, shot);
} finally {
  await browser.close();
  server.close();
}
