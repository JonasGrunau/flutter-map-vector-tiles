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
     │       the display zoom (crisp overzoom via subdivision, not scaling);
     │       features are culled — and at deep overzoom clipped — to the
     │       tile's window of the data tile
     │
     └─ symbols: SymbolLayouter collects label/icon anchors per tile
             └─ LabelPainter: per-frame screen-space pass, global collision
                grid across all tiles, upright text under rotation

Rasterization and symbol extraction are two separate jobs in a budgeted
per-frame render pump (rasters for every pending tile first, symbols
after), and a finished tile — image plus symbols — enters the shared
result cache, so re-crossing a zoom level skips the pipeline entirely.
The pump's stages emit DevTools timeline events (`VT render pump`,
`VT rasterize`, `VT symbols`, `VT labels`).
```

## Rendering model

Geometry (background/fill/line) is rasterized **once** per display tile
into a GPU-resident `ui.Image` via `Picture.toImageSync`; the per-frame
cost of pan/zoom/rotate is just textured quads, like a raster tile layer.
Between integer zooms the images scale (max 2×) exactly as raster maps
do; on crossing a zoom level, new display tiles are rasterized from the
already-decoded data tile, while the previous zoom's images are retained
and drawn underneath until replacements are ready (no white flicker).

At overzoom — display zoom past the source's maxzoom — each display tile
shows only a small window of its data tile. Features are rejected
against that window (expanded by a 64-logical-px buffer) using bounds
computed once at decode time, *before* any filter or paint expression
runs; from two levels of overzoom the surviving geometry is additionally
clipped to the window, with dash and line-pattern phase measured from
the original run start so patterns stay aligned across clip boundaries
and display-tile seams. Rasterization cost per display tile is therefore
bounded by what is visible, not by the density of the data tile — the
difference between ~1 ms and ~85 ms per tile for a dense city tile
viewed at z20 over z14 data.

Labels and icons are **not** baked into the tile images. They are drawn
each frame in screen space:

* text stays crisp at fractional zoom and upright under map rotation;
* collision detection runs globally across tile borders, so labels never
  duplicate or clip at tile seams;
* fade transitions don't require re-rasterizing geometry;
* a symbol layer's `minzoom`/`maxzoom` is enforced per frame at the
  fractional style zoom (per-tile layout only prefilters by the integer
  zoom band), so labels appear and disappear exactly at the style's
  thresholds — including labels still painted from retained
  previous-level tiles during a zoom crossing.

Text is shaped **once per unique label at a 16 px reference size** and
drawn through the canvas transform at the evaluated `text-size` — valid
because every layout input is em-proportional, and crisp because glyphs
rasterize at device scale under the transform. The shape-cache key
therefore contains no font size; `text-opacity` (1/32 steps) and
`text-halo-width` (1/128-em ratio steps) enter it quantized, so style
ramps re-shape a label a bounded number of times ever rather than per
zoom step. Never put a font size — or an unquantized opacity or halo
width — back into that key: it re-creates the full-screen re-shape per
pinch that this design removed. Collision boxes and curved-text cluster
metrics are the reference-size measurements multiplied by the scale.

Symbol layout applies the same decode-time bounds culling before
evaluating any expressions, and along-line anchors keep their full-line
spacing parametrization — an anchor lands at the same world position no
matter which display tile lays it out — while being *enumerated* only
inside the tile's window. It runs as its own budgeted job after the
tile's raster (skipped entirely when no symbol layer intersects the
tile's zoom band),
and the tile's label text is shaped into the caches in that same tick —
before the first frame that can draw it, never during paint. A tile
whose symbols are still pending counts as loading for the retention
rules, so the previous level's labels cover the gap; newly appearing
labels then fade in over `labelFadeDuration`, drawn in a few quantized
opacity buckets (one translucent layer each, bounded to what that
bucket paints) while reserving full-size collision space.

Which labels count as *newly appearing* is decided once, when a tile
publishes its cohort, by `render/label_continuity.dart`. Every integer
zoom crossing replaces the whole display level with fresh tiles that
carry no fade history, so without this the arriving level would re-fade
labels the retained level is still drawing at full opacity. The two
copies then compete for the same collision space and the winner turns on
a sub-pixel difference in anchor position — arbitrary per label, which is
what made *some* labels blink across a crossing (and, on
`*-allow-overlap` layers where nothing collides, composite over
themselves). So a cohort is split against the labels the overlapping
retained tiles are showing, matched on `(layer, text, icon)` — position
plays no part, because the two levels simplify geometry differently and a
missed match would put the blink back, while a spurious one only makes a
label appear instantly. The carried-over prefix draws opaque; only the
rest fades.

Symbols also ramp out over the last quarter zoom level before their
layer's declared `maxzoom`, so zooming past a threshold dissolves a label
instead of snapping it away. The ramp is a function of zoom alone — no
per-symbol history, and exactly reversible — and lives *inside* the
range, reaching zero at the threshold where the hard cut takes over.
Only `maxzoom` ramps: `minzoom` is inclusive, so a symmetric ramp would
leave a `minzoom: 14` layer invisible on a map resting at exactly zoom
14. The ramp may dim a symbol the style is about to remove, never one
the style says is fully visible. The per-frame
label pass evaluates at a zoom quantized to 1/8-level steps, so the
per-instance style memos — which compare evaluated primitives, not
strings — keep hitting on every frame of a pinch gesture instead of
missing on every fractional zoom change. Layer visibility is gated on
the *exact* fractional zoom rather than that quantized value: rounding a
size costs a fraction of a pixel, while rounding a discrete cut moves it
by up to 1/16 of a level, so labels would appear and vanish away from
the thresholds the style declares.

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
| memory: raster-source `ui.Image` | data tile per raster source | entry count + bytes (handed out as ref-counted clones) |
| memory: finished display tile (raster `ui.Image` + symbols) | display tile, per render signature (theme id, providers, dpr, sprite *content*, labels) | GPU texture bytes (`rasterCacheMaxBytes`, cache owns the master image, tiles hold clones); retained signatures bounded by their combined cost |
| disk: raw tile bytes | url hash | TTL + total size sweep |

All caches are plain deterministic LRU implementations — no external
cache framework. Every `ui.Image` has exactly one owner and is disposed
on eviction or layer dispose; disposing the layer tears down isolates,
pending requests and its owned images (verified by tests). Each live
display-tile model owns exactly one `ui.Image` (a clone, when it came
from the result cache); the result cache separately owns its master
images and is shared process-wide, so revisiting a zoom level — or
reopening a map over the same style — swaps finished tiles back in
without touching the pipeline. The signature identifies the sprite sheet
by content (`SpriteAtlas.signature`, its URL when `StyleReader` loaded
it), never by object identity: re-reading a style builds a new atlas
every time, so an identity key would miss on every open and strand the
previous signature's textures. Signatures are retained past their
layer for exactly that warm-open case, so the registry releases the
least recently used once their combined cost exceeds the budget —
always keeping the two most recent, so two layers over different styles
cannot evict each other.

Only final, fully-sourced results are cached, so a hit can never mask a
pending retry. Render jobs and loads carry the tile generation they were
built for and are dropped once it moves on, so content replaced by a
revalidation can neither be painted nor written back into the cache that
revalidation just invalidated. Beyond the cache's budget, revisiting a
zoom re-rasterizes from the `PreparedTile` LRU — cheap, since only the
visible window is processed. `VectorTileLayer.clearMemoryCache()` empties
all three memory tiers at once — the memory-pressure valve, since the
caches are process-wide and otherwise freed only by their budgets; the
disk cache is untouched.

The disk TTL is a *revalidation* deadline, not an expiry: expired
entries — including the zero-byte "known absent" sentinels — are served
immediately and refetched in the background (stale-while-revalidate,
`TileByteLoader.refresh`). When the refetch delivers different bytes the
store re-decodes them, replaces the memory entry and notifies the layer,
which re-rasterizes the affected display tiles; the previous raster is
kept as an underlay for the duration of the fade, so the swap
cross-fades instead of dipping to the background.

Three properties keep that deadline honest:

- **Nothing serves content the check never reached.** A refresh
  reports failure distinctly from "unchanged", so an absence recorded
  from an expired sentinel is withdrawn when the source could not be
  reached — otherwise one failed request would strand the tile for the
  session, since `obtain` short-circuits on a known absence.
- **A stale entry that cannot be decoded still gets refetched.** The
  revalidation runs even when the served bytes fail to prepare, because
  it is the only thing that rewrites the disk entry; without it a torn
  write would fail identically on every retry until the size sweep.
- **A display tile served from the finished-tile cache is checked
  too** (`TileStore.revalidateIfStale`). It never reaches the stores,
  so nothing else would notice its data expiring. Data tiles still held
  in memory are skipped — loading them ran the check already — leaving
  one disk lookup for the case where a rendered result outlived its
  source data.

A failed refetch changes nothing displayed: the stale entry stays
servable and is only ever deleted by the size sweep. It does not
throttle *loads* — that would make the failure worse than the staleness
— but it does throttle further *refreshes* of that key, so browsing an
expired area offline cannot start one request per memory-cache miss.

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
supported. The parser proves per property whether an expression reads
feature data — properties that depend only on the zoom (most paint
properties are pure zoom ramps) memoize their coerced result against
the zoom in the typed wrappers, so a tile pass or a label frame
evaluates each once instead of per feature. Parsed CSS colours are
memoized process-wide for the same reason. Sources are resolved through TileJSON when `url` is present,
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
