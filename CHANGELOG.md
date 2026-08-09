# Changelog

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
