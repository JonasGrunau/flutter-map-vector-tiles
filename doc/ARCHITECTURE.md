# Architecture

`flutter_map_vector_tiles` is a clean-room rewrite of the ideas behind
`vector_map_tiles`, designed for flutter_map ≥ 8 and modern Flutter
(Impeller). It is a single self-contained package: MVT decoding, the
MapLibre style engine, the tile pipeline and rendering all live here.

## Data flow

```
style.json ──► StyleReader ──► Theme (compiled layers + expressions)
                                  │
camera ──► TileGrid (visible display tiles at floor(zoom))
                                  │
display tile (z,x,y) ─► data tile key (clamped to source maxZoom)
     │
     ├─ TileStore (memory LRU of PreparedTile)
     │      └─ miss: bytes ◄─ DiskCache ◄─ VectorTileProvider (network…)
     │              └─ IsolatePool: decode MVT + filter per theme layer
     │                             └─ PreparedTile (compact, transferable)
     │
     ├─ TileRasterizer: PreparedTile ─► ui.Picture ─► toImageSync (GPU)
     │       one raster per *display* tile at tileSize·dpr, evaluated at
     │       the display zoom (crisp overzoom via subdivision, not scaling)
     │
     └─ symbols: SymbolPlacer collects label/icon anchors per tile
             └─ LabelLayer: per-frame screen-space pass, global collision
                grid across all tiles, upright text under rotation
```

## Rendering model

Geometry (background/fill/line) is rasterized **once** per display tile
into a GPU-resident `ui.Image` via `Picture.toImageSync`; the per-frame
cost of pan/zoom/rotate is just textured quads, like a raster tile layer.
Between integer zooms the images scale (max 2×) exactly as raster maps
do; on crossing a zoom level, new display tiles are rasterized from the
already-decoded data tile, while the previous zoom's images are retained
and drawn underneath until replacements are ready (no white flicker).

Labels and icons are **not** baked into the tile images. They are drawn
each frame in screen space:

* text stays crisp at fractional zoom and upright under map rotation;
* collision detection runs globally across tile borders, so labels never
  duplicate or clip at tile seams;
* fade transitions don't require re-rasterizing geometry.

The whole layer is one `CustomPaint` — no per-tile widget churn, one
repaint boundary. The painter applies the camera transform (translate ·
rotate about the screen centre) itself; `MobileLayerTransformer` is not
used.

## Concurrency

MVT decoding and per-layer feature filtering run on a small isolate pool
with a priority queue (tiles closest to the camera centre first) and
*silent* cancellation — a cancelled job never surfaces an exception.
`PreparedTile` keeps geometry in `Float32List`s (tile-extent units) so
isolate transfer is cheap, and only the feature properties referenced by
the theme are retained.

Requests are coalesced per key at every level (`SingleFlight`); a
coalesced load polls a token joined over *all* its waiters, so one
cancelled waiter never aborts work others still await. Transient
failures are throttled (15 s per key) and visible tiles retry a bounded
number of times just past that throttle; a worker isolate that dies is
replaced, and if isolates cannot be spawned at all the pool falls back
to the event loop permanently.

On web (no isolate support for this workload) the pool degrades to
chunked event-loop execution.

## Caching

| layer | keyed by | bounded by |
| --- | --- | --- |
| memory: `PreparedTile` | data tile + theme id | entry count + bytes |
| memory: raster `ui.Image` | display tile + int zoom + theme | entry count (images disposed on evict) |
| memory: raster-source `ui.Image` | data tile per raster source | entry count + bytes (handed out as ref-counted clones) |
| disk: raw tile bytes | url hash | TTL + total size sweep |

All caches are plain deterministic LRU implementations — no external
cache framework. Every `ui.Image` has exactly one owner and is disposed
on eviction or layer dispose; disposing the layer tears down isolates,
pending requests and caches (verified by tests).

On web the disk row is absent: the cache resolver
(`cache_resolver_stub.dart` vs `cache_resolver_io.dart`, mirroring the
executor's conditional import) resolves to no persistent cache, and
`TileStore`/`StyleReader` already tolerate a null cache — tiles degrade
to the memory LRU plus the browser's HTTP cache.

## Style engine

The style reader accepts real-world MapLibre/Mapbox GL styles and is
deliberately tolerant: unknown layer types, unknown paint properties and
unparseable expressions degrade per-layer (with a log), never failing the
whole style. Expressions are compiled once into Dart closures; both the
modern expression array syntax and the legacy filter syntax are
supported. Sources are resolved through TileJSON when `url` is present,
including `{key}` substitution. Whatever a source (or its TileJSON)
declares as `attribution` is collected into `Style.attributions`,
deduplicated across sources; since that value is HTML by convention it
is parsed into both flattened text and text-plus-link spans, because
Flutter has no DOM to hand it to. Relative URLs resolve against the
document that declared them — sprite and source URLs against the style
URL, tile templates against the TileJSON URL when they came from one
(ArcGIS declares `"url": "../../"` and `tile/{z}/{y}/{x}.pbf`) — and
the `{z}`/`{x}`/`{y}` braces survive resolution un-percent-encoded.

Sources whose `url` starts with `pmtiles://` bypass TileJSON entirely:
`PmTilesVectorTileProvider` reads the single-file archive over HTTP
range requests. Its `open()` fetches the 127-byte header plus root
directory in one 16 KiB request (the spec guarantees both fit there);
each tile then maps z/x/y onto the PMTiles Hilbert tile ID and costs at
most two more range requests — an LRU-cached leaf directory and the
tile blob. Directory gunzip runs at fetch through a conditional import
(`dart:io` zlib natively, the browser's `DecompressionStream` on web).
Tile-blob gunzip is deferred on native platforms: the provider hands
the compressed blob through (the disk cache stores that smaller form)
and `prepareTileSync` inflates it on the worker isolate — provider
loads run on the UI isolate, where a 0.5–3 ms inflate per tile would
eat into the frame budget. On web, with no worker isolate, blobs are
inflated at fetch as before. The raster store performs the same
gzip-magic sniff before image decode for the rare compressed-raster
archive.
All 64-bit offsets and tile IDs are computed with multiply/add
arithmetic (exact to 2^53) rather than bitwise ops, which dart2js
truncates to 32 bits — the same constraint the MVT decoder observes.

## What was deliberately changed vs. vector_map_tiles

* one package instead of three (`vector_map_tiles`, `vector_tile_renderer`,
  `executor_lib`), one rendering mode instead of three;
* `stash` replaced by ~200 lines of deterministic cache code;
* labels moved out of tile rasters into a global screen-space pass;
* cancellation is a state, not an exception;
* tile substitution (parent/child retention) is part of the core grid
  logic instead of an afterthought;
* `Picture.toImageSync` keeps rasters on the GPU (no async readback).
