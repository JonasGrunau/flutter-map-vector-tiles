# 🗺️ flutter_map_vector_tiles

[![pub package](https://img.shields.io/pub/v/flutter_map_vector_tiles.svg)](https://pub.dev/packages/flutter_map_vector_tiles)
[![license: BSD-3-Clause](https://img.shields.io/badge/license-BSD--3--Clause-blue.svg)](LICENSE)
[![flutter_map](https://img.shields.io/badge/flutter__map-%E2%89%A5%208.2-green.svg)](https://pub.dev/packages/flutter_map)

**Vector tiles for [`flutter_map`](https://pub.dev/packages/flutter_map).**
A clean, self-contained rewrite of the ideas behind
[`vector_map_tiles`](https://pub.dev/packages/vector_map_tiles), built for
flutter_map ≥ 8 and modern Flutter (Impeller).

Render MapLibre / Mapbox GL styles (MapTiler, OpenFreeMap, OpenMapTiles,
Stadia, Protomaps, …) straight from MVT sources, as a plain flutter_map
layer. flutter_map keeps owning the camera, gestures and your other
layers; this package only draws the map.

---

## ✨ Why this package?

| | |
|---|---|
| 📦 **One package** | MVT decoding, style engine and renderer in one dependency, with no renderer/cache/executor satellites |
| 🚀 **Smooth interaction** | Geometry is rasterized **once** per tile into GPU-resident images (`Picture.toImageSync`), so pan, zoom and rotate are just textured quads |
| 🔍 **Crisp labels** | Text and icons drawn per frame in screen space: upright under rotation, sharp at fractional zoom, and **one global collision pass**, so nothing is duplicated or clipped at a tile seam |
| 🌫️ **No white flashes** | New tiles fade in over retained ancestor imagery. Fast zoom-ins render from already-decoded parent tiles, zoom-outs compose the decoded children until the new level arrives |
| 🎚️ **Correct MapLibre zoom semantics** | The default `TileOffset.maplibre` renders 512px-convention styles *exactly* as their authors designed them |
| 🧵 **Isolate pipeline** | Tiles decode and trim on a worker-isolate pool (a yielding event-loop queue on web), viewport-centre first. Cancellation is a state, **never an exception** in your crash reporting |
| 💾 **Deterministic caching** | LRU memory caches with byte budgets, plus a size-capped disk cache with no index files to corrupt. Every `ui.Image` is disposed on eviction |
| ✈️ **Works offline** | The style bundle and recently viewed tiles are cached on disk (native), so places you visited keep rendering with no network |
| 🌐 **All six platforms** | Android, iOS, macOS, Linux, Windows and web. See [Web support](#-web-support) for the browser differences |
| 🛡️ **Tolerant style reader** | Unknown layer types and exotic expressions degrade per layer with a warning, so one weird layer never kills your map |

## 🚀 Quick start

### 1. Install

```yaml
dependencies:
  flutter_map: ^8.2.0
  flutter_map_vector_tiles: ^2.8.1
```

### 2. Load a style & drop in the layer

```dart
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_vector_tiles/flutter_map_vector_tiles.dart' as vt;
import 'package:latlong2/latlong.dart';

// Load the style once. MapTiler shown, any MapLibre style URL works.
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
    // Show what the style's sources ask for; most providers require it.
    SimpleAttributionWidget(
      source: Text(style.attributions.map((a) => a.text).join(' · ')),
    ),
    // ...your markers, polylines, etc.
  ],
);
```

`style.attributions` comes pre-parsed: each entry pairs the flattened
`text` shown above with `spans`, whose runs keep the `url` of the `<a>`
tag they came from. Build from those when your provider's terms call for
*tappable* links.

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
| 🟢 ArcGIS / Esri | `https://…/VectorTileServer/resources/styles/root.json` | relative `../../` sources, `tile/{z}/{y}/{x}` templates and sprites all resolve. Verified against `World_Basemap_v2` |
| 🟢 Self-hosted (TileServer GL, Martin, …) | any MapLibre `style.json` | relative tile templates supported. Verified against the MapLibre demo tiles |
| 🟢 [Protomaps](https://protomaps.com) hosted API | `https://api.protomaps.com/styles/v5/light/en.json?key={key}` | verified against the v5 `light` style, which embeds the key in an absolute `…/tiles/v4/{z}/{x}/{y}.mvt?key=…` template. On web, allow-list your origin per key in the Protomaps portal; `localhost` is exempt |
| 🟢 [PMTiles](https://docs.protomaps.com/pmtiles/) archives | `pmtiles://https://…/planet.pmtiles` source URLs in any style | single-file archives over HTTP range requests, verified against the Protomaps samples. Gzip-internal only; brotli and zstd are rejected |
| 🟢 [MBTiles](https://github.com/mapbox/mbtiles-spec) archives | wired up in code via [`flutter_map_vector_tiles_mbtiles`](https://pub.dev/packages/flutter_map_vector_tiles_mbtiles) | local SQLite archives from QGIS, tilemaker or TileServer GL. A companion package, so this one stays free of `dart:ffi`. Native only |

## ⚙️ Configuration

Everything has sensible defaults; override what you need:

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
  // sized for the device by default; a byte count overrides it
  rasterCacheMaxBytes: vt.VectorTileLayer.autoRasterCacheBytes,
  tileFadeDuration: const Duration(milliseconds: 150),
  labelFadeDuration: const Duration(milliseconds: 150),
  showLabels: true,
  logger: const vt.Logger.console(),           // see style warnings in debug
)
```

| Parameter | Default | What it does |
|---|---|---|
| `tileOffset` | `TileOffset.maplibre` | zoom relation between map and style, see below 👇 |
| `concurrency` | `3` | worker isolates decoding tiles off the UI thread (ignored on web) |
| `diskCacheMaximumSizeInBytes` | 50 MB | `0` disables disk caching (no effect on web) |
| `diskCacheTtl` | 14 days | freshness window: younger tiles skip the network, older ones still paint instantly and refresh in the background. ⚠️ Respect your provider's terms |
| `cachePath` | app support dir | your own directory, to control or clear it (ignored on web) |
| `memoryCacheMaxBytes` | 24 MB | decoded tile budget per source. The caches are shared process-wide, so the most recently mounted layer's value wins |
| `rasterCacheMaxBytes` | sized for the device | finished-tile budget: zooming back to a recent level, or reopening the same style, paints instantly instead of re-rendering. These are GPU texture bytes, roughly 1 MB per tile at devicePixelRatio 2 and 2.25 MB at 3, and a phone screenful is 25 to 35 tiles, so a *single* level costs about 80 MB on a large dpr-3 phone. The default measures your viewport and dpr and budgets 2.5 screenfuls, clamped to 64 to 256 MB, so a zoom round trip keeps the level it returns to. Pass a byte count to pin it, or `0` to disable |
| `tileFadeDuration` | 150 ms | fade-in of newly rendered tiles. Tiles from the finished-tile cache fade only when retained imagery lies beneath to cross-fade over; with nothing beneath, as on a reopened map or in the ring a zoom-out exposes, ready imagery appears at once rather than fading over the background. `Duration.zero` disables |
| `labelFadeDuration` | 150 ms | fade of appearing *and* departing labels and icons, one fade state per label identity, so a label carried across a zoom level never re-fades or blinks. Also how often collision is re-decided, capped at 300 ms: camera and candidate changes wait at most one interval, while an unchanged map schedules no further placement work. `Duration.zero` restores instant pops and per-frame collision, and immediately finishes a fade already in progress |
| `showLabels` | `true` | disables the whole symbol pass when `false`; toggling it re-lays-out the tiles already on screen |

The memory caches are shared process-wide and outlive the layer, which is
why reopening a map paints instantly. If those budgets are too generous
under memory pressure, the static `VectorTileLayer.clearMemoryCache()`
releases decoded tiles, raster-source images and finished tiles alike,
leaving the disk cache untouched. Call it from a handler such as
`WidgetsBindingObserver.didHaveMemoryPressure`: visible maps keep their
imagery, and only tiles panned to afterwards are re-read from disk.

The layer manages those caches itself in one case. Coming back from the
background it discards the finished tiles and re-renders, because iOS
revokes GPU access for a backgrounded process and a tile rasterized just
as that happens comes back solid magenta, indistinguishable from a real
image. So it stops rasterizing on the way out and treats what it has as
suspect on the way back in. Recovery costs no network and no decoding,
since the decoded geometry never left memory, and on-screen imagery is
replaced only once the new render is ready.

`StyleReader` also takes:

- `apiKey`, substituted for `{key}` in the style URI and every URL the
  style references. For `mapbox://` URIs (style ids, sprite bases and
  tileset sources, expanded to `api.mapbox.com` automatically) it is the
  access token.
- `headers`, added to the style, TileJSON and sprite requests and
  forwarded to the created tile providers, for header-authenticated
  services such as `Authorization`.
- `httpClient`, your own `http.Client` for proxying, certificate pinning
  or tests. A passed client stays yours and is never closed for you.

### 🎚️ Understanding `TileOffset`

MapLibre renders 512px tiles, so at the same visual scale a MapLibre zoom
is **one lower** than flutter_map's. Styles from MapTiler and friends are
authored against that convention.

- `TileOffset.maplibre` *(default)* matches the author's intent exactly,
  for text sizes, road widths and layer zoom ranges.
- `TileOffset.none` evaluates the style at flutter_map's zoom directly, so
  everything appears one zoom earlier and larger. The legacy
  `vector_map_tiles` default, if you need parity with it.

## ✈️ Offline behaviour

Everything you looked at recently keeps working without network:

- **Style bundle.** `StyleReader` caches style.json, TileJSON and sprites
  on disk, stale-while-revalidate: the cached copy is served instantly,
  including fully offline, and refreshed in the background once older than
  `refreshAfter` (12 h default). Opt out with `StyleReader(cache: false)`.
- **Tiles.** Served from disk while fresh. Past `diskCacheTtl` they still
  paint instantly and revalidate in the background: changed tiles
  cross-fade to the new imagery, and with no network the old tile simply
  stays. Stale tiles are deleted only by the size cap, oldest first, never
  by age alone.
- **Durable location.** Both caches default to the application support
  directory, which the OS doesn't purge, unlike the temp directory.

This is a *visited-places* cache, not region pre-download. For a
guaranteed offline region, ship a tile archive: point
`PmTilesVectorTileProvider` at a `.pmtiles` file, or
[`flutter_map_vector_tiles_mbtiles`](https://pub.dev/packages/flutter_map_vector_tiles_mbtiles)
at a `.mbtiles` one, alongside an `asset://` style. Nothing on that path
touches the network, and a local archive is excluded from the disk cache,
being the local copy already.

Disk caching, and with it everything above, is native-only. See
[Web support](#-web-support) for the browser.

## 🌐 Web support

The layer runs on Flutter web with the CanvasKit/Skwasm renderer, the
default since Flutter 3.29. (Do not force the removed HTML renderer on
Flutter 3.27/3.28: it lacks `Picture.toImageSync`.) What differs from
native:

- **No persistent cache.** `cachePath`, `diskCacheTtl`,
  `diskCacheMaximumSizeInBytes` and `StyleReader(cache: …)` are no-ops.
  Tiles and the style bundle rely on the in-memory caches plus the
  browser's HTTP cache instead.
- **Decoding runs on the event loop.** A yielding queue replaces the
  worker-isolate pool, and `concurrency` is ignored.
- **CORS.** The browser fetches style.json, TileJSON, sprites and tiles
  directly, so every host involved must send
  `Access-Control-Allow-Origin`. MapTiler, OpenFreeMap and Stadia do;
  self-hosted tile servers need it configured. PMTiles hosts additionally
  need range requests to pass CORS, meaning `Range` in
  `Access-Control-Allow-Headers` when preflighted.
- **PMTiles gunzip** uses the browser's native `DecompressionStream`,
  available wherever Flutter web runs.
- **No MBTiles.** The companion package reads SQLite through `dart:ffi`,
  which has no web implementation. PMTiles fills the same role over HTTP
  range requests.

## 🔌 Custom tile sources

No style URL? Any `{z}/{x}/{y}` MVT endpoint works. Build the theme
yourself and wire providers manually:

```dart
vt.VectorTileLayer(
  theme: vt.ThemeReader(logger: const vt.Logger.console()).read(myStyleJson),
  tileProviders: vt.TileProviders({
    'openmaptiles': vt.NetworkVectorTileProvider(
      urlTemplate: 'https://tiles.example.com/{z}/{x}/{y}.pbf?key=$key',
      maximumZoom: 14, // the source's max; higher zooms overzoom this data
    ),
  }),
)
```

Those are the two options you'll always set.
`NetworkVectorTileProvider` also takes `headers` for header-authenticated
tile servers, `minimumZoom`, `maxRetries` (default 2) and an optional
`client` if you bring your own `http.Client`, which is shared and never
closed for you.

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
`minimumZoom`/`maximumZoom` to override the archive header, the same role
a style source's `minzoom`/`maxzoom` plays.

**MBTiles** archives live in a companion package,
[`flutter_map_vector_tiles_mbtiles`](https://pub.dev/packages/flutter_map_vector_tiles_mbtiles),
separate because SQLite through `dart:ffi` would cost every app here a
native dependency and this package its web support:

```dart
final provider = await MbTilesVectorTileProvider.open('…/bavaria.mbtiles');
```

**Anything else** you write against `VectorTileProvider`, which is four
members; `MemoryVectorTileProvider` covers tests and tiles you already
hold. Two hooks exist for custom providers.

`resolveProvider` substitutes yours into a style by source id, so you keep
the style's theme, sprites and attribution and replace only the tiles.
Handy when the source lives somewhere no style document can name, like a
device-absolute path:

```dart
final style = await vt.StyleReader(
  uri: 'asset://styles/liberty.json',
  resolveProvider: (id) async => id == 'openmaptiles' ? provider : null,
).read();
```

Returning null falls through to the style's own URL, it applies to raster
sources too, and the `Style` takes ownership of what you return, so
`style.dispose()` disposes it.

`cacheBytesToDisk => false` says your provider is already backed by local
storage, so the disk cache is skipped in both directions instead of
storing a second copy. Implement it on anything reading from local
storage, and use `vt.SingleFlight` to coalesce concurrent loads, as the
built-in providers do.

Raster imagery (satellite, hillshade) wires up the same way: pass
`rasterSources:` entries of `RasterTileSource(provider: …, tileSize:
512)`, where the provider serves encoded PNG/JPEG/WebP bytes instead of
MVT. `NetworkVectorTileProvider` works unchanged. 256px sources are
fetched one zoom deeper for the same visual scale.

## 🎨 Style support

**Layer types**

| Type | Support |
|---|---|
| `background`, `fill`, `line`, `circle` | full, including `fill-pattern`, `line-pattern`, dashes and casing |
| `symbol` | full, including curved line text and `text-variable-anchor` / `text-radial-offset`; see [Labels](#-labels) below |
| `raster` | raster sources *inside* vector styles (satellite/hybrid imagery) draw at their layer position, with `raster-opacity` and brightness/contrast/saturation/hue-rotate matching MapLibre's shader math |
| `fill-extrusion` | renders as a flat fill |
| `hillshade`, `heatmap`, `sky` | skipped, with a log line |

**Icons.** SDF sprite sheets (`"sdf": true`) are thresholded and tinted
per `icon-color`, `icon-halo-color` and `icon-halo-width`; dark MapLibre
styles ship their icons this way. Ordinary sprites are drawn with the
colours baked into the sheet.

**Expressions.** The practical MapLibre set: `get`/`has`, comparisons,
`all`/`any`/`case`/`match`/`coalesce`, `step`/`interpolate` (linear,
exponential, cubic-bezier), math, string and color operators, `let`/`var`,
legacy filters, legacy `{stops}` functions and `{token}` templates.

Unsupported layer types, paint properties and expressions are skipped per
layer with a warning, so one weird layer never kills the whole style.

### 🏷️ Labels

Text and icons are drawn per frame in screen space rather than baked into
the tile rasters, which is what the behaviour below rests on:

- **Curved along the road.** Glyphs are placed one by one with MapLibre
  semantics: `text-max-angle` rejects sharp bends, `text-keep-upright`
  flips reading direction, `text-rotation-alignment: viewport` keeps
  shield text horizontal. Nearly straight windows are drawn as a single
  rotated string for speed; scripts with contextual shaping (Arabic,
  Indic, …) fall back to straight placement so glyphs are never
  mis-joined.
- **Zoom ranges, with a ramp at the top.** Nothing claims label space
  outside a symbol layer's `[minzoom, maxzoom)`, but labels ramp out over
  the last quarter zoom level before a declared `maxzoom` instead of
  snapping away, and ramp back in on the way out. `minzoom` gets no ramp:
  it is inclusive, so one would leave a `minzoom: 14` layer invisible at
  exactly zoom 14.
- **One fade state per label identity.** Beyond that ramp, every
  appearance and disappearance is animated per label (layer, text, icon),
  rising while the label is placed and falling once it is not, whatever
  the reason: a feature the tileset drops at the next zoom, a label
  crowded out by denser labelling, a whole layer cut at its `minzoom`.
  Each eases out over `labelFadeDuration` instead of vanishing in one
  frame. A departing label frees its space immediately, so its replacement
  fades in over it: a crossfade, not a pop at the fade's end.
- **A placed label always paints.** A label that has won its spot is never
  held invisible waiting on anything; it fades in from the frame it
  arrives. A zoom crossing delivers a screen's labels over tens of frames,
  since tiles finish one at a time, and each starts its fade as it lands
  rather than at some shared moment.
- **No blink when a zoom level hands over.** A label that survives the
  change keeps its opacity, because the two levels' copies share one fade
  state; a crossing can neither blink a label nor fade it into itself. The
  outgoing level also only ever *keeps* labels on screen and never
  introduces ones that weren't already visible, so a label that had been
  crowded out, a street name under a POI say, cannot flash up just as the
  level departs.
- **Street names cross-fade between per-level positions.** Along-line
  labels are re-spaced per zoom level, so the same name can genuinely sit
  elsewhere on its road after a crossing. Each sitting fades on its own
  clock: the old position eases out where it was while the new one fades
  in, instead of the name teleporting at full opacity.
- **Placement is remembered, not re-derived.** A label drawable from more
  than one feature, a street name on both carriageways or the same name
  from two zoom levels, stays on the one it is already on; a label at a
  `text-variable-anchor` stays at the anchor it took; a road label near
  vertical keeps reading the way it was reading. A slow pan therefore
  doesn't walk a street name across its street. Those choices are
  remembered per label and position rather than per tile, so they survive
  a level handing over or a tile re-rendering underneath a label that
  never left the screen.
- **Collision is decided on a timer.** Camera motion and changed label
  candidates are picked up at the next `labelFadeDuration` interval, at
  most 300 ms away, and the previous decision is held in between. Zooming
  and rotating drag labels through each other constantly, and re-deciding
  every frame turns each of those brushes past into a label that disappears
  and comes straight back. Between decisions neighbours are simply allowed
  to overlap for a moment, as they are in MapLibre. An unchanged repaint
  creates no new placement work, so the animation ticker settles when the
  last real change has been placed.

## 🏗️ Architecture

```
style.json ─► StyleReader ─► compiled Theme (expressions → closures)
camera ─► visible display tiles ─► data tiles (shared, LRU-cached)
   bytes ◄─ disk cache ◄─ network        ─► isolate: decode + trim
   PreparedTile ─► rasterize once ─► GPU image ─► textured quad per frame
   symbols ─────► per-frame screen-space label pass (global collision)
   finished tiles (image + symbols) ─► shared LRU ─► instant re-crossings
```

For profiling, the render pipeline emits DevTools timeline events:
`VT render pump`, `VT rasterize`, `VT symbols`, `VT labels`.

On web the disk cache tier is absent and decoding runs on a yielding
event-loop queue instead of isolates. Everything else is identical.

The full rendering model, and the reasoning behind each departure from
[`vector_map_tiles`](https://pub.dev/packages/vector_map_tiles), is in
[doc/ARCHITECTURE.md](doc/ARCHITECTURE.md). 📖

## 🆚 [`vector_map_tiles`](https://pub.dev/packages/vector_map_tiles)

| | vector_map_tiles (stable) | this package |
|---|---|---|
| Packages | 3 ([`vector_map_tiles`](https://pub.dev/packages/vector_map_tiles), [`vector_tile_renderer`](https://pub.dev/packages/vector_tile_renderer), [`executor_lib`](https://pub.dev/packages/executor_lib)) + [`stash`](https://pub.dev/packages/stash) caching | 1 |
| Labels | baked into tile rasters / per-tile collision | screen-space pass, global collision, upright text |
| Zoom flicker | white flash on fast zoom ([#147](https://github.com/greensopinion/flutter-vector-map-tiles/issues/147)) | retained level + ancestor/descendant substitution |
| Cancellation | `CancellationException` reaches crash reporting ([#205](https://github.com/greensopinion/flutter-vector-map-tiles/issues/205)) | a state, never an exception |
| Style zoom | evaluated at flutter_map zoom (1 off vs. MapLibre) | `TileOffset.maplibre` default |
| Rasters | async image encode | `Picture.toImageSync` (stays on GPU) |

## 🐛 Troubleshooting

- **Blank map, no errors.** Pass `logger: const vt.Logger.console()` to
  both `StyleReader` and `VectorTileLayer`. Usually the style's source ids
  don't match your `TileProviders` keys, or the API key is invalid; HTTP
  403s are logged, with keys redacted.
- **`read()` or `open()` throws.** The designed failure path for a broken
  setup. `StyleReader.read()` throws `StyleReaderException` when the style
  can't be loaded or parsed, and `PmTilesVectorTileProvider.open` throws
  `PmTilesException` on an invalid or unsupported archive, or
  `http.ClientException` on network failure. Catch these to show a retry
  UI. Runtime tile fetches never throw into your code; failures are logged
  and retried.
- **Anything MBTiles-related.** See the companion package's own
  [troubleshooting section](https://pub.dev/packages/flutter_map_vector_tiles_mbtiles).
- **Labels/roads look bigger than in MapLibre.** Probably `TileOffset.none`
  with a 512px-convention style; use the default.
- **Stale data after changing styles.** The disk cache keys by URL, and a
  changed `{key}` or map id is a different URL, so usually there is
  nothing to do. Supply `cachePath` to wipe it yourself.
- **Blank map on web.** Open the browser console: missing
  `Access-Control-Allow-Origin` headers on the style or tile host block
  every request (see [Web support](#-web-support)).
- **Solid magenta tiles after reopening the app on iOS.** Tiles rasterized
  while iOS had revoked the process's GPU access. The layer handles this
  itself; on 2.6.1 and earlier the corrupted tiles are cached for the life
  of the process, and calling `VectorTileLayer.clearMemoryCache()` on
  `AppLifecycleState.resumed` is the workaround. The underlying engine gap
  is [flutter#191255](https://github.com/flutter/flutter/issues/191255).
  Magenta from *decoded* images, meaning sprites and raster sources, is
  the same iOS bug one layer down and outside this package's reach
  ([flutter#166668](https://github.com/flutter/flutter/issues/166668),
  fixed in 3.32), so keep your Flutter up to date.

## 🤝 Contributing

Issues and PRs are welcome! Please run `dart analyze && flutter test`
before submitting; the suite covers the MVT decoder, expression engine,
caches, grid math and tile store. Run `flutter test --platform chrome` too
when touching anything platform-sensitive (requires Chrome).

## 📄 License

[BSD 3-Clause](LICENSE) © 2026 Jonas Grunau
