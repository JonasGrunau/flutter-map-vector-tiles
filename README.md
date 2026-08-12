# 🗺️ flutter_map_vector_tiles

[![pub package](https://img.shields.io/pub/v/flutter_map_vector_tiles.svg)](https://pub.dev/packages/flutter_map_vector_tiles)
[![license: BSD-3-Clause](https://img.shields.io/badge/license-BSD--3--Clause-blue.svg)](LICENSE)
[![flutter_map](https://img.shields.io/badge/flutter__map-%E2%89%A5%208.2-green.svg)](https://pub.dev/packages/flutter_map)

**Vector tiles for [`flutter_map`](https://pub.dev/packages/flutter_map).**
A clean, self-contained rewrite of the ideas behind
[`vector_map_tiles`](https://pub.dev/packages/vector_map_tiles) —
built for flutter_map ≥ 8 and modern Flutter (Impeller).

Render MapLibre / Mapbox GL styles (MapTiler, OpenFreeMap, OpenMapTiles,
Stadia, Protomaps, …) straight from MVT vector tile sources — as a plain
flutter_map layer. flutter_map keeps owning the camera, gestures and all
your other layers; this package only draws the map.

---

## ✨ Why this package?

| | |
|---|---|
| 📦 **One package** | MVT decoding, style engine and renderer in a single dependency — no renderer/cache/executor satellites |
| 🚀 **Smooth interaction** | Geometry is rasterized **once** per tile into GPU-resident images (`Picture.toImageSync`); pan, zoom and rotate are just textured quads |
| 🔍 **Crisp labels** | Text & icons are drawn per-frame in screen space: upright under rotation, sharp at fractional zoom, with **one global collision pass** — no duplicated or clipped labels at tile seams |
| 🌫️ **No white flashes** | New tiles fade in while ancestor imagery is kept underneath; fast zoom-ins render instantly from already-decoded parent tiles |
| 🎚️ **Correct MapLibre zoom semantics** | The default `TileOffset.maplibre` renders 512px-convention styles *exactly* as their authors designed them |
| 🧵 **Isolate pipeline** | Tiles are decoded & trimmed on a worker-isolate pool (a yielding event-loop queue on web), viewport-centre first; cancellation is a state, **never an exception** in your crash reporting |
| 💾 **Deterministic caching** | LRU memory caches with byte budgets + a size-capped disk cache with no index files to corrupt; every `ui.Image` is disposed on eviction |
| ✈️ **Works offline** | The style bundle and recently viewed tiles are cached on disk (native platforms): places you visited keep rendering with no network at all |
| 🌐 **All six platforms** | Android, iOS, macOS, Linux, Windows and web — see [Web support](#-web-support) for what differs in the browser |
| 🛡️ **Tolerant style reader** | Unknown layer types and exotic expressions degrade per-layer with a warning — one weird layer never kills your whole map |

## 🚀 Quick start

### 1. Install

```yaml
dependencies:
  flutter_map: ^8.2.0
  flutter_map_vector_tiles: ^2.4.0
```

### 2. Load a style & drop in the layer

```dart
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_vector_tiles/flutter_map_vector_tiles.dart' as vt;
import 'package:latlong2/latlong.dart';

// Load the style once — MapTiler shown, any MapLibre style URL works.
final style = await vt.StyleReader(
  uri: 'https://api.maptiler.com/maps/streets-v2/style.json?key={key}',
  apiKey: myMapTilerKey,
).read();

// Use it like any other flutter_map layer:
FlutterMap(
  options: MapOptions(
    initialCenter: style.center ?? const LatLng(48.137, 11.575),
    initialZoom: style.zoom ?? 12,
    maxZoom: 21,
  ),
  children: [
    vt.VectorTileLayer(
      theme: style.theme,
      tileProviders: style.providers,
      rasterSources: style.rasterSources,
      sprites: style.sprites,
    ),
    // Show what the style's sources ask for — most providers require it.
    SimpleAttributionWidget(
      source: Text(style.attributions.map((a) => a.text).join(' · ')),
    ),
    // ...your markers, polylines, etc.
  ],
);
```

`style.attributions` comes pre-parsed: every entry pairs the flattened
`text` (shown above) with `spans`, whose runs keep the `url` of the
`<a>` tag they came from — build from those when your provider's terms
call for *tappable* attribution links.

### 3. Clean up

```dart
@override
void dispose() {
  style.dispose(); // releases HTTP clients & sprite images
  super.dispose();
}
```

▶️ A runnable app lives in [`example/`](example):

```bash
cd example
flutter run --dart-define=MAPTILER_KEY=yourKey
```

## 🌍 Tested style providers

| Provider | Style URL shape | Notes |
|---|---|---|
| 🟢 [MapTiler](https://maptiler.com) | `https://api.maptiler.com/maps/<mapId>/style.json?key={key}` | works with custom map styles |
| 🟢 [OpenFreeMap](https://openfreemap.org) | `https://tiles.openfreemap.org/styles/liberty` | free, no key needed |
| 🟢 [Stadia Maps](https://stadiamaps.com) | `https://tiles.stadiamaps.com/styles/osm_bright.json?api_key={key}` | |
| 🟢 ArcGIS / Esri | `https://…/VectorTileServer/resources/styles/root.json` | relative `../../` sources, `tile/{z}/{y}/{x}` templates and sprites resolve correctly — verified against `World_Basemap_v2` |
| 🟢 Self-hosted (TileServer GL, Martin, …) | any MapLibre `style.json` | verified against the MapLibre demo tiles; relative tile templates supported |
| 🟢 [Protomaps](https://protomaps.com) hosted API | `https://api.protomaps.com/styles/v5/light/en.json?key={key}` | verified against the v5 `light` style; the style embeds the key in an absolute `…/tiles/v4/{z}/{x}/{y}.mvt?key=…` template. On web, allow-list your origin per key in the Protomaps account portal — `localhost` is exempt |
| 🟢 [PMTiles](https://docs.protomaps.com/pmtiles/) archives | `pmtiles://https://…/planet.pmtiles` source URLs in any style | single-file archives served via HTTP range requests — verified against the Protomaps sample archives; gzip-internal archives only (brotli/zstd are rejected) |

The reader is tolerant either way: unsupported layer types, paint
properties and expressions are skipped per-layer with a warning — one
weird layer never kills the whole style.

## ⚙️ Configuration

Everything has sensible defaults — override what you need:

```dart
vt.VectorTileLayer(
  theme: style.theme,
  tileProviders: style.providers,
  rasterSources: style.rasterSources,          // satellite/hybrid imagery
  sprites: style.sprites,
  tileOffset: vt.TileOffset.maplibre,          // 512px style convention (default)
  concurrency: 3,                              // decoding isolates
  diskCacheMaximumSizeInBytes: 50 * 1024 * 1024,
  diskCacheTtl: const Duration(days: 14),
  memoryCacheMaxBytes: 24 * 1024 * 1024,
  rasterCacheMaxBytes: 64 * 1024 * 1024,
  tileFadeDuration: const Duration(milliseconds: 150),
  labelFadeDuration: const Duration(milliseconds: 150),
  showLabels: true,
  logger: const vt.Logger.console(),           // see style warnings in debug
)
```

| Parameter | Default | What it does |
|---|---|---|
| `tileOffset` | `TileOffset.maplibre` | zoom relation between map and style — see below 👇 |
| `concurrency` | `3` | worker isolates decoding tiles off the UI thread (ignored on web) |
| `diskCacheMaximumSizeInBytes` | 50 MB | `0` disables disk caching (no effect on web) |
| `diskCacheTtl` | 14 days | freshness window: younger tiles skip the network; older ones still paint instantly and are refreshed in the background — ⚠️ respect your tile provider's terms |
| `cachePath` | app support dir | supply your own directory path to control/clear it (ignored on web) |
| `memoryCacheMaxBytes` | 24 MB | decoded tile budget per source (the caches are shared process-wide; the most recently mounted layer's value wins) |
| `rasterCacheMaxBytes` | 64 MB | finished-tile budget: zooming back to a recent level (or reopening the same style) paints instantly instead of re-rendering. GPU texture bytes — ~1 MB per tile at devicePixelRatio 2, ~2.25 MB at 3, so the default holds ≈2 phone-screen zoom levels at dpr 2 (≈1 at dpr 3). `0` disables |
| `tileFadeDuration` | 150 ms | `Duration.zero` disables fade-in |
| `labelFadeDuration` | 150 ms | fade-in of newly appearing labels/icons (masks the pop at the zoom where symbols start). Labels carried over from the previous zoom level are not re-faded, so crossing a zoom level does not blink them; `Duration.zero` restores the instant pop |
| `showLabels` | `true` | disables the whole symbol pass when `false`; toggling it re-lays-out the tiles already on screen |

The memory caches are shared process-wide and outlive the layer — that's
why reopening a map paints instantly instead of decoding everything
again. If those budgets are too generous under memory pressure, the
static `VectorTileLayer.clearMemoryCache()` releases them (decoded
tiles, raster-source images and finished tiles alike; the disk cache is
untouched). Call it from a memory-pressure handler such as
`WidgetsBindingObserver.didHaveMemoryPressure` — visible maps keep their
imagery, only tiles panned to afterwards are re-read from disk.

`StyleReader` options worth knowing:

- `apiKey` — substituted for `{key}` in the style URI and every URL the
  style references. For `mapbox://` URIs (style ids, sprite bases,
  tileset sources — expanded to `api.mapbox.com` automatically) it
  becomes the access token.
- `headers` — extra HTTP headers sent with the style, TileJSON and
  sprite requests and forwarded to the created tile providers, for
  header-authenticated services (e.g. `Authorization`).
- `httpClient` — bring your own `http.Client` (proxying, certificate
  pinning, tests); a passed client stays yours and is never closed for
  you.

### 🎚️ Understanding `TileOffset`

MapLibre renders 512px tiles, so at the same visual scale a MapLibre zoom
is **one lower** than flutter_map's.
Styles from MapTiler & friends are authored against that convention.

- `TileOffset.maplibre` *(default)* — text sizes, road widths and layer
  zoom ranges match the style author's intent exactly.
- `TileOffset.none` — evaluates the style at flutter_map's zoom directly;
  everything appears one zoom earlier/larger (the legacy
  `vector_map_tiles` default,
  if you need visual parity with it).

## ✈️ Offline behaviour

Everything you looked at recently keeps working without network:

- **Style bundle** — `StyleReader` caches style.json, TileJSON and
  sprites on disk (stale-while-revalidate): the cached copy is served
  instantly — including fully offline — and refreshed in the background
  once older than `refreshAfter` (12 h default). Opt out with
  `StyleReader(cache: false)`.
- **Tiles** — served from the disk cache while fresh; once older than
  `diskCacheTtl` they still paint instantly and are revalidated in the
  background (stale-while-revalidate): changed tiles cross-fade to the
  new imagery, and when the network is unavailable the old tile simply
  stays. Stale tiles are only ever deleted by the size cap (oldest
  first), never by age alone.
- **Durable location** — both caches default to the application support
  directory, which the OS doesn't purge (unlike the temp directory).

This is a *visited-places* cache, not region pre-download. For
guaranteed offline regions, bundle tiles and serve them through the
`VectorTileProvider` interface (e.g. MBTiles/PMTiles) alongside an
`asset://` style.

Disk caching — and with it the offline behaviour above — is native-only;
see [Web support](#-web-support) for what applies in the browser.

## 🌐 Web support

The layer runs on Flutter web with the CanvasKit/Skwasm renderer — the
default since Flutter 3.29. (Do not force the removed HTML renderer on
Flutter 3.27/3.28: it lacks `Picture.toImageSync`.) What differs from
native:

- **No persistent cache** — `cachePath`, `diskCacheTtl`,
  `diskCacheMaximumSizeInBytes` and `StyleReader(cache: …)` are no-ops.
  Tiles and the style bundle rely on the in-memory caches plus the
  browser's own HTTP cache instead.
- **Decoding runs on the event loop** — a yielding queue replaces the
  worker-isolate pool (`concurrency` is ignored).
- **CORS** — the browser fetches style.json, TileJSON, sprites and tiles
  directly, so every host involved must send
  `Access-Control-Allow-Origin`. MapTiler, OpenFreeMap and Stadia do;
  self-hosted tile servers need it configured. PMTiles archive hosts
  additionally need range requests to pass CORS (`Range` in
  `Access-Control-Allow-Headers` when preflighted).
- **PMTiles gunzip** uses the browser's native `DecompressionStream`
  (available in every browser that runs Flutter web).

## 🔌 Custom tile sources

No style URL? Any `{z}/{x}/{y}` MVT endpoint works — build the theme
yourself and wire providers manually:

```dart
vt.VectorTileLayer(
  theme: vt.ThemeReader(logger: const vt.Logger.console()).read(myStyleJson),
  tileProviders: vt.TileProviders({
    'openmaptiles': vt.NetworkVectorTileProvider(
      urlTemplate: 'https://tiles.example.com/{z}/{x}/{y}.pbf?key=$key',
      maximumZoom: 14, // the source's max — higher zooms overzoom this data
    ),
  }),
)
```

The sample shows the two options you'll always set;
`NetworkVectorTileProvider` also takes `headers` (header-authenticated
tile servers), `minimumZoom`, `maxRetries` (default 2) and an optional
`client` if you bring your own `http.Client` — a passed client is
shared and never closed for you.

**PMTiles** single-file archives work out of the box: styles with
`pmtiles://https://…/planet.pmtiles` source URLs just load, or open an
archive directly:

```dart
final provider = await vt.PmTilesVectorTileProvider.open(
  'https://tiles.example.com/planet.pmtiles',
);
// → vt.TileProviders({'mySource': provider})
```

`open` likewise accepts `headers`, `maxRetries`, a shared `client`, and
`minimumZoom`/`maximumZoom` to override the archive header — the same
role a style source's `minzoom`/`maxzoom` plays.

Raster imagery (satellite, hillshade) wires up the same way: pass
`rasterSources:` entries of `RasterTileSource(provider: …, tileSize:
512)`, where the provider serves encoded PNG/JPEG/WebP bytes instead of
MVT — `NetworkVectorTileProvider` works unchanged. 256px sources are
fetched one zoom level deeper for the same visual scale.

There's also `MemoryVectorTileProvider` (tests, bundled offline regions)
and a small `VectorTileProvider` interface for anything else
(MBTiles, …).

## 🎨 Style support

**Layer types:** `background`, `fill` (incl. `fill-pattern`), `line`
(incl. `line-pattern`, dashes, casing), `symbol` (incl. curved line
text, `text-variable-anchor` / `text-radial-offset`), `circle`, and
`raster` — raster sources inside vector styles (satellite/hybrid
imagery) draw at their layer position with `raster-opacity`,
brightness/contrast/saturation/hue-rotate matching MapLibre's shader
math (`fill-extrusion` renders as flat fill; `hillshade`, `heatmap` and
`sky` are skipped with a log line).

**Icons:** SDF sprite sheets (`"sdf": true`) are thresholded and tinted
per `icon-color`, `icon-halo-color` and `icon-halo-width` — dark
MapLibre styles ship their icons this way. Ordinary sprites are drawn
with the colours baked into the sheet.

Road labels curve glyph-by-glyph along their line with MapLibre
semantics: `text-max-angle` rejects labels on sharp bends,
`text-keep-upright` flips reading direction, and
`text-rotation-alignment: viewport` keeps shield text horizontal.
Nearly straight windows are drawn as a single rotated string for speed;
scripts with contextual shaping (Arabic, Indic, …) fall back to straight
placement so glyphs are never mis-joined.

A symbol layer's zoom range is honoured exactly — nothing paints outside
`[minzoom, maxzoom)` — but labels ramp out over the last quarter zoom
level before a declared `maxzoom` rather than snapping away, and ramp
back in when you zoom out across it. `minzoom` stays a hard edge: it is
inclusive, so fading there would leave a `minzoom: 14` layer invisible
on a map sitting at exactly zoom 14. This applies to zoom ranges the
*style* declares; a label the tileset itself stops carrying at higher
zoom still disappears when its tile does.

**Expressions:** the practical MapLibre set — `get`/`has`, comparisons,
`all`/`any`/`case`/`match`/`coalesce`, `step`/`interpolate` (linear,
exponential, cubic-bezier), math, string & color operators, `let`/`var`,
legacy filters, legacy `{stops}` functions and `{token}` templates.

## 🏗️ Architecture

```
style.json ─► StyleReader ─► compiled Theme (expressions → closures)
camera ─► visible display tiles ─► data tiles (shared, LRU-cached)
   bytes ◄─ disk cache ◄─ network        ─► isolate: decode + trim
   PreparedTile ─► rasterize once ─► GPU image ─► textured quad per frame
   symbols ─────► per-frame screen-space label pass (global collision)
   finished tiles (image + symbols) ─► shared LRU ─► instant re-crossings
```

Profiling: the render pipeline emits DevTools timeline events
(`VT render pump`, `VT rasterize`, `VT symbols`, `VT labels`).

On web the disk cache tier is absent and decoding runs on a yielding
event-loop queue instead of isolates; everything else is identical.

The full rendering model and the reasoning behind each departure from
[`vector_map_tiles`](https://pub.dev/packages/vector_map_tiles) is
documented in [doc/ARCHITECTURE.md](doc/ARCHITECTURE.md). 📖

## 🆚 [`vector_map_tiles`](https://pub.dev/packages/vector_map_tiles)

| | vector_map_tiles (stable) | this package |
|---|---|---|
| Packages | 3 ([`vector_map_tiles`](https://pub.dev/packages/vector_map_tiles), [`vector_tile_renderer`](https://pub.dev/packages/vector_tile_renderer), [`executor_lib`](https://pub.dev/packages/executor_lib)) + [`stash`](https://pub.dev/packages/stash) caching | 1 |
| Labels | baked into tile rasters / per-tile collision | screen-space pass, global collision, upright text |
| Zoom flicker | white flash on fast zoom ([#147](https://github.com/greensopinion/flutter-vector-map-tiles/issues/147)) | ancestor retention + provisional rendering |
| Cancellation | `CancellationException` reaches crash reporting ([#205](https://github.com/greensopinion/flutter-vector-map-tiles/issues/205)) | a state, never an exception |
| Style zoom | evaluated at flutter_map zoom (1 off vs. MapLibre) | `TileOffset.maplibre` default |
| Rasters | async image encode | `Picture.toImageSync` (stays on GPU) |

## 🐛 Troubleshooting

- **Blank map, no errors** → pass `logger: const vt.Logger.console()` to
  both `StyleReader` and `VectorTileLayer`; most often the style's source
  ids don't match your `TileProviders` keys, or your API key is invalid
  (HTTP 403s are logged, keys redacted).
- **`read()` or `open()` throws** → that's the designed failure path
  for a broken setup: `StyleReader.read()` throws `StyleReaderException`
  when the style can't be loaded or parsed, and
  `PmTilesVectorTileProvider.open` throws `PmTilesException` on an
  invalid or unsupported archive (`http.ClientException` on network
  failure) — catch these to show a retry UI. Runtime tile fetches never
  throw into your code; failures are logged and retried instead.
- **Labels/roads look bigger than in MapLibre** → you're probably using
  `TileOffset.none` with a 512px-convention style; use the default.
- **Stale data after changing styles** → the disk cache keys by URL; a
  changed `{key}` or map id is a different URL, so usually nothing to do.
  Supply `cachePath` if you want to wipe it yourself.
- **Blank map on web** → open the browser console; missing
  `Access-Control-Allow-Origin` headers on the style or tile host block
  every request (see [Web support](#-web-support)).

## 🤝 Contributing

Issues and PRs are welcome! Please run
`dart analyze && flutter test` before submitting — the suite covers the
MVT decoder, expression engine, caches, grid math and tile store. Run
`flutter test --platform chrome` too when touching anything
platform-sensitive (requires Chrome).

## 📄 License

[BSD 3-Clause](LICENSE) © 2026 Jonas Grunau
