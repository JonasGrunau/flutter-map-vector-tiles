# 🗺️ flutter_map_vector_tiles

[![pub package](https://img.shields.io/pub/v/flutter_map_vector_tiles.svg)](https://pub.dev/packages/flutter_map_vector_tiles)
[![license: BSD-3-Clause](https://img.shields.io/badge/license-BSD--3--Clause-blue.svg)](LICENSE)
[![flutter_map](https://img.shields.io/badge/flutter__map-%E2%89%A5%208.0-green.svg)](https://pub.dev/packages/flutter_map)

**Vector tiles for [flutter_map](https://pub.dev/packages/flutter_map).**
A clean, self-contained rewrite of the ideas behind `vector_map_tiles` —
built for flutter_map ≥ 8 and modern Flutter (Impeller).

Render MapLibre / Mapbox GL styles (MapTiler, OpenFreeMap, OpenMapTiles,
Stadia, Protomaps, …) straight from MVT vector tile sources — as a plain
flutter_map layer. flutter_map keeps owning the camera, gestures and all
your other layers; this package only draws the map. 🎯

---

## ✨ Why this package?

| | |
|---|---|
| 📦 **One package** | MVT decoding, style engine and renderer in a single dependency — no renderer/cache/executor satellites |
| 🚀 **Smooth interaction** | Geometry is rasterized **once** per tile into GPU-resident images (`Picture.toImageSync`); pan, zoom and rotate are just textured quads |
| 🔍 **Crisp labels** | Text & icons are drawn per-frame in screen space: upright under rotation, sharp at fractional zoom, with **one global collision pass** — no duplicated or clipped labels at tile seams |
| 🌫️ **No white flashes** | New tiles fade in while ancestor imagery is kept underneath; fast zoom-ins render instantly from already-decoded parent tiles |
| 🎚️ **Correct MapLibre zoom semantics** | The default `TileOffset.maplibre` renders 512px-convention styles *exactly* as their authors designed them |
| 🧵 **Isolate pipeline** | Tiles are decoded & trimmed on a worker-isolate pool, viewport-centre first; cancellation is a state, **never an exception** in your crash reporting |
| 💾 **Deterministic caching** | LRU memory caches with byte budgets + a size-capped disk cache with no index files to corrupt; every `ui.Image` is disposed on eviction |
| ✈️ **Works offline** | The style bundle and recently viewed tiles are cached on disk: places you visited keep rendering with no network at all |
| 🛡️ **Tolerant style reader** | Unknown layer types and exotic expressions degrade per-layer with a warning — one weird layer never kills your whole map |

## 🚀 Quick start

### 1. Install

```yaml
dependencies:
  flutter_map: ^8.2.0
  flutter_map_vector_tiles: ^0.4.0
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
      sprites: style.sprites,
    ),
    // ...your markers, polylines, attribution, etc.
  ],
);
```

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
| 🟡 Others (Protomaps, ArcGIS, self-hosted) | any MapLibre `style.json` | tolerant reader; unsupported layer types are skipped with a warning |

## ⚙️ Configuration

Everything has sensible defaults — override what you need:

```dart
vt.VectorTileLayer(
  theme: style.theme,
  tileProviders: style.providers,
  sprites: style.sprites,
  tileOffset: vt.TileOffset.maplibre,          // 512px style convention (default)
  concurrency: 3,                              // decoding isolates
  diskCacheMaximumSizeInBytes: 50 * 1024 * 1024,
  diskCacheTtl: const Duration(days: 14),
  memoryCacheMaxBytes: 24 * 1024 * 1024,
  tileFadeDuration: const Duration(milliseconds: 150),
  showLabels: true,
  logger: const vt.Logger.console(),           // see style warnings in debug
)
```

| Parameter | Default | What it does |
|---|---|---|
| `tileOffset` | `TileOffset.maplibre` | zoom relation between map and style — see below 👇 |
| `concurrency` | `3` | worker isolates decoding tiles off the UI thread |
| `diskCacheMaximumSizeInBytes` | 50 MB | `0` disables disk caching |
| `diskCacheTtl` | 14 days | freshness window: younger tiles skip the network; older ones are refetched but kept as offline fallback — ⚠️ respect your tile provider's terms |
| `cacheFolder` | app support dir | supply your own directory to control/clear it |
| `memoryCacheMaxBytes` | 24 MB | decoded tile budget per source |
| `tileFadeDuration` | 150 ms | `Duration.zero` disables fade-in |
| `showLabels` | `true` | disables the whole symbol pass when `false` |

### 🎚️ Understanding `TileOffset`

MapLibre renders 512px tiles, so at the same visual scale a MapLibre zoom
is **one lower** than flutter_map's. Styles from MapTiler & friends are
authored against that convention.

- `TileOffset.maplibre` *(default)* — text sizes, road widths and layer
  zoom ranges match the style author's intent exactly. ✅
- `TileOffset.none` — evaluates the style at flutter_map's zoom directly;
  everything appears one zoom earlier/larger (the legacy
  `vector_map_tiles` default, if you need visual parity with it).

## ✈️ Offline behaviour

Everything you looked at recently keeps working without network:

- **Style bundle** — `StyleReader` caches style.json, TileJSON and
  sprites on disk (stale-while-revalidate): the cached copy is served
  instantly — including fully offline — and refreshed in the background
  once older than `refreshAfter` (12 h default). Opt out with
  `StyleReader(cache: false)`.
- **Tiles** — served from the disk cache while fresh; when a network
  fetch fails, an expired cached tile is served instead of a blank one.
  Stale tiles are only ever deleted by the size cap (oldest first),
  never by age alone.
- **Durable location** — both caches default to the application support
  directory, which the OS doesn't purge (unlike the temp directory).

This is a *visited-places* cache, not region pre-download. For
guaranteed offline regions, bundle tiles and serve them through the
`VectorTileProvider` interface (e.g. MBTiles/PMTiles) alongside an
`asset://` style.

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

There's also `MemoryVectorTileProvider` (tests, bundled offline regions)
and a small `VectorTileProvider` interface for anything else (MBTiles,
PMTiles, …).

## 🎨 Style support

**Layer types:** `background`, `fill` (incl. `fill-pattern`), `line`,
`symbol` (incl. curved line text ✍️, `text-variable-anchor` /
`text-radial-offset`), `circle` (`fill-extrusion` renders as flat fill;
`raster`, `hillshade`, `heatmap` and `sky` are skipped with a log line).

Road labels curve glyph-by-glyph along their line with MapLibre
semantics: `text-max-angle` rejects labels on sharp bends,
`text-keep-upright` flips reading direction, and
`text-rotation-alignment: viewport` keeps shield text horizontal.
Nearly straight windows are drawn as a single rotated string for speed;
scripts with contextual shaping (Arabic, Indic, …) fall back to straight
placement so glyphs are never mis-joined.

**Expressions:** the practical MapLibre set — `get`/`has`, comparisons,
`all`/`any`/`case`/`match`/`coalesce`, `step`/`interpolate` (linear,
exponential, cubic-bezier), math, string & color operators, `let`/`var`,
legacy filters, legacy `{stops}` functions and `{token}` templates.

**Not (yet) supported:** 🚧 `line-pattern`, raster sources inside
vector styles, and **web** (the disk cache and isolate pool are
`dart:io`-based).

## 🏗️ Architecture

```
style.json ─► StyleReader ─► compiled Theme (expressions → closures)
camera ─► visible display tiles ─► data tiles (shared, LRU-cached)
   bytes ◄─ disk cache ◄─ network        ─► isolate: decode + trim
   PreparedTile ─► rasterize once ─► GPU image ─► textured quad per frame
   symbols ─────► per-frame screen-space label pass (global collision)
```

The full rendering model and the reasoning behind each departure from
`vector_map_tiles` is documented in
[doc/ARCHITECTURE.md](doc/ARCHITECTURE.md). 📖

## 🆚 vs. `vector_map_tiles`

| | `vector_map_tiles` (stable) | this package |
|---|---|---|
| Packages | 3 (`vector_map_tiles`, `vector_tile_renderer`, `executor_lib`) + `stash` caching | 1 |
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
- **Labels/roads look bigger than in MapLibre** → you're probably using
  `TileOffset.none` with a 512px-convention style; use the default.
- **Stale data after changing styles** → the disk cache keys by URL; a
  changed `{key}` or map id is a different URL, so usually nothing to do.
  Supply `cacheFolder` if you want to wipe it yourself.

## 🤝 Contributing

Issues and PRs are welcome! Please run
`dart analyze && flutter test` before submitting — the suite covers the
MVT decoder, expression engine, caches, grid math and tile store.

## 📄 License

[BSD 3-Clause](LICENSE) © 2026 Jonas Grunau
