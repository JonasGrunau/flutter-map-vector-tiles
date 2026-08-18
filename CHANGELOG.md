# Changelog

## Unreleased

Surviving an app backgrounding on iOS.

- 🐛 **Magenta tiles after resuming an app**: iOS revokes GPU access
  while an app is in the background, and Impeller fills a texture whose
  Metal work was rejected with solid magenta rather than failing — so a
  tile rasterized on the way out or on the way back in returned a
  perfectly ordinary-looking image that was pure magenta, and the
  process-wide finished-tile cache then served it for the rest of the
  session. The layer now watches the app lifecycle: it stops rasterizing
  from `inactive` onwards (parking the work rather than dropping it),
  and on the way back it discards the finished-tile cache, the
  raster-source images and the pattern stamps, then re-rasterizes what
  is on screen. Recovery reads no network and decodes nothing — the
  geometry never left the Dart heap — and the old imagery stays up until
  its replacement lands, so there is no blank frame. A map screen
  rebuilt during the return is covered too: the "has been away" mark is
  process-wide, not per layer. This works around an engine gap rather
  than fixing it — Impeller parks an async `Picture.toImage` snapshot
  while the GPU is disabled but rasterizes `Picture.toImageSync`
  regardless — so it is written to be deleted once
  [flutter#191255](https://github.com/flutter/flutter/issues/191255)
  lands.

## 2.6.1

Documentation only — the style support section, rewritten to be
scannable. The library is unchanged from 2.6.0.

- 📚 **Style support**: layer types are a table with a row per type,
  icons and expressions sit together as the reference block they are,
  and the label behaviour becomes a Labels subsection of bold-led
  bullets instead of five dense paragraphs — with the zoom-handover
  guarantees split out from the general fade rule, since they answer a
  different question. No behaviour claim changed.

## 2.6.0

Everything a third-party tile source needs: providers can now be
substituted into a hosted style, opt out of the disk cache, and coalesce
their own requests — enough that
[`flutter_map_vector_tiles_mbtiles`](https://pub.dev/packages/flutter_map_vector_tiles_mbtiles)
adds MBTiles archives without this package taking on SQLite. Labels also
hold the spot they are sitting on across a zoom crossing.

- ✨ **Bring your own provider**: `StyleReader(resolveProvider: …)` swaps
  in a provider for any source by id, so a local archive can back a
  hosted style while that style still supplies the theme, sprites and
  attribution. Returning null falls through to the style's own URL, and
  it applies to raster sources too. This replaces the need for per-format
  URL schemes: a device-absolute path is not something a portable style
  document can name.
- ✨ `SingleFlight` is exported, so a provider outside this package can
  coalesce concurrent loads the same way the built-in ones do rather than
  hand-rolling an in-flight map.
- ⚡ Providers backed by local storage no longer duplicate their tiles
  into the on-disk cache, or leave a zero-byte marker for every
  coordinate they do not cover. Opt a custom provider out with the new
  `VectorTileProvider.cacheBytesToDisk`; `MemoryVectorTileProvider`
  already does. The opt-out covers reads as well as writes, so an entry
  written before a source became local cannot shadow it.
- 🐛 Street names no longer flip to the other side of their street, and
  labels at a `text-variable-anchor` no longer hop, at the moment a zoom
  level hands over or a tile is re-rendered. The choices a label makes
  when it is placed — which anchor it sits at, which way it reads — were
  kept on the symbol instance, and a new zoom level's copy of a street
  is a new instance: it decided again from scratch, at full opacity,
  with no fade to cover the change. They are now remembered per label
  and position, so the arriving copy inherits what the label it replaces
  was sitting on.
- 📚 The offline documentation now points at a real MBTiles
  implementation instead of describing one you would have to write.

## 2.5.0

Labels that hold still. Every appearance and disappearance animates
through one per-label fade, and which labels win their space is decided
on a timer instead of on every frame — so gestures no longer flicker
labels out and back, or walk them around the map.

- ✨ **Per-label fades**: `labelFadeDuration` now drives one fade state
  per label *identity* (layer, text, icon) instead of one per tile
  cohort — rising while the label is on screen, falling once it no
  longer is, whatever the cause. Labels fade in when a tile arrives,
  when they win collision space mid-gesture, or when panning brings
  them in; they fade out when the tileset stops carrying them at the
  next zoom, when denser labelling crowds them out, or when a zoom
  crossing cuts their layer at its `minzoom` — cases that used to pop
  in one frame. A departing label frees its space immediately, so its
  replacement crossfades in over it rather than popping in when the
  fade ends, and a label mid-fade that comes back resumes from its
  current opacity instead of restarting.
- 🎨 Labels ramp out over the last quarter zoom level before their
  layer's declared `maxzoom` instead of snapping away, and ramp back in
  when you zoom out across it. `minzoom` gets no zoom-based ramp — it
  is inclusive, so one would leave a `minzoom: 14` layer invisible on a
  map resting at exactly zoom 14 — but crossing it now eases labels out
  through the time-based fade above.
- ⚡ Frames between two collision passes lay out only the labels that
  are on screen, skipping the candidates that lost — most of them on a
  dense screen — and reserve no collision space at all.
- 🐛 Labels no longer wink out for a moment and return while you zoom.
  Collision was re-decided on every painted frame, and label boxes scale
  with the zoom, so every brush past a neighbour was acted on: a label
  lost its spot for a few frames and took it straight back. The
  collision pass now runs once per `labelFadeDuration` (at most every
  300 ms) and its decision is held in between, with the labels allowed
  to overlap for those frames — the trade MapLibre makes. Labels from a
  tile that just landed still place immediately.
- 🐛 Labels no longer wander while you pan. A name that can be drawn
  from more than one feature — a street label on both carriageways, or
  the same name coming from two zoom levels — jumped between them as
  their screen order changed; a label with `text-variable-anchor` hopped
  to its second anchor and back when a neighbour brushed past; and a
  road running near vertical flipped its label's reading direction on
  alternate frames, mirroring it (and any perpendicular `text-offset`)
  to the other side of the street each time. Each of those choices is
  now kept from the previous placement unless it genuinely stops
  fitting.
- 🐛 Labels no longer blink — or visibly fade into themselves — when
  you cross a zoom level. Crossing one replaces the whole display level
  with new tiles whose labels used to carry fresh fade state, so a
  label present at both levels could be re-faded against its own
  still-visible copy, with collision deciding between the two on a
  sub-pixel anchor difference. The two copies now share one fade state
  by construction: whichever wins collision draws at the same opacity,
  and the swap is invisible.
- 🐛 Street names no longer flash up in the moment between a zoom-out
  crossing and the new level's tiles arriving. The crossing cuts whole
  symbol layers at their `minzoom` (POIs, typically), and the space
  their labels held went to whatever the outgoing level had been
  suppressing — street names never previously on screen appeared, only
  to be faded straight back out. An outgoing level is now pinned to the
  labels that were actually visible: it keeps them on screen until the
  new level covers them, but can no longer introduce new ones.

## 2.4.0

What a full review of 2.3.0 turned up: tiles honour their freshness
deadline again, the finished-tile cache stops stranding textures across
map opens, and labels switch exactly at the zoom their layer declares.

- ✨ **`SpriteAtlas.signature`**: a sprite sheet now identifies its
  content — the URL `StyleReader` loaded it from, or its layout for a
  hand-built atlas — and `SpriteAtlas` accepts an optional `cacheKey`.
- 🎨 Stroked polygon outlines keep the corner at a ring's first vertex
  when clipped at deep zoom. The two halves of the contour were stroked
  separately, so butted end caps left a notch there.
- 🎨 Labels appear and disappear at exactly their layer's `minzoom` and
  `maxzoom`. The threshold was tested against a zoom rounded to 1/8 of a
  level, so labels could switch up to 1/16 of a level early or late.
- ⚡ Reopening a map over the same style paints from the finished-tile
  cache as documented. Its key changed on every style read, so styles
  with sprites — nearly all of them — re-rendered every open, and each
  open stranded the previous one's textures for the process lifetime.
  The number of retained caches is now bounded as well.
- ⚡ Fading labels draw through layers bounded to what they cover,
  instead of a full-screen offscreen pass per opacity step per frame.
- ⚡ Tiles held over from the previous zoom level release their
  cross-fade underlay at once, and render jobs queued for a tile that
  leaves the viewport are dropped rather than waiting for the pump —
  both used to hold a full tile texture longer than it was needed.
- 🐛 An expired tile whose cached bytes are corrupt is refetched. It was
  served, failed to decode, and every retry re-read the same bad entry,
  so the tile stayed blank until the cache evicted it.
- 🐛 A tile the source reports missing is re-checked when the
  revalidation meant to confirm that could not reach the source. A
  single failed request used to hide the tile for the whole session.
- 🐛 A background revalidation is no longer lost to a tile load that was
  already in flight: the older load could finish first, publish the
  replaced content and make the reload look like a no-op.
- 🐛 Content replaced by a revalidation can no longer be written back
  into the cache that revalidation just invalidated by a render job
  queued before it.
- 🐛 Display tiles served from the finished-tile cache are revalidated
  too. They never reach the tile stores, so `diskCacheTtl` did not apply
  to them for as long as they stayed cached.
- 🐛 A retry no longer replaces imagery that has already arrived. It
  could flip a finished tile back to loading and — when the retry
  recovered nothing — leave it there, pinning the previous zoom level's
  tiles and labels on screen.
- 🐛 Labels held over from the previous zoom level no longer stay hidden
  for several frames when a visible tile is re-rendered mid-transition.
- 🐛 A `labelFadeDuration` shorter than a millisecond no longer throws
  during paint, and a fade no longer spends its first frame invisible.
- 🐛 Setting `rasterCacheMaxBytes` to `0` at runtime releases the
  textures actually being held; changing the style in the same rebuild
  made it clear a different, empty cache instead.
- ✈️ Browsing an expired area offline no longer starts a request per
  cache miss: failed revalidations are throttled. Failed *loads* still
  are not, so stale tiles keep painting.
- ✈️ Tiles that finish downloading while a map is closing are written to
  the disk cache instead of dropped, so reopening does not refetch them.
- 📚 The README now documents the public API it never mentioned:
  tappable attribution links (`StyleAttribution.spans` /
  `AttributionSpan.url`), the exceptions `StyleReader.read()` and
  `PmTilesVectorTileProvider.open` throw, the full option sets of
  `NetworkVectorTileProvider` and `open()` (headers, zoom clamps,
  retries, custom `http.Client`), `StyleReader.httpClient`, and manual
  `RasterTileSource` wiring for raster imagery.
- 📚 `VectorTileLayer.clearMemoryCache()` is now covered in the README and
  the architecture guide — it had been public since 2.2.0 with no mention
  outside its dartdoc.

## 2.3.0

Smooth zooming where labels live: text is shaped once and scaled,
zoom-level crossings stagger their work, finished tiles are cached for
instant re-crossings — plus expired tiles that paint instantly and
refresh in the background, deep-zoom performance in dense cities, and
pub.dev gallery screenshots.

- ✨ **Finished-tile cache** (`rasterCacheMaxBytes`, default 64 MiB,
  0 disables): rasterized display tiles and their symbols are kept in a
  process-wide LRU, so zooming out and back in — or reopening a map on
  the same style — swaps the level back in instead of re-rendering it.
  These are GPU texture bytes (~1 MiB per tile at devicePixelRatio 2,
  ~2.25 MiB at 3); the default holds roughly two phone-screen zoom
  levels at dpr 2. `VectorTileLayer.clearMemoryCache()` releases it.
- ✨ **Label fade-in** (`labelFadeDuration`, default 150 ms, 0 restores
  the old instant pop): newly appearing labels and icons now fade in,
  masking the pop when a zoom level first shows symbol layers. Fading
  labels reserve their full collision space, so placements never shift
  mid-fade.
- ✨ **Stale-while-revalidate tiles**: disk-cached tiles older than
  `diskCacheTtl` are no longer refetched *before* they can paint —
  the expired tile is shown immediately and revalidated in the
  background. When the server returns changed data the tile
  cross-fades to the new imagery; when the fetch fails (e.g. offline)
  the old tile simply stays. Previously the map held back such tiles
  for the full network round-trip (plus retries) and fell back to the
  expired copy only after it failed.
- 🎨 A re-rasterized tile that replaces visible imagery (background
  refresh, a source recovered by a retry, provisional→final) now keeps
  the previous raster underneath while the new one fades in, instead of
  fading in over the map background.
- ⚡ **Scale-invariant text shaping**: label text used to be re-shaped
  (two `TextPainter.layout` passes per label, inside the paint phase)
  roughly every 0.1 px of a `text-size` zoom ramp — a full-screen
  re-shape ~10× per pinched zoom level, felt as stutter wherever labels
  were visible. Text is now shaped once at a 16 px reference size and
  drawn through the canvas transform, which keeps it vector-crisp at
  every fractional zoom; `text-opacity` and `text-halo-width` ramps
  re-shape a bounded handful of times per label ever instead of per
  zoom step. The per-frame style memo compares evaluated primitives, so
  a pinch frame no longer builds cache-key strings per symbol.
- ⚡ **Two-phase zoom crossings**: crossing an integer zoom used to
  rasterize geometry *and* extract symbols for every tile in one
  un-preemptible job each, and the first frame with new labels shaped
  all their text inside the paint phase — the visible stutter at the
  zoom where text and icons appear. Rasters and symbol extraction are
  now separate budgeted jobs (geometry for the whole viewport lands
  first, labels follow a frame or two later), text shaping is prewarmed
  in the same budgeted tick that publishes a tile's symbols, and the
  retained-level label bookkeeping is memoized instead of recomputed
  per frame during transitions.
- ⚡ **Overzoom culling and clipping**: zoomed past the source's
  maxzoom (z15+ for typical OpenMapTiles sources), every display tile
  used to re-process *all* features of its data tile for every style
  layer — in a dense city that meant millions of filter evaluations and
  full-tile path building per zoom crossing, and dash/line-pattern cost
  that grew 4× per zoom level. Features are now rejected on
  decode-time bounds before any expression work, and geometry is
  clipped to the tile's visible window from two levels of overzoom,
  with dash and line-pattern phase preserved across tile seams. A dense
  city tile at z20 over z14 data rasterizes ~80× faster in the bundled
  benchmark (85 ms → 1 ms).
- ⚡ Along-line label anchors are enumerated only within the display
  tile's window (their global spacing is kept, so labels never shift
  between tiles), and symbol layout skips features outside the tile
  before evaluating any style expressions — previously every display
  tile scanned every POI, house number and road of the whole data tile.
- ⚡ `line-gap-width` casings no longer allocate a full-tile offscreen
  buffer per feature — the compositing layer is bounded to the stroked
  path, which in a city of casing-styled roads was a large hidden
  raster-thread cost.
- ⚡ Smooth labels during pinch zoom in dense areas: the label pass now
  evaluates at a zoom quantized to 1/8-level steps and the text/glyph
  caches grew (800→2500 and 1500→4000 entries). Previously any
  fractional zoom change invalidated every label's cached style on
  every frame, and a dense city screen overflowed the text cache and
  re-laid-out every label every frame.
- 🐛 **Labels respect their layer's zoom range continuously**: zooming
  out toward a symbol layer's `minzoom`, street names used to burst on
  all at once just before the threshold and then all vanish together —
  the range was only checked at integer tile zoom, so labels (including
  the retained previous level's) kept painting until the tile grid
  flipped. The label pass now enforces `minzoom`/`maxzoom` every frame
  at the fractional style zoom, exactly where the style author set the
  cut.
- 🐛 Text whose `text-size` ramps toward zero is skipped instead of
  inflated to a 4 px floor — the near-invisible labels used to flood
  the collision grid at the bottom of the ramp (the other half of the
  burst). Text sized between 1 px and 4 px now draws at its true size.
- 🐛 Symbol layers with a fractional `minzoom` (e.g. 14.5) now appear
  at exactly that zoom when zooming in, instead of one whole zoom level
  late.
- 🐛 When current- and previous-level copies of a label tie for the
  same spot during a zoom crossing, the current level now wins
  deterministically instead of the winner flickering between the two.
- 📦 The pub.dev page now shows three screenshots (`screenshots/`), framed
  in an iPhone bezel: Munich in OpenFreeMap Liberty, Zermatt with an Esri
  hillshade raster blended into the vector style, and Munich in the dark
  Fiord style.
- 🧹 DevTools timeline events (`VT render pump`, `VT rasterize`,
  `VT symbols`, `VT labels`) around the render pipeline's UI-thread
  stages, for profiling zoom behaviour.
- 🧹 The example app draws its attribution as a rounded translucent
  pill centered at the bottom of the map instead of a flush white bar
  in the bottom-right corner.

## 2.2.0

Mapbox-hosted and header-authenticated styles now load, over a broad
correctness and performance pass.

- ✨ `StyleReader` now actually resolves `mapbox://` URIs — style ids,
  sprite bases and bare tileset ids expand to their `api.mapbox.com`
  equivalents with `apiKey` as the access token. The capability was
  documented but never implemented.
- ✨ `StyleReader` accepts `headers`, sent with the style, TileJSON and
  sprite requests and forwarded to the created tile providers — style
  loading now works end-to-end against header-authenticated services.
- ⚡ MVT tile decoding is about twice as fast (measured 2.0–2.3× on
  real tiles): geometry vertices accumulate into a reusable typed-data
  scratch buffer instead of a growable `List<double>`, which boxed
  every coordinate on the VM.
- ⚡ PMTiles tile blobs are no longer gzip-inflated on the UI isolate
  on native platforms: the worker isolate inflates them just before
  decoding (0.5–3 ms per tile that used to compete with the frame
  budget while panning on a cold cache), and the disk cache now stores
  the smaller compressed form. As a side effect, servers that send
  gzip-compressed MVT without declaring it now decode instead of
  failing. Feature properties are also filtered during decoding
  instead of being fully materialized and then trimmed.
- ⚡ Tile bytes travel lighter: downloaded tiles are no longer copied a
  second time before decoding, tiles a source has said don't exist
  (oceans, sparse zooms) are remembered on disk instead of being
  re-requested every app session, the offline fallback reads the disk
  once instead of probing existence first, and PMTiles leaf-directory
  caching is bounded by bytes rather than entry count alone.
- ⚡ The style engine does far less work per evaluation: zoom-only
  paint properties (pure zoom ramps — the most common shape) are
  detected at compile time and memoized against the zoom, so a tile
  pass evaluates each once instead of per feature; parsed CSS colours
  are cached; legacy `in` filters use set lookups instead of linear
  scans; literal `get`/`has` keys read the property map directly;
  operator dispatch moved from evaluation to parse time; exponential
  ramps precompute their per-interval `pow` factors; and legacy
  `{token}` templates are split once instead of regex-replaced per
  feature.
- ⚡ Less per-frame and per-feature work: zoom-only line layers resolve
  their stroke style once per tile instead of per feature, circle
  paints are built per feature instead of per point, literal list
  properties (fonts, offsets, dash arrays) are converted once at parse
  time, each symbol's text style is re-evaluated only when the zoom
  changes instead of every frame, the label collision index no
  longer allocates an iterator per collision box, curve-safety of
  label text is computed once per symbol instead of re-scanned per
  frame, the label pass sorts the per-frame symbol list in place
  instead of copying it first, and grid maintenance (visible-key
  enumeration and sorting) is skipped on the ~95% of gesture frames
  where the integer tile bounds are unchanged.
- 🐛 Coalesced tile loads no longer inherit the first requester's
  cancellation: a display tile disposed mid-flight (panned away,
  zoomed past) used to cancel the shared load and leave every other
  tile waiting on it permanently blank until recreated. Loads now poll
  a token joined over *all* waiters — cancelled only when nobody is
  left — in both tile stores and both network providers.
- 🐛 Tiles whose source failed transiently (network loss, 5xx) now
  retry: visible tiles re-request missing sources a bounded number of
  times, just past the stores' failure throttle, instead of staying
  blank or partial until the zoom level changes. Already-rendered
  content is not re-rasterized when a retry recovers nothing.
- 🐛 A raster tile load could return no image despite succeeding when
  the decoded image was evicted by a concurrent load in the same
  instant; callers now receive a handle that cannot be evicted out
  from under them.
- 🐛 On devices where isolate spawning fails, the decode pipeline now
  falls back to the event loop permanently instead of hanging every
  tile enqueued after the first batch; a decode isolate killed by the
  OS no longer strands its tile and shrinks the pool — it is replaced
  and the tile retried.
- 🐛 Turning `showLabels` on now lays out labels on the tiles already
  on screen (they used to appear only on tiles loaded afterwards), and
  changing `sprites` re-rasterizes live tiles so fill/line patterns
  from the old atlas don't linger. Neither refresh refetches or
  re-fades anything.
- 🐛 MVT decoding: a packed field ending in a continuation byte now
  fails as a decode error instead of silently reading past the field —
  which could render corrupt geometry — or crashing at the buffer end;
  and negative `int_value` properties (10-byte varints) decode to the
  correct negative number on web instead of a garbage positive one.
- 🐛 The label painter's text and glyph caches now dispose their
  `TextPainter`s on eviction and teardown instead of leaking the native
  paragraph memory (flagged under Flutter leak tracking; panning across
  label-dense areas grew it unboundedly).
- 🐛 Legacy `interval` functions evaluated exactly on a middle stop
  returned the previous band's output (wrong style values at every
  integer zoom boundary); they now select the greatest stop ≤ input,
  matching MapLibre.
- 🐛 Legacy `identity` functions now return the feature property's raw
  value; they — like every stop-less legacy function — used to be
  silently compiled to a constant raw JSON map, making typed paint
  properties fall back to their spec defaults with no warning.
  Uncompilable function shapes now degrade with a parser warning.
- 🐛 A tile property carrying `Infinity` no longer crashes the layer
  when stringified into a `text-field` token.
- 🐛 `MemoryVectorTileProvider` no longer defaults every instance to
  the same `cacheKey`: two providers bundling different regions shared
  decoded-tile and disk cache entries, rendering one region's tiles
  inside the other. The default key is now derived from the tile set
  (deterministic, so identical data still shares); pass an explicit
  `cacheKey` to control sharing. Disk entries cached under the old
  constant key are re-fetched once.
- 🐛 `VectorTileLayer.clearMemoryCache` during an open map no longer
  orphans the caches that in-flight loads keep refilling — refilled
  entries used to be unreachable by every later clear (a bounded
  `ui.Image` leak, worst on exactly the memory-pressure path the call
  serves). `memoryCacheMaxBytes` now actually applies when the shared
  cache for a source already exists (latest layer wins, including via
  `didUpdateWidget`); it used to be fixed by whichever layer mounted
  first in the process.
- 📦 pub.dev topics retagged for discoverability: `map` replaces
  `maps` (the topic page the flutter_map ecosystem actually uses) and
  `pmtiles` replaces `mvt`.

## 2.1.1

Style attribution and MVT decode performance.

- ✨ **Style attribution**: `Style.attributions` exposes what the style's
  sources (or the TileJSON they point at) declare, deduplicated and in
  document order. Attribution is HTML by convention, so each
  `StyleAttribution` carries the flattened `text` for a plain `Text`
  widget and the `spans` — text plus link — if you want it tappable. A
  source's own `attribution` overrides its TileJSON's, as in MapLibre.
  The example app now shows this instead of a hardcoded string.
- ⚡ Zigzag decoding is branchless again, recovering the ~5% of
  whole-tile decode time that 2.0.0's web-safe rewrite spent on
  mispredicted branches. Output is unchanged and still bit-identical
  between native and web; a latent wrong-sign overflow at the int64
  maximum is fixed as a side effect.

## 2.1.0

PMTiles support: Protomaps-style single-file tile archives now work.

- ✨ **PMTiles v3 archives**: styles with
  `pmtiles://https://…/planet.pmtiles` source URLs load out of the box,
  and `PmTilesVectorTileProvider.open(url)` serves any archive directly.
  Tiles come from HTTP range requests — the header and root directory
  are fetched once, leaf directories are LRU-cached, and each tile costs
  at most two range requests. Works on all six platforms; on web the
  archive host must allow ranged CORS requests, and gunzip uses the
  browser's native `DecompressionStream`. Archives with brotli or zstd
  internal compression are rejected with a clear error (gzip and
  uncompressed are supported — Protomaps builds ship gzip).
- The source's `minzoom`/`maxzoom` in the style override the archive
  header, matching the behaviour of TileJSON sources.

## 2.0.1

Real-world style compatibility: ArcGIS/Esri `root.json` styles now work.

- 🐛 Relative tile URL templates from TileJSON documents now resolve
  against the TileJSON URL instead of the style URL. ArcGIS vector tile
  services (`…/VectorTileServer/resources/styles/root.json`) declare
  their source as `"url": "../../"` with a relative
  `tile/{z}/{y}/{x}.pbf` template, which previously produced 404s for
  every tile.
- 🐛 Relative tile templates no longer break on `{z}`/`{x}`/`{y}`
  placeholders: URL resolution percent-encoded the braces to `%7Bz%7D`,
  defeating placeholder substitution.
- 🐛 `{key}` is now substituted in TileJSON source URLs
  (`"url": "https://…/tiles.json?key={key}"`), not only in the style
  URL and the tile templates.
- 📚 The README provider table now lists ArcGIS/Esri and self-hosted
  servers as verified (Esri `World_Basemap_v2`, MapLibre demo tiles)
  and documents that Protomaps `pmtiles://` archives are not supported.

## 2.0.0

The layer now runs on Flutter web.

- 🌐 **Web support**: rendering, styles, labels and raster sources work
  identically in the browser (CanvasKit/Skwasm renderer — the default
  since Flutter 3.29; the removed HTML renderer lacks
  `Picture.toImageSync`). Tile decoding runs on a yielding event-loop
  queue instead of worker isolates (`concurrency` is ignored), and
  there is no persistent cache on web: `cachePath`, `diskCacheTtl`,
  `diskCacheMaximumSizeInBytes` and `StyleReader(cache: …)` are no-ops
  there — tiles and the style bundle rely on the in-memory caches plus
  the browser's own HTTP cache, so the disk-backed offline behaviour
  remains native-only. Style, TileJSON, sprite and tile hosts must send
  `Access-Control-Allow-Origin` (MapTiler, OpenFreeMap and Stadia do).
- 💥 **Breaking**: the `cacheFolder` parameter
  (`Future<Directory> Function()?`) on `VectorTileLayer` and
  `StyleReader` is now `cachePath` (`Future<String> Function()?`), so
  the public API no longer carries a `dart:io` type. Migration:
  `cacheFolder: () async => dir` becomes
  `cachePath: () async => dir.path`; if you never passed `cacheFolder`,
  nothing changes — cache locations and defaults are identical, and
  existing on-disk caches are reused as-is.
- 🐛 MVT varint and zigzag decoding no longer relies on 64-bit bitwise
  operations, which JavaScript truncates to 32 bits — negative
  coordinate deltas decoded as huge positive values on web. Native
  results are bit-identical.

## 1.2.0

Two style features that used to be skipped now render.

- 🎨 `line-pattern`: the sprite is stamped along the line, rotated to
  the local direction and scaled so its height matches the line width
  (MapLibre semantics, data-driven patterns included). Per spec the
  pattern replaces `line-color` and `line-dasharray`; `line-opacity`
  still applies. A missing sprite falls back to the color stroke.
- 🛰️ Raster sources inside vector styles (satellite/hybrid imagery,
  pre-rendered hillshade tiles): `raster` layers draw their tiles at
  the correct position in the layer order. `raster-opacity`,
  `raster-brightness-min`/`-max`, `raster-contrast`,
  `raster-saturation` and `raster-hue-rotate` replicate MapLibre's
  fragment-shader math (including its factor curves and spin weights).
  Raster tiles share the tile disk cache, are decoded once and cached
  process-wide (released by `VectorTileLayer.clearMemoryCache()`),
  overzoom past the source maximum, respect the source `tileSize`
  (512/256) under `TileOffset`, and render in-memory ancestors as
  provisional imagery during zoom — the same lifecycle vector tiles
  get. `StyleReader` picks raster sources up automatically (inline
  `tiles` or TileJSON `url`); pass `style.rasterSources` to the new
  `VectorTileLayer.rasterSources` parameter.

## 1.1.0

Reopening a map is now nearly instant. Both caches used to die with the
layer, so every time a map screen was pushed it started from nothing.

- ⚡ The disk cache is awaited rather than raced. It initializes
  asynchronously — its directory comes from a platform channel — but tiles
  are requested on the very first frame, and the load path read it as a
  plain field that was still null. Every map open therefore fetched its
  opening screenful over the network, with the tiles already on disk. The
  stores now hold the pending cache and await it.
- ⚡ Decoded tiles are cached process-wide instead of per layer, so a
  reopened map paints without decoding anything again. Entries are keyed by
  source *and* by the properties the theme reads — two styles over one
  source do not share trimmed tiles — and are capped by
  `VectorTileLayer.memoryCacheMaxBytes` per key. They outlive the layer by
  design; `VectorTileLayer.clearMemoryCache()` releases them, e.g. from a
  memory-pressure handler.
- ⚡ `DiskCache` instances are shared per directory, so a second layer over
  the same folder reuses an initialized cache instead of setting up its own.
- 📝 `VectorTileProvider.cacheKey` now also identifies the in-memory cache.
  Providers serving different bytes must not share one.

## 1.0.0

First stable release: the public API is now considered settled and will
follow semantic versioning from here.

- ✨ `icon-color`, `icon-halo-color` and `icon-halo-width` are supported
  for SDF sprite sheets (see the rendering fix below).
- 🐛 The map no longer shakes while zooming and no longer slides out
  from under its labels while dragging. Tile rectangles are now made
  camera-relative in Dart before they reach the canvas: world pixel
  coordinates pass 2^24 around zoom 16, and the canvas transform is
  float32, so absolute coordinates were snapping the imagery onto a
  grid — 0.25 px at zoom 14, but 4 px at zoom 18 and 16 px at zoom 20.
  The label pass does its own float64 arithmetic, so the two drifted
  apart. This is why the artifacts only appeared when heavily zoomed
  in.
- 🐛 SDF sprites are rendered correctly instead of as dark blobs.
  Sheets flagged `"sdf": true` store a distance field in the alpha
  channel over flat RGB; they were being blitted directly, which
  painted the raw field. They are now thresholded and tinted, adding
  support for `icon-color`, `icon-halo-color` and `icon-halo-width`.
  Ordinary sprites are unaffected. Dark MapLibre styles are typically
  entirely SDF, which is why icons looked correct in light styles and
  wrong in dark ones.
- 🐛 `text-opacity` is now applied. Labels the style fades out are also
  no longer laid out at all, so they stop reserving collision space and
  suppressing the visible labels around them.

## 0.4.1

Nothing on screen disappears before its replacement is ready — the
blanking, flashing and dropped frames around zoom changes are gone.

- 🐛 The map no longer blanks and reloads moments after first paint:
  the async disk-cache initialization now attaches to the running tile
  stores instead of rebuilding them (which disposed every rendered
  tile).
- 🐛 No more flash on zoom level changes: the previous level's imagery
  is kept until the new tiles are rasterized *and* fully faded in —
  it used to be dropped mid-fade, dipping to the background color.
- 🐛 Labels no longer blink out on zoom level changes: the previous
  level's labels keep drawing wherever the new level has no label data
  yet (current-level labels win collisions as they arrive).
- ⚡ Smoother zooming: tiles are rasterized through a priority queue
  with a per-frame time budget (viewport centre first) instead of all
  in one frame. With warm caches, a zoom change used to rasterize the
  entire grid synchronously in a single frame, dropping frames.

## 0.4.0

Places you have already visited keep working without a network.

- ✈️ Offline support for recently visited places:
  - `StyleReader` now caches the style bundle (style.json, TileJSON,
    sprites) on disk with stale-while-revalidate: the cached copy is
    served instantly — including fully offline — and refreshed in the
    background once older than `refreshAfter` (12 h default). Opt out
    with `cache: false`.
  - Tiles: when a network fetch fails, an expired disk-cache entry is
    served instead of a blank tile. `diskCacheTtl` is now a freshness
    window — stale tiles are kept (up to the size cap, evicted oldest
    first) as the offline fallback instead of being deleted by age.
  - The default cache folder moved from the system temp directory to
    the application support directory, which the OS doesn't purge.
    Existing temp-dir caches are simply abandoned and refetched once.

## 0.3.0

Road labels now follow the curve of their line.

- ✨ Curved line text: road labels now follow their line glyph by glyph,
  with MapLibre semantics — `text-max-angle` (labels on too-sharp bends
  are not placed), `text-keep-upright` (reading direction flips so text
  is never upside-down) and `text-rotation-alignment: viewport`
  (horizontal shield text). Glyph spacing/kerning comes from the full
  string layout; per-glyph collision boxes; nearly straight labels are
  drawn as a single rotated string for speed.
- Scripts with contextual shaping (Arabic, Indic, Thai, …) fall back to
  straight placement so glyphs are never mis-joined; labels longer than
  their line are dropped instead of sticking out (matches MapLibre).
- Along-line labels no longer wrap to multiple lines.
- ⬆️ `latlong2` constraint widened to `>=0.9.1 <0.11.0`, so 0.10.x resolves.
  Still compatible with flutter_map 8.2.0+, which pins `^0.9.1` until 8.3.1.
- 🧹 Source reformatted with the Dart formatter (no behaviour change).

## 0.2.0

Denser labels and pattern fills, plus a parser fix that quietly broke
font stacks and label offsets in most real styles.

- ✨ `text-variable-anchor` + `text-radial-offset`: labels try alternate
  anchors before being dropped on collision — dense areas keep far more
  POI and place labels visible (matches MapLibre behaviour).
- ✨ `fill-pattern` (and `fill-extrusion-pattern`): polygon fills render
  repeating sprite patterns (wetlands, glaciers, pedestrian zones),
  world-grid aligned across tile seams; missing sprites fall back to the
  color fill.
- 🐛 Bare literal arrays in style JSON (`text-offset: [0, 0.6]`,
  `text-font: [...]`, `line-dasharray: [2, 1]`, anchor lists) were
  mis-parsed as expressions and silently fell back to defaults —
  affected font stacks and label offsets in most real styles.
- `LabelPainter.paint` now returns the symbols that were actually drawn.

## 0.1.0

Initial release. 🎉

- `VectorTileLayer` for flutter_map ≥ 8 rendering MapLibre/Mapbox GL
  styles from MVT vector tile sources.
- Self-contained: built-in MVT decoder, style/expression engine
  (modern expressions + legacy filters/functions/tokens), sprite support.
- GPU-resident per-tile rasterization (`Picture.toImageSync`) with
  fade-in, ancestor-tile retention and provisional rendering from
  cached parent tiles (no white flashes on zoom).
- Screen-space label pass with global cross-tile collision, upright
  text under rotation, halo and sprite icon support.
- Worker-isolate decode pipeline with priority ordering and silent
  cancellation.
- Deterministic LRU memory caches (byte budgets) and TTL + size-capped
  disk cache.
- `StyleReader` for style.json / TileJSON / sprites with `{key}`
  substitution, tolerant of real-world provider quirks
  (MapTiler, OpenFreeMap, Stadia, ArcGIS, Protomaps).
- `TileOffset.maplibre` default for correct 512px-convention rendering.
