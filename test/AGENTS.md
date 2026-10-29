<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-08-09 | Updated: 2026-08-09 -->

# test

## Purpose

The package's test suite — flat apart from `fixtures/` and `scripts/`, no
mocking framework, and golden files only in `scripts/`. Pure
logic is unit tested directly; anything involving `ui.Image` ownership, tile
lifecycle or painting is covered by widget tests that pump a real
`FlutterMap`. Tests import package internals via
`package:flutter_map_vector_tiles/src/…` where needed.

## Key Files

| File | Description |
|------|-------------|
| `expression_test.dart` | Style expression compilation: operators, interpolation, legacy syntax, coercions |
| `maplibre_expression_conformance_test.dart` | Every expression fixture of maplibre-style-spec (583, embedded by `fixtures/maplibre_expression_fixtures.dart`) through the parser, one test each. The 425 MapLibre evaluates must give its outputs — read through the typed property coercions, an error matching a fallback — unless listed in `_divergences` with a reason; a listed one that starts passing fails, so the list only shrinks. Fixtures MapLibre rejects only have to compile without throwing (the parser is tolerant by design). The zoom-only and zoom-free flags are checked against MapLibre's own analysis, since the memo and filter caches trust them. Feature geometry is quantized to an 8192 extent as MapLibre's runner does, but in the tile holding the feature: tile coordinates are `Float32`. Runs in Chrome too |
| `global_state_test.dart` | `Theme.withGlobalState` end to end: a sibling theme redraws in place, never showing the background between the old and the new imagery, and the default state is the theme the map started with |
| `tile_lifecycle_test.dart` | Widget-level: first paint, zoom changes, pan, cache attachment, disposal. The heaviest and most integration-shaped test |
| `app_lifecycle_raster_test.dart` | The app-backgrounding defence: no rasterizing below `resumed` on iOS, an unfocused (`inactive`) window rendering on every other platform, parked work resuming, re-rasterization and cache distrust after a departure (including by a layer mounted only after the return), and an `inactive`-only interruption costing nothing. Drives lifecycle with `tester.binding.handleAppLifecycleStateChanged`; note that `pump()` is inert from `hidden` on, because the scheduler disables frames there — the assertions that need frames use `inactive` |
| `symbol_layouter_test.dart` | Label placement candidates, tile-seam behaviour, overzoom |
| `placement_order_test.dart` | Which of two colliding labels of one layer wins: the layouter's source tile, feature index and part, and the label pass placing in MapLibre's tile and feature order rather than by screen position |
| `raster_source_test.dart` | Raster sources declared inside vector styles, image ref-counting |
| `hillshade_test.dart` | `hillshade` layers and `raster-dem` sources: reading (spec defaults, per-light arrays, the light cap, `StyleReader` encodings), the renderer's geometry (`neighbourKey`, `neighboursNeeded`, `slopeScale`, `latitudeOf`), shading through the real shaders against MapLibre's formula (uniform slope, seamless edges with neighbours vs a flat border without, which side is lit for west/north light, multidirectional averaging, overzoom sub-squares, zoom-out descendants, nothing before the shaders load), and a widget test whose seam check fails if neighbours are not loaded. DEM tiles are synthetic Terrarium images, served to the map as BMPs (encoded synchronously, so inside fake async). The shading groups skip on Chrome: `flutter test --platform chrome` serves no assets, so no shaders |
| `tile_store_test.dart` | Memory/disk cache keying, miss paths, disposal, stale-while-revalidate (expired entries served instantly, `onRefreshed` on changed content only, corrupt expired entries refetched, `revalidateIfStale` for results served without the stores); a store's filter plan resolved by native workers and by the UI isolate on web, and a tile cached for another theme serving this one |
| `curved_text_test.dart` | Text along lines and the sharp-bend fallback; the upright guard on a hairpin (dropped on a pass, drawn straight on a replay, kept without `text-keep-upright`, no false rejection near vertical); every along-line symbol fitting on its line, shields and straight-drawn scripts included (dropped on a pass, kept on a replay); `trimCaches` keeping the on-screen label's glyphs; a cluster's remembered glyph never drawn once the glyph cache has evicted it, whether by a trim or within its pass |
| `label_wrap_test.dart` | `text-max-width` wrapping, read off the collision box: a word wider than the width stays on one line, words still wrap between them; `LabelPainter.breakAroundWideRuns` giving a wide word a line of its own while the words around it wrap at the width, and keeping explicit line breaks |
| `label_wrap_test.dart` | `text-max-width` wrapping, read off the collision box: a word wider than the width stays on one line, words still wrap between them; `LabelPainter.breakAroundWideRuns` giving a wide word a line of its own while the words around it wrap at the width, keeping explicit line breaks, and moving a cluster of several code units that opens a line to that line whole |
| `glyph_text_test.dart` | The pure-Dart glyph path: `decodeGlyphPbf` (every field, negative offsets, unknown length-delimited fields skipped — the regression of a misaligned skip — later stacks only filling gaps, truncation), `isGlyphShapeable` for every script of the script suite (Latin with diacritics, Cyrillic, Greek, Armenian, Georgian to glyphs; RTL, mixed bidi, Indic, Thai/Lao/Khmer/Myanmar/Sinhala/Tibetan, CJK, kana, Hangul, emoji/ZWJ, combining marks, variation selectors to the platform), `shapeGlyphs` (advances, letter spacing, missing glyphs, ZWSP, centred lines 1.2 em apart, `justify` and `lineHeightEm`, `justified` matching a fresh shaping, balanced breaking vs greedy, the shorter last line, unsplit wide words, hyphen breaks) and `glyphRangeUrl` |
| `glyph_label_test.dart` | The label painter's glyph path with a synthetic box-glyph font: collision boxes from glyph advances, pixels of fill and halo where the metrics put them (only pixels clear of the 1.68 px edge ramp are asserted), `text-justify` (with `auto` following a variable anchor) and `text-line-height` on glyph lines, a blurred halo fading over more pixels than a sharp one (compared render to render, never against fixed pixels), atlas cells reused while the size holds, complex scripts / missing glyphs / failed ranges on the platform path, `glyphsPending` asking for each range once, platform-shaped text re-shaped once its loading ranges arrive, a glyph source swap, `paintTile` |
| `glyph_layer_test.dart` | `VectorTileLayer.glyphs` end to end, with one label on screen: held back while its range loads (no system-font flash) and drawn from the glyphs once it arrives; past the 5 s wait limit drawn by the platform and switched to the glyphs when the range finally arrives; a layer disposed while a symbols job waits letting go cleanly. Waits with a short `_untilParked`, not `settleLoads`: the wait limit runs on the fake clock, which a real-time settle advances by seconds |
| `label_painter_prewarm_test.dart` | The resumable `LabelPainter.prewarm` contract: the whole batch with no budget, the resume cursor and guaranteed progress per slice, nothing shaped twice across slices, text-less symbols advancing the cursor; and the text cache holding a z15→z17→z15 round trip without re-shaping |
| `label_painter_dispose_test.dart` | Text-cache eviction deferring `TextPainter` disposal past the live frame; `trimCaches` keeping the text on screen, what the pump shaped after the last placement pass and the on-screen losers a replayed frame skipped, and releasing the rest |
| `icon_rotation_test.dart` | `icon-rotate`/`icon-rotation-alignment`, anchor/offset pivot semantics, and rotated collision bounds |
| `label_repeat_test.dart` | Screen-space line-repeat suppression, layer priority, and invisible/gated fallback candidates |
| `sdf_icon_test.dart` | SDF sprite tinting |
| `sprite_packer_test.dart` | Sprite sheet repacking: a magnified icon from an edge-to-edge sheet picks up its neighbour (the control) and from the padded sheet does not; byte-exact copies inside a transparent gutter; aliases, flags and off-sheet sprites; a sprite hanging off the sheet keeps its whole cell; a packed sheet over 4096 px on either side keeps the original; a failed pixel decode errors instead of hanging |
| `tile_retention_test.dart` | The pure retention predicates (17 cases) |
| `descendant_substitution_test.dart` | Zoom-out substitution: the `findDescendants` walk (partial cover, depth and maxzoom bounds), descendant rasterization into sub-squares with buffer-spill clipping (vector and raster sources), and widget-level: a reopened map below the cached level paints from descendants while its own tiles never arrive |
| `theme_reader_test.dart` | Layer parsing and MapLibre spec defaults; `filterReadsZoom` for absent, legacy, expression and zoom-reading filters (including `let`/`step`/`case`/`interpolate` and zoom-keyed legacy functions inside an expression); `readsGeometry`; global state — the root `state` defaults, siblings, the same instance per state, null restoring a default, a style without global state returning itself |
| `matched_features_test.dart` | Zoom-free filters resolved once per prepared tile: cached matches equal a full scan, a zoom-reading filter is never cached and still flips across zooms, and later display tiles of one data tile — rasterizer and symbol layouter alike — evaluate no filter (counted through a property map that tallies reads, not a hook in the renderer) |
| `feature_state_test.dart` | `FeatureStates` (MapLibre merge semantics, a set that changes nothing, ids matched as MapLibre matches them, removal by key/feature/source layer, versions never shared between stores), the controller's state API and a detached controller, and the `feature-state` expression (null without state, computed keys, `let`, never zoom-memoized, `readsFeatureState` per layer) |
| `feature_query_test.dart` | Hit geometry (`HitArea`: holes, edge crossings, line half-widths, circles, rotated boxes, clipping, packed `LabelHit`s, a zero-area rectangle acting as a point rather than containing everything) and `FeatureQuery.hitTile` deciding as the rasterizer draws — widths at the tile zoom with casing, filters and zoom ranges, overzoom windows, descendants clipped to their extent — plus `drawsAny` finding only the display tiles a feature reaches |
| `rendered_features_test.dart` | Widget-level `VectorTileLayerController`: point queries topmost first (labels, then geometry), layer ids, the background answering nothing, a seam-crossing rectangle reporting a feature with an id once, a rotated map queried where it is drawn (checked against the pixel), `retainAllProperties`, tile-mode labels, a curved label drawn from the style's glyphs (found on it, not just off it); feature state re-rendering only the two tiles that draw the feature with no label re-laid out, nothing re-rendered for a no-op or for state no layer reads, the finished-tile cache never serving a stateful render (state cleared while the tiles were gone), a promoted id, a controller handed over bringing its state, queries and state still answering after `clearMemoryCache` and for tiles served from the finished-tile cache with their decoded data gone, a keyed remount keeping the controller, a controller added to a tile-mode layer finding its labels, a render that outlives a state change (zoom crossing mid-render, then cleared) never cached with the old state (fails without the version stamp and the current-tile guard), no image or picture leaked; and a screen label's text style following state at a steady zoom (the memo's state version). Sizes the test view before counting allocations: resizing it disposes a picture of the old root layer |
| `promote_id_test.dart` | `PromoteId.parse` (both spec shapes), decode replacing ids with the promoted property (numbers, strings, booleans as 1/0, absent as none) while other source layers keep theirs, stores promoting different properties keeping separate caches, and `StyleReader` reading `promoteId` |
| `matched_features_test.dart` | Zoom-free filters resolved once per prepared tile: cached matches equal a full scan, a zoom-reading filter is never cached and still flips across zooms, and later display tiles of one data tile — rasterizer and symbol layouter alike — evaluate no filter (counted through a property map that tallies reads, not a hook in the renderer); worker matches are read without evaluating the filter, and one the worker did not resolve is scanned as before |
| `tile_filters_test.dart` | Worker filter resolution: worker-resolved matches equal a UI-side scan on Liberty's real filters (`fixtures/liberty_layers.dart`) and on a filter-heavy synthetic style, over random features whose values come from the filters' own literals; `FilterIds` interning; only zoom-free filters of source layers get an id; zoom-reading filters stay per display tile; a `global-state` filter gets no id and its UI-side matches follow a state change on a tile prepared under the old state; a geometry-reading (`within`) filter gets no id; a tile prepared for another filter falls back; match lists counted in `byteSize`; the web executor resolves none; `TileFilterPlan`'s zoom bands |
| `line_pattern_test.dart`, `fill_pattern_test.dart` | Pattern paints; a `line-color` reading only `["id"]` or `["geometry-type"]` evaluated per feature, not shared across the tile |
| `fill_extrusion_test.dart` | `fill-extrusion-opacity` per layer: overlapping buildings blended once (constant colour, per-feature colour and patterned), the alpha of `fill-extrusion-color` ignored (constant and per-feature), a plain fill as the double-blend control, no outline on extrusions, a colour reading only `["id"]` or `["geometry-type"]` evaluated per building, and a building decoded from bytes wound the wrong way still filling its overlap (the decoder's winding fix, end to end) |
| `fill_outline_test.dart` | `fill-outline-color` dimmed by `fill-opacity` (constant and per-feature, multiplying the outline's own alpha), hidden at opacity 0, untouched by the alpha of `fill-color`, evaluated per feature when it reads only `["id"]`, one device pixel wide at pixel ratios 1 and 3, off under `fill-antialias: false`. The square's edge sits on a pixel-column centre so the outline covers exactly one column |
| `paint_properties_test.dart` | The geometry paint and layout properties beyond colour, width and opacity, pixel by pixel: `*-translate` (constant, a zoom-interpolated `[x, y]`, a legacy stop function, a feature translated in from beyond the cull window, a pattern moving with its fill, flat extrusions), `line-offset` (sides, polygon inset with a closed corner, per feature), `line-blur` compared row by row with MapLibre's ramp at dpr 3 (full ramp, a line narrower than twice its blur, a sub-pixel blur keeping its ink, batched or drawn per feature, a layer-wide opaque blur drawn as one path matching per-feature drawing, per feature, a blurred casing keeping its gap; and two Impeller faults — a blurred axis-aligned dashed line still drawing, a blurred bent casing keeping its casing — which only fail under `flutter test --enable-impeller` without the workarounds), `line-miter-limit` (the spec default bevels a 40° turn Skia's own default would miter; a negative limit bevels too), `*-sort-key` (higher key on top, ties in source order, a zoom-reading key re-sorting per zoom), circles (stroke outside the radius, a translucent stroke not covering the fill, `circle-blur` 1 and 0.5, a blurred fill blending into its stroke), `background-pattern` (and its colour fallback, and no gap colour), `resampling`/`raster-resampling`, and the reader leaving every new property null when unset |
| `disk_cache_test.dart`, `lru_cache_test.dart` | Cache eviction, TTL, size sweep |
| `style_reader_cache_test.dart` | Stale-while-revalidate style loading |
| `style_reader_glyphs_test.dart` | VM-only: a style's `glyphs` becoming `Style.glyphs` (signature = the resolved template), range 0 of each constant `text-font` asked for up front and data-driven stacks not, no source without `glyphs`, ranges served from the style cache offline (and a never-fetched range failing cleanly), `mapbox://fonts/…` expansion |
| `style_reader_sources_test.dart` | Source URL resolution: relative TileJSON/tile templates (ArcGIS `root.json` shape), `{key}` substitution |
| `redact_test.dart` | API keys out of logs: `redactKeys` per credential parameter, `monkey=` left alone, text after a URL kept; `Logger.custom` receiving redacted messages; network (403, 500, `ClientException` with `uri=`) and PMTiles provider warnings and `StyleReaderException` carrying no key |
| `label_language_test.dart` | `StyleReader.language`: the `text-field` rewrite for every shape real styles use (plain `get`, Liberty's `case` over `name:latin`/`name:nonlatin`, `concat` with a non-name suffix, `{token}` templates, zoom stop functions, names only in conditions, a name in several branches wrapped per branch while name-only branches and a `let` share one wrap), the style returned as the same object without a language, `resolved-locale` folding, labels identical to the original, and with a translation a branch keeping the ref or elevation beside the name wherever a feature has no translation, and end to end: translated label, fallback, `name:de` kept by tile prep, a distinct theme id per language |
| `attribution_test.dart` | `StyleAttribution.parse` (link spans, entities, stray markup) and the reader's collection: source over TileJSON, dedup, order |
| `pmtiles_test.dart` | PMTiles: Hilbert tile IDs (spec anchors + bijection), directory decode/lookup, range-request provider (leaves, coalescing, cancellation), `pmtiles://` style wiring |
| `pmtiles_gzip_test.dart` | VM-only: gzip-compressed archives via `dart:io` gzip; brotli/zstd rejection |
| `pmtiles_gunzip_web_test.dart` | Browser-only: `DecompressionStream` gunzip round-trip |
| `mvt_decoder_test.dart` | MVT decoding against independently built fixtures, including a polygon written the wrong way round (exterior counter-clockwise) turned over whole |
| `variable_anchor_test.dart` | Variable text anchors |
| `symbol_properties_test.dart` | Every symbol property beyond the basics, through the real painter: parsing with spec defaults (bare-number `icon-padding`, interpolated anchor-offset collections, `text-writing-mode` logged), halo blur softening the text and SDF icon halo edges (and drawing the same on every frame), `icon-optional` keeping the text and a dropped icon staying dropped on replay frames, `icon-padding`, `text-ignore-placement`, overlap modes (an allow-overlap symbol still reserving its space, `cooperative`), `symbol-avoid-edges`, `icon-text-fit` with stretch zones and a content box (pixel spans), `text-justify` (incl. `auto` and variable anchors), `text-line-height`, anchor offsets, `text-rotate`, map-aligned point text, translation, `icon-keep-upright`, `symbol-z-order`, and `paintTile` drawing them in `LabelMode.tile`. The test font's glyphs are solid em squares, which makes text extents exact |
| `tile_precision_test.dart` | Tile transform precision |
| `grid_layout_test.dart` | Visible tile set, load ordering, tile rects |
| `css_color_test.dart` | All CSS colour syntaxes |
| `executor_test.dart` | Executor contract: priority ordering, silent cancellation, disposal; workers resolving filters from sources sent once per worker, re-sent to a replacement worker, and a malformed tile with filters failing as before |
| `tile_key_test.dart` | Tile coordinate arithmetic and equality |
| `fade_test.dart` | Tile/label fade progress arithmetic, including sub-millisecond durations |
| `label_replay_test.dart` | Replay frames, which sort only the last pass's winners: they draw exactly what the pass placed, in the same order, whatever order the candidates arrive in, and still find a fallback to fade out a label that lost the pass |
| `label_identity_test.dart` | `LabelIdentityIndex` on its own: ids surviving a republish, a zoom crossing (point labels both ways; nested along-line anchors through the real `SymbolLayouter`) and a seam (both neighbours' copies), new ids for labels that moved too far and for same-named labels either side of a seam, the twin rule against each same-level holder's own copy, one-to-one and nearest-first matching, holders and release. Every case runs twice, scanning names and looking them up by position (`gridFrom: 0`), and a common name of hundreds of icon-only labels must get the same ids both ways |
| `label_identity_layer_test.dart` | The identity index through a real layer: labels keep their ids through zoom crossings into overzoom and back, every id a tile takes is handed back across pans and crossings (`VectorTileLayer.debugLabelIds` held == offered), and `LabelMode.tile` holds none until screen mode takes them up again |
| `label_continuity_test.dart` | Per-label fade and placement continuity by label id, including idle repaints not creating placement debt, clearing an in-progress fade when `labelFadeDuration` is disabled at runtime, a republished winner drawn from its first frame, copies of one label drawing once (also where `*-allow-overlap` means nothing collides), and which copy draws: the one the pass drew on replays, the one already drawn on the next pass, and the ghost from the copy last drawn |
| `show_labels_test.dart` | End-to-end label enable/disable, sub-millisecond fades and fade-ticker settlement on an unchanged map, and `VectorTileLayer.clearMemoryCache` trimming an open map's label text to the labels of its tiles (counted as live `TextPainter`s), the buffer ring's text kept so a pan after a trim shapes none of it again |
| `label_mode_test.dart` | `LabelMode.tile`: `paintTile` edge drops (allow-overlap too), in-tile collision and untouched screen-pass state; widget-level, labels baked with no per-frame pass, rotating with the map (upright in screen mode), the result cache kept apart per mode, a layer starting halfway into the level laid out in screen mode but not in tile mode, `showLabels` re-rendering, and image/picture leak counting that also holds on web (see below); and, with `VectorTileLayer.debugPumpBudgetMicros = 0` (one layer or label per frame), the same map in both modes as with the normal budget, every recording spread over one frame per layer, tile mode's label placement, drawing and snapshot never sharing a frame with shaping, a `clearMemoryCache` trim mid-shaping still finishing every tile (queued shaping rewound), no slice leaked by a layer disposed mid-recording, a refresh finishing each recording before starting the next, and a pixel ratio change between a tile-mode tile's two phases neither showing nor caching a tile with part of its geometry; and the first frame of a camera move pumping on the moving budget (`VectorTileLayer.debugPumpCameraStill`) |
| `heatmap_test.dart` | Heatmap style compilation (spec defaults, a `heatmap-color` ramp evaluated per density rather than memoized by zoom, which properties read the zoom), the density grid against the closed-form kernel (peak, fall-off, reach) and the separable blur against a brute-force sum within 2 %, colouring (density interpolated before the ramp, premultiplied packing), a whole `renderHeatmap` job (nothing that counts gives no image, the result snapped to the cell lattice and covering the cover, a skip mask leaving out its squares), the painter over real images (two tiles' points add up, a skip mask removes them), and layout: a point in exactly one display tile across seams and buffers, points only, per-feature weights evaluated once and zoom-reading ones per zoom |
| `heatmap_layer_test.dart` | Widget-level heatmaps through a real `FlutterMap`: a cluster's density drawn at the expected radius (a `step` ramp makes the 0.5 contour a hard edge), and a kernel reaching across a tile seam |
| `render_job_queue_test.dart` | Render pump queue: phase-major and tile-major pop order, a resumed job winning a tie (but not against a more central fresh one), replacement and supersede, `symbolJobs` listing only the queued symbols jobs |
| `sprites_change_test.dart` | A sprites change during a zoom crossing: the outgoing level's queued jobs (a half-done sliced recording, a tile-mode label job holding geometry, a symbols job about to cache an earlier image) never publish or cache old patterns under the new sprites; gated providers hold z14/z15 back so the level stays retained |
| `sliced_recording_test.dart` | `TileRasterizer.recordSlice` / `compose`: one layer per slice stacks into exactly the pixels one `record` makes (a translucent line over a fill shows any reordering), symbol and out-of-zoom layers get no slice of their own, a slice always makes progress, and a sliced tile still counts as one rasterization |
| `sprite_atlas_signature_test.dart` | `SpriteAtlas.signature` — equal sheets agree, different ones do not (the render-signature cache key) |

## Subdirectories

| Directory | Purpose |
|-----------|---------|
| `fixtures/` | Test data builders (see `fixtures/AGENTS.md`) |
| `scripts/` | Labels in 23 scripts drawn through the real label painter with bundled Noto subset fonts: structural pixel tests (VM and Chrome) and goldens (VM, tolerant of rasterizer differences). Excluded from the package by `.pubignore` (see `scripts/AGENTS.md`) |

## For AI Agents

### Working In This Directory

- **`tile_lifecycle_test.dart`'s "reopened map paints from cache" case is known
  to flake under parallel test load** (the memory caches are process-wide).
  Re-run it before concluding a regression exists.
- Prefer `MemoryVectorTileProvider` over network stubs; where HTTP is genuinely
  under test, inject an `http.Client`.
- **Test the interface, not the implementation** — especially for the executor,
  where two platform implementations must satisfy one contract.
- Every bug fix gets a regression test. Several tests here exist because a
  specific rendering bug shipped once (SDF blobs, duplicate seam labels, zoom
  jitter); name new ones after the behaviour, not the bug number.
- Widget tests must dispose the map and assert no images leak — image ownership
  bugs are the most common defect class in this package. `label_mode_test.dart`
  shows how: count `FlutterMemoryAllocations` creations against disposals of
  `ui.Image`/`ui.Picture`. Count, don't match by identity — on web an image
  reports one creation for all its clones and one disposal, through whichever
  handle went last — and ignore the test's own `RepaintBoundary.toImageSync`
  snapshots, of which the web engine keeps a picture.

### Testing Requirements

```
flutter test                       # whole suite
flutter test test/foo_test.dart    # one file
```

The suite must be green and `flutter analyze` clean before any release. CI
(`.github/workflows/ci.yml`) runs both, plus the Chrome suite, on every push
to `main` and every PR. A red run on the "reopened map paints from cache"
case is the known flake above; re-run the job before chasing it.

### Common Patterns

- Plain `test()`/`testWidgets()` with `expect` — no mocks, no code generation.
- Fixtures are built in-test from `fixtures/mvt_builder.dart` rather than
  checked in as binary blobs, so the input to a failing test is readable.
- Widget tests wait on the wall clock (`pumpUntil` / `settle` / `settleLoads`
  from `fixtures/lifecycle_harness.dart`), never on a fixed number of pumped
  frames — see `fixtures/AGENTS.md` for why a frame count silently becomes a
  shorter deadline under parallel load.
- Fixture encoders must be web-safe too. `mvt_builder.dart`'s `zig()` uses
  arithmetic, not `(v << 1) ^ (v >> 31)`: under dart2js the shift form
  mis-encodes negative deltas, which would make the decoder's round-trip
  tests pass on chrome for the wrong reason.

## Dependencies

### Internal

- The package under test, including `src/` internals

### External

- `flutter_test`, `flutter_map` (for widget tests)

<!-- MANUAL: -->
