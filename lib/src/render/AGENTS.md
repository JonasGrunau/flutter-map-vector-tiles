<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-08-09 | Updated: 2026-10-26 -->

# render

## Purpose

All drawing, split along the package's central design line: **geometry is
rasterized once per display tile into a GPU-resident image; by default
labels and icons are not baked in** — they are laid out per tile and drawn
every frame in screen space with one global collision pass. That split is
why text stays crisp at fractional zoom, upright under rotation, and never
duplicates or clips at tile seams. `LabelMode.tile` is the opt-in
exception: the same painter places and draws a tile's labels once, into
that tile's raster (`LabelPainter.paintTile`), trading those properties
for frames with no per-frame label work in them.

## Key Files

| File | Description |
|------|-------------|
| `tile_rasterizer.dart` | `TileRasterizer.paint()` — draws background/fill/line/raster/hillshade/circle layers of one display tile into a `Canvas` (turned into an image by `toImage`, i.e. `Picture.toImageSync`). The layer records only through `recordSlice`, which is `record` spread over calls: it stops at a layer boundary once its `outOfBudget` says so (after at least one layer that draws, and never just before layers that draw nothing), returns the cursor to resume from, and `compose` stacks the slices into the picture one `record` would have made — the render pump records every tile this way, a dense one over several frames. In `LabelMode.tile` the composed picture goes to the symbol job the raster job enqueues (`_RenderJob.geometry`), which draws the labels over it before `toImage`. `rasterize` (= `record` + `toImage`) and `record` remain for tests and benchmarks. Iterates the `MatchedFeatures` of zoom-free filters (only a zoom-reading filter is still evaluated here), culls features on their decode-time bounds against the display window (+64px buffer) before any other expression work, clips geometry to the window from overzoom shift 2 — and descendant tiles standing in on zoom-out to their own extent, unconditionally — and handles fill outlines as MapLibre draws them (dimmed by `fill-opacity`, one device pixel wide via the `pixelScale` the recording canvas is scaled by, off under `fill-antialias: false`), fill, line and background patterns, dash arrays (phase-anchored to the un-clipped run start), `*-translate` folded into the `_TileTransform` (so the cull and clip windows follow the geometry; patterns are shifted with it), `*-sort-key` order (cached weakly per feature list, layer and zoom, like the filter matches), `line-offset` (`_offsetRun`, per run in logical px after clipping), `line-blur` (a narrowed stroke under a Gaussian mask filter, see `_blurFilter`), `line-miter-limit` (Skia's default is 4, the spec's 2), circle strokes outside the radius and `circle-blur` as a radial gradient (`_blurredCircle`), `resampling`, `fill-extrusion` per spec in `_paintExtrusion` (`fill-extrusion-opacity` per layer rather than per feature, the alpha of `fill-extrusion-color` ignored, no outline; one non-zero union path when the colour reads no feature, a composited `saveLayer` when it varies by feature or the layer is patterned), raster colour matrices, and the `_TileTransform` from tile-extent units to logical pixels (both directions: ancestor sub-window at overzoom, descendant sub-square under zoom-out substitution). Fetches a source layer's feature-state map once per layer, only for layers that read state (`ThemeLayer.readsFeatureState`). `displayTransform` exposes the draw transform for queries |
| `matched_features.dart` | `MatchedFeatures.of(layer, sourceLayer, tile:)` — the features a zoom-free filter (`ThemeLayer.filterReadsZoom` false) selects, in source order, resolved on first use and cached in an `Expando` on the `PreparedSourceLayer`: one filter scan per data tile instead of one per display tile cut from it, the entry living exactly as long as the prepared tile. Keyed by layer identity, so a theme swap misses — and through a second `Expando`, so both levels are weak: a swapped-out theme's layers and their match lists are not kept alive by the decoded tiles still in the cache. Keep it that way; a strong map keyed by `ThemeLayer` held every previous style alive on each cached tile. Returns null for zoom-reading filters, which the callers evaluate per display tile; an unfiltered layer gets the source list itself. Also `featureGeometry(tile, sourceLayer, feature)`, the `FeatureGeometry` that `within` / `distance` read; every evaluation site (filter matching here, the rasterizer, the symbol layouter, the heatmap layouter, `SymbolInstance.geometry` for the label pass) builds it only when `ThemeLayer.readsGeometry` and evaluates through `featureContext`, so the layers that do not read geometry allocate neither it nor the larger `FeatureEvalContext` |
| `tile_rasterizer.dart` | `TileRasterizer.paint()` — draws background/fill/line/raster/hillshade/circle layers of one display tile into a `Canvas` (turned into an image by `toImage`, i.e. `Picture.toImageSync`). The layer records only through `recordSlice`, which is `record` spread over calls: it stops at a layer boundary once its `outOfBudget` says so (after at least one layer that draws, and never just before layers that draw nothing), returns the cursor to resume from, and `compose` stacks the slices into the picture one `record` would have made — the render pump records every tile this way, a dense one over several frames. In `LabelMode.tile` the composed picture goes to the symbol job the raster job enqueues (`_RenderJob.geometry`), which draws the labels over it before `toImage`. `rasterize` (= `record` + `toImage`) and `record` remain for tests and benchmarks. Iterates the `MatchedFeatures` of zoom-free filters (only a zoom-reading filter is still evaluated here), culls features on their decode-time bounds against the display window (+64px buffer) before any other expression work, clips geometry to the window from overzoom shift 2 — and descendant tiles standing in on zoom-out to their own extent, unconditionally — and handles fill outlines as MapLibre draws them (dimmed by `fill-opacity`, one device pixel wide via the `pixelScale` the recording canvas is scaled by, off under `fill-antialias: false`), fill, line and background patterns, dash arrays (phase-anchored to the un-clipped run start), `*-translate` folded into the `_TileTransform` (so the cull and clip windows follow the geometry; patterns are shifted with it), `*-sort-key` order (cached weakly per feature list, layer and zoom, like the filter matches), `line-offset` (`_offsetRun`, per run in logical px after clipping), `line-blur` (a narrowed stroke under a Gaussian mask filter, see `_blurFilter`), `line-miter-limit` (Skia's default is 4, the spec's 2), circle strokes outside the radius and `circle-blur` as a radial gradient (`_blurredCircle`), `resampling`, `fill-extrusion` per spec in `_paintExtrusion` (`fill-extrusion-opacity` per layer rather than per feature, the alpha of `fill-extrusion-color` ignored, no outline; one non-zero union path when the colour reads no feature, a composited `saveLayer` when it varies by feature or the layer is patterned), raster colour matrices, and the `_TileTransform` from tile-extent units to logical pixels (both directions: ancestor sub-window at overzoom, descendant sub-square under zoom-out substitution) |
| `matched_features.dart` | `MatchedFeatures.of(layer, sourceLayer, tile:)` — the features a zoom-free filter (`ThemeLayer.filterReadsZoom` false) selects, in source order, resolved once per prepared tile and cached in an `Expando` on the `PreparedSourceLayer`: one filter scan per data tile instead of one per display tile cut from it, the entry living exactly as long as the prepared tile. On native platforms the scan already happened on the worker: the first use gathers the features at the indices `PreparedSourceLayer.matches` holds under `ThemeLayer.filterId` (null there = every feature, the source list itself). Only where no worker resolved the filter — web, a hand-built layer, a filter reading `global-state` or the feature geometry, a layer drawing the tile outside its own zoom band — is it evaluated here on first use. Keyed by layer identity, so a theme swap misses — and through a second `Expando`, so both levels are weak: a swapped-out theme's layers and their match lists are not kept alive by the decoded tiles still in the cache. Keep it that way; a strong map keyed by `ThemeLayer` held every previous style alive on each cached tile. Returns null for zoom-reading filters, which the callers evaluate per display tile; an unfiltered layer gets the source list itself. Also `featureGeometry(tile, sourceLayer, feature)`, the `FeatureGeometry` that `within` / `distance` read; every evaluation site (filter matching here, the rasterizer, the symbol layouter, `SymbolInstance.geometry` for the label pass) builds it only when `ThemeLayer.readsGeometry` and evaluates through `featureContext`, so the layers that do not read geometry allocate neither it nor the larger `GeometryEvalContext` |
| `hillshade_renderer.dart` | `HillshadeRenderer.paint` — a `hillshade` layer for one display tile, called by the rasterizer at the layer's position. Per DEM tile (the display tile's own or ancestor's, or zoom-out descendants): a snapshot of the elevations with a two-texel border from the neighbours (`_bordered`, the tile's own edge repeated where one is missing), the prepare shader's slope snapshot from it (`_slopes`, (dim+2)² texels), then the shade shader drawn over the tile's part, per device pixel (`_shade`). `neighbourKey` (antimeridian wrap, null past a pole) and `neighboursNeeded` (all eight, or the touched edges at overzoom) are shared with the layer; `slopeScale` (texel size + MapLibre's below-z15 exaggeration) and `latitudeOf` are pure and unit tested. `HillshadePrograms` loads both programs once per process (`packages/…` key first, the bare key for the package's own tests) and is read synchronously via `loaded`; null means not yet or never (no fragment programs), and the layer draws nothing then. Web-only branch in `_shade`: CanvasKit keeps a pointer to a `FragmentShader`'s uniforms and `dispose` frees them, so there the shade pass is snapshotted at once and the tile records the image |
| `geometry_clipper.dart` | `clipPolyline` (segment-wise Liang–Barsky, emitting sub-runs plus their distance from the original run start for dash/stamp phase; with `close:` it walks the ring's closing segment and rejoins the contour that crosses vertex 0, so a stroked ring keeps its join there instead of butting two caps) and `clipRing` (Sutherland–Hodgman, winding-preserving) over tile-extent `Float32List`s — pure functions, no canvas |
| `fade.dart` | `fadeProgressOf` — elapsed fraction of a fade, in microseconds. Shared by the tile and label fades; the unit matters (see the file) |
| `label_identity.dart` | `LabelIdentityIndex` — the cross-tile symbol index: gives every symbol on offer an integer label id that outlives its `SymbolInstance`. A tile `assign`s ids when it publishes (matching each instance to the labels already on offer by continuity key and world position, within `matchRadius`, 32 logical px of the finer level), and its holder `release`s them when it stops offering them. Each label keeps one holding per tile that offers it, with that tile's copy's position; matching is one-to-one per publish and nearest-first within one name (the tile's own previous labels ahead of others'), and within one zoom level a different tile may share an id only as a seam twin of the copy *it* holds (`twinRadius`, 1 px). A name with more than `gridFrom` (16) labels — icon-only labels share an empty text, so one-way arrows or waste baskets run into the hundreds — is also filed in a per-level grid of `matchRadius` cells, and `assign` judges only the labels with a copy in the 3×3 cells around each symbol instead of scanning the name (the same candidates; the tests run every case both ways). The layer owns one per state, holders are current/retained tiles and parked ghost cohorts, and ids live in a parallel `Int32List` per holder (`_DisplayTile.labelIds`), never on the shared `SymbolInstance`s the finished-tile cache hands to other layers |
| `label_continuity.dart` | The per-label fade model, keyed by label id: `labelContinuityKey` (`(layer, text, icon)` as a pre-hashed `ContinuityKey` — position-free, the first half of a label's identity, memoized on `SymbolInstance.continuityKey`), `LabelFadeTracker` (one opacity per label id, integrated toward "placed this frame ? 1 : 0" via `beginFrame`/`show`/`sweep`; every copy of a label resumes its state, labels the index keeps apart fade apart, and resume-not-restart stops dips from becoming blinks. **Nothing may park a placed label at zero** — `sweep` drops anything at or below zero, so a state resting there is destroyed by one lost frame; see the invariant below), `PlacementThrottle` (which frames re-run the collision pass: a changed placement generation — camera or candidate set — is placed once the fade-duration interval permits, a viewport resize at once; `deferred` reports a pass owed only while the latest generation differs from the one last placed, so an unchanged replay never keeps the ticker alive), `PlacementMemory` (the choices a label is sitting on — `SittingPlacement.anchor`/`flip`/`textDropped` — keyed by label id, so they outlive the `SymbolInstance` that took them) and `drawnLabels` (the indices of a cohort whose label ids the last frame drew — retention pins outgoing cohorts to them so they can keep labels but never introduce them). Pure and clock-agnostic; the painter drives both |
| `label_painter.dart` | `LabelPainter` — the per-frame screen-space pass (~2600 lines), and `paintTile`, `LabelMode.tile`'s once-per-tile version of it (one placing pass of the same `_prepare`/`_draw` in tile coordinates, with a fresh `PlacementMemory` and repeat-anchor map swapped in for the call, no fades/throttle/incumbents, and a collision index bounded by the tile that also holds `*-allow-overlap` boxes to it — a label crossing the tile edge is dropped): text shaped once at a 16 px reference size and drawn scaled through the canvas transform — from the style's glyph PBFs when `glyphs` is set and `isGlyphShapeable` accepts the text (`_GlyphRun`: pure-Dart layout via `text/glyph_shaper.dart`, drawn from distance-field cells in the glyph atlas with per-sprite colours, halos and fills in one `drawRawAtlas`; `glyphsPending` tells the pump which ranges a tile's labels still wait for; text the platform shaped only because its ranges were loading carries `awaitedRanges` and is re-shaped from glyphs on its first lookup after they arrive), else as platform paragraphs —, grapheme clustering, halos (baked as a quantized em-ratio stroke), variable text anchors, curved text along lines (with a max-angle bail-out to an icon-only fallback), SDF icon tinting, map/line-aligned icon rotation about the symbol anchor (with rotated collision/fade bounds), upright text rotation, and repeat suppression for visible `line` text within `symbol-spacing / 2` across layers reading the same source layer — only between anchors on the *same road* (displacement along either one's line direction, never within one feature, never involving retained-level candidates), after exact zoom/opacity/collision, so a rejected candidate never hides a fallback; MapLibre's in-tile line merging was rejected because it would re-parametrize anchors per data level. Every candidate carries its label id (`PlacedSymbol.id`): one copy per id draws in a frame, the first in priority order, and later copies are skipped before any layout work. It also owns the per-label fades (a `LabelFadeTracker` keyed on the label id — so same-named POIs fade independently and a re-spaced street name, a different label at its new position, cross-fades instead of teleporting; labels no longer placed draw ghosts — laid out past the zoom gate, claiming no collision space — from a copy of their own id still on offer) compounded with the `zoomRangeOpacity` ramp out before a declared `maxzoom` into `_DrawableSymbol.opacity` and drawn via per-opacity-bucket `saveLayer`s (a bucket's bounds are the union of its members', so on a label-dense screen each one is effectively full-screen — the bucket *count* is the cost, but see the invariant below before trading anything for it: a key on its first frame takes the one-step floor rather than drawing at zero), the throttled placement (a `PlacementThrottle` decides pass vs replay; replay frames sort and prepare only the copies of `_winners`, the last pass's label ids — everyone else goes straight to the fade-out fallbacks, unsorted — and use `_CollisionIndex.permissive()`, so the frozen decision is reproduced rather than re-derived), `prewarm()` for shaping a tile's labels inside the render pump — **resumable**, taking a `from` cursor and an `outOfBudget` predicate and returning where to continue, because shaping one dense tile costs several times a whole frame's render budget; its caller must not publish a batch as placement candidates before it completes, or the label pass will shape the remainder during paint, and `_CollisionIndex`, a grid-bucketed screen-space collision index (which is where tile-seam duplicates are removed — the layouter deliberately lets both neighbours claim a feature on the seam rather than risk neither doing so). Evaluates at a 1/8-level-quantized zoom so its memos survive pinch gestures. For rendered-feature queries it keeps the last frame's drawables (`_lastDrawn`, a reference, nothing computed) and works out their quads only when `hitTestLabels` asks (`_DrawableSymbol.hitQuads`: icon turned about its pivot, text box, a box per curved glyph); `paintTile(hits:)` reports a tile's drawn labels as `LabelHit`s instead. `featureStates` feeds `featureContext` (a `FeatureEvalContext` for a feature with state) for layers that read it, and `TextStyleMemo.stateVersion` makes the memo's fast path re-evaluate after any state change |
| `glyph_atlas.dart` | `GlyphAtlas` — glyphs rasterized once per style, glyph and snapped device size onto 1024² pages (shelf-packed, LRU page eviction that never evicts a page the current frame drew from, one `toImageSync` per touched page per frame): curved paragraph text's graphemes, and every glyph of text drawn from the style's glyph PBFs as white coverage thresholded from its distance field. `generation` changes whenever cells are lost, so a label can keep its cells across frames and check them with `use` instead of a lookup per glyph |
| `symbol_layouter.dart` | `SymbolLayouter.layout()` — extracts label/icon placement candidates (`SymbolInstance`, with its `TextStyleMemo` label-pass memo; placement state deliberately lives in `PlacementMemory` instead, since instances are replaced under labels that stay on screen) from a prepared tile: polygon centroids, line midpoints, and spaced placements along lines via `SymbolPath` (precomputed cumulative lengths, `pointAt`/`angleAt`). Each instance records where it comes from (`sourceTile`, `featureIndex`, `part`), the label pass's placement order. Iterates the `MatchedFeatures` of zoom-free filters, as the rasterizer does, and bounds-culls features before any other expression evaluation; along-line targets are enumerated only within the tile window while keeping their full-line parametrization. Gates layers by zoom-band intersection (`coversZoomBand`) — the precise per-frame cut and repeat suppression are the label pass's job — or, with `exact` (`LabelMode.tile`, whose `paintTile` gates at the tile's own zoom), by `coversZoom` at that zoom. `anySymbolLayerCovers()` (same `exact` switch) lets the render pump skip the symbol phase when no symbol layer intersects the tile's band |
| `display_tile_data.dart` | `DisplayTileData` — the prepared data backing one display tile, per style source, plus its raster tiles and any descendant tiles composing a provisional zoom-out cover (geometry only; the symbol layouter never sees descendants). Also carries the `FeatureStates` layers reading `feature-state` are drawn with |
| `heatmap_layouter.dart` | `HeatmapLayouter.layout` — a display tile's points per heatmap layer (`HeatmapPoints`, logical tile coordinates), run where the tile's image publishes and cached with it. A point counts only inside its data tile's own extent and only in the display tile whose (half-open) window holds it, so each is summed exactly once per level. Weights and radii that read the feature but not the zoom are evaluated here; ones that read both are re-evaluated per pass zoom (`weightsAt`/`radiiAt`); point features only, like circle layers |
| `heatmap_density.dart` | `HeatmapGrid` — the spec density (`weight·intensity·exp(−½(3d/r)²)/√(2π)`) sampled at cell centres, filled per batch by whichever is cheaper, a direct kernel sum or a bilinear splat plus separable Gaussian blur; `colorize` interpolates the density up to the output before the ramp lookup; `cellFor` picks σ/2 cells, never finer than a quarter of the device resolution. `HeatmapJob` (a pass for one layer as plain data: the cover, one `HeatmapTileInput` per tile — offset, scale, point/weight/radius arrays, skip mask) and `renderHeatmap`, which places, culls and buckets every point, sums and colours: everything per point, on the worker. Pure arithmetic, no `dart:ui` |
| `heatmap_worker.dart` (+ `_isolate`, `_inline`) | `HeatmapWorker.render(job)` — `renderHeatmap` on one long-lived isolate on native (spawned on the first job; spawn failure or a dead isolate falls back to / respawns on the event loop), inline after a yield on web. Null on dispose or failure, never an error |
| `heatmap_painter.dart` | `HeatmapPainter` — screen-space heatmap layers between the tile images and the labels. A throttled *pass* (zoom, tiles or screen changed and 100 ms since the last, at once when the viewport left the image, never two in flight) lists the tiles for the worker — nothing per point runs here but weights that read both feature and zoom — and uploads the pixels via `decodeRgbaPixels`; every frame draws the last image under the camera transform with `heatmap-opacity`. A retained tile carries a skip mask (`HeatmapTile.skip`) rather than a predicate, so the rule travels to the worker. `debugPassCount`/`debugPassMicros` count the UI-thread part |
| `feature_query.dart` | `FeatureQuery.hitTile` — the geometry half of a rendered-feature query: which features of fill/line/circle layers a display tile draws under a `HitArea` (in its logical pixels), decided as `TileRasterizer` draws them (layers gated at the tile's style zoom, the same filters and `MatchedFeatures`, widths with casing and circle radius + stroke evaluated at that zoom, non-zero fill, descendants clipped to their extent, opacity ignored as in MapLibre). Maps the query into extent units with `TileRasterizer.displayTransform` rather than features into pixels. `FeatureQuery.drawsAny` — whether a display tile draws any of a set of feature ids (an `Expando`-held per-source-layer index by normalized id, then bounds against the tile window + `cullBufferPx`), which decides the tiles a state change re-renders |
| `hit_test.dart` | `HitArea` — a point or convex polygon with the tests queries need: non-zero point-in-polygon plus edge crossings for fills (edges beside the area's bounds skipped, one winding pass after them), distance to segments for lines, circles, separating-axis for convex label boxes, Sutherland–Hodgman `clipTo`. A polygon with no area contains nothing — its edges are tested anyway — so a zero-size rectangle is a point, not the whole plane. `LabelHit` — a tile-mode label's quads packed into a `Float32List`; `rotatedBox`/`rotatedRect` build the quads |
| `pattern_resolver.dart` | `PatternResolver` — crops `fill-pattern` / `line-pattern` sprites out of the atlas into standalone images suitable for a tiled `ImageShader` |

## For AI Agents

### Working In This Directory

- **Heatmaps never go into the tile images.** A kernel reaches across
  tile seams, so the density is summed over every visible tile's points
  in screen space (`heatmap_painter.dart`), as MapLibre does; the
  rasterizer skips heatmap layers before its budget check, like symbol
  layers. Two things keep the sum right: a point is laid out by exactly
  one display tile per level (never from a neighbour's buffer), and a
  retained level contributes only where the current level has no
  points yet — break either and the density doubles along seams or
  across a crossing. The density arithmetic stays pure Dart over typed
  lists, so it can run on the worker; anything needing `dart:ui` goes
  in the painter.
- **Labels never go through `tile_rasterizer.dart`.** Anything that must stay
  crisp under fractional zoom, stay upright under rotation, or participate in
  global collision belongs in `label_painter.dart`. `LabelMode.tile` does put
  labels into the tile image, but by drawing `LabelPainter.paintTile` over the
  rasterizer's recorded picture — one text stack for both modes. Do not add a
  second one, and do not draw symbol layers in `TileRasterizer.paint`.
- **Collision is global across tiles** in the default mode. The
  `_CollisionIndex` is built once per placement pass for the whole screen
  (replay frames in between use a permissive one), then every tile's
  candidates are tested against it. Per-tile collision would
  reintroduce duplicate labels at seams — the exact bug this design exists to
  prevent. `paintTile` is per-tile by definition, which is why its index is
  bounded by the tile: dropping every label that would cross the edge is what
  keeps a per-tile pass free of half-labels and duplicates (at the price of
  gaps along seams, the documented trade-off).
- **`paintTile` carries no state between calls.** A tile's image must be a
  pure function of its candidates, or the finished-tile cache would serve
  images that depend on what was rendered before them. It swaps in a fresh
  `PlacementMemory` and repeat-anchor map for the call and restores the
  screen pass's afterwards; anything new that `_prepare` remembers across
  candidates has to be swapped the same way.
- **`_TileTransform` is where overzoom lives.** It maps a *data* tile's extent
  coordinates into a *display* tile's logical pixels, including the subdivision
  offsets used when overzooming. Off-by-one here shows up as hairline seams.
- **Never reset dash/stamp phase at clip boundaries.** Clipped sub-runs carry
  their distance from the un-clipped run start (`ClippedRuns.startDistances`),
  and `_dashRun`/`_stampLinePattern` resume the pattern there — otherwise
  dashes and stamps tear at every display-tile seam at overzoom.
- **Dashes are walked over coordinates, not `PathMetrics`.** `_dashRun` emits
  dash segments by plain arithmetic on the polyline `Float32List`s;
  `extractPath` per dash was thousands of engine calls (and one `Path`
  allocation each) on a dense footpath tile — the z15–16 zoom-crossing jank
  the bench caught. Tile geometry is polylines only, so the outputs are
  pixel-equivalent; keep it that way if geometry ever grows curves.
- **Along-line anchor parametrization must stay global and nested.**
  Anchors sit at `mid + k·spacing` (every integer k) measured over the
  *full* line from its midpoint; windowing may skip enumeration, never
  re-base the distances, or labels jump between display tiles. The
  midpoint origin is what makes level z+1's anchors a superset of level
  z's over the same data (for a `symbol-spacing` constant across the two
  levels; a zoom-dependent spacing moves them regardless) — do not "restore" MapLibre's `spacing/2 +
  k·spacing`, which shares no anchor across a crossing and moves every
  street name at each one (`bench/test/anchor_continuity_test.dart`).
- **A tile's recording is cut only between layers.** `recordSlice`
  slices are stacked by `compose` into the picture one `record` makes,
  which holds only because each layer is drawn whole, in order, with its
  own paints, on a canvas clipped and scaled like `record`'s. Do not
  split inside a layer (a translucent layer's features would blend
  differently, and dash phases would restart) without a pixel test like
  `sliced_recording_test.dart`'s. And skip layers that draw nothing
  *before* checking the budget: a slice ending just before them costs
  the tile a frame for an empty slice.
- **Shaping is the expensive half of the symbol phase**, by an order
  of magnitude (sub-millisecond extraction against 2-9 ms of
  `prewarm` on a real city tile). That is why `prewarm` is resumable
  and why the pump slices it rather than treating a tile as one unit
  of work. Two invariants come with it: a partially shaped batch is
  never published (the label pass shapes on a cache miss, so it would
  simply reclaim the cost in paint), and `prewarm` always shapes at
  least one label per call, so a requeued job cannot spin without
  progress.

- **Fading costs render passes, not CPU.** Every distinct draw
  opacity among fading labels becomes one `saveLayer`, bounded by the
  union of that bucket's members — the whole screen, once labels are
  scattered. A `saveLayer` only *records* an op during picture
  recording, so no Dart-side stopwatch can see it; the cost lands on
  the raster thread, where a tiled mobile GPU flushes its tile buffer
  per pass. Anything that widens the spread of simultaneous opacities
  (a finer `labelOpacitySteps`, per-key fade clocks, a new ramp that
  does not quantize onto the same grid) multiplies those passes — a
  real Munich crossing peaked at 7 per frame. **Measure before trading
  anything for it.** 2.7.0 grouped arrivals into shared-opacity waves to
  get that peak down to 2, and it had to be reverted in 2.7.1. A
  back-to-back `bench/` A/B on the dpr-3 phone it was aimed at: without
  the waves, BUILD p99 4.93 ms and RASTER p99 1.93 ms; with them, BUILD
  p99 6.67 ms and RASTER p99 1.63 ms — 0% of frames over the 8.3 ms
  budget either way. The whole benefit was 0.3 ms of raster p99 nobody
  was waiting on, and the cost was labels flashing (see below). The pass
  count is a robustness margin.

- **A placed label must paint something, every frame it is placed.**
  This is the invariant the wave mechanism broke. Holding a placed label
  at zero opacity fails three ways at once, and the third is the subtle
  one: `LabelFadeTracker.sweep` drops any key at or below zero, so a
  label resting at exactly zero is destroyed by a single frame of lost
  placement and re-arrives as a brand-new key. Tiles republish
  constantly during a gesture, so that can repeat indefinitely — a label
  placed on 80 of 120 frames painted on 2. It also means a label can
  only become visible at whatever moment releases it, so a steady stream
  of arrivals appears in bursts rather than fading in; and a
  zero-opacity label still holds the collision space it won, so the map
  gets a hole nothing may fill. If you need to reduce opacity buckets,
  find a way that never parks a placed label at zero.

- **Only a placement pass may start a fade-out.** Between passes the
  winner set is frozen by label id. A republish or level swap replaces
  every instance, and the successor carries the id, so it is drawn as
  the winner it is; but a winner can still be missing for a while — its
  tile gone before the successor published, or a successor whose anchor
  moved past the match radius. `LabelFadeTracker.sweep`'s `hold:`
  (passed on replay frames) keeps such labels at their opacity, their
  ghosts drawn from any copy on offer, until a pass decides. Decaying
  through the churn window fades a label into itself at every crossing —
  the regression that added the flag. A fade a pass *has* started
  advances every frame, held or not; one step per pass would stretch a
  150ms fade across minutes.

- **Disabling label fades clears the tracker.** A no-fade paint must
  discard every tracked label, including an in-progress one. Otherwise
  `LabelFadeTracker.anyActive` stays true without any future `beginFrame`
  call to advance it, and the widget's fade ticker repaints forever.

- **An unchanged replay never creates placement debt.** Camera motion and
  candidate churn advance the placement generation. `PlacementThrottle`
  reports `deferred` only while that generation differs from the last one
  actually placed. The repaint requested by the tick that settles a pass
  carries the same generation and must leave `deferred` false; setting it
  merely because the interval has not elapsed restarts the ticker forever
  on an otherwise idle map.

- **A visible label is never evicted by a same-layer arrival.** On
  placing frames `_flagIncumbents` marks candidates whose label is
  steadily on screen (the last pass's winners, by label id — which is
  what survives republishes and level swaps), and the priority sort
  tries incumbents ahead of same-layer newcomers. Without this, every
  crossing let the arriving level's re-ranked candidates evict visible
  labels and hand the space back half a level later — the
  visible→hidden→visible twitch (`bench/` stability mode counts it as
  `blink`). Scoped to the layer on purpose: a higher style layer still
  wins, so the style author's hierarchy holds. MapLibre has no such
  rule (its passes re-elect winners from scratch, smoothed only by
  fades) — this is a deliberate divergence, argued at
  `PlacedSymbol.incumbent`.

- **`LabelPainter` quantizes its eval zoom** (1/8-level steps). Don't key
  anything on the exact fractional zoom — it changes every pinch frame.
  The quantized value is for *evaluation* only: `_prepare` takes both
  and must keep them apart. Rounding a continuous size by 1/8 of a level
  costs a fraction of a pixel; rounding a discrete cut moves the cut,
  which is why visibility is gated on the exact zoom below.
- **Symbol layer zoom range is enforced per frame**, in
  `LabelPainter._prepare` via `coversZoom` at the *exact* fractional
  style zoom; `SymbolLayouter` gates only by integer-band intersection
  (`coversZoomBand`). Moving the precise check back to layout time makes
  labels persist to the tile-grid flip and burst/vanish at thresholds;
  gating it on the quantized zoom instead moves every threshold by up
  to 1/16 of a level.
  Text whose evaluated `text-size` is below 1 px is skipped, never
  clamped up — tiny-but-visible text floods the collision grid.
- **Placement order is MapLibre's, and reads no camera.** The full
  priority is layer, incumbency (see above), `symbol-sort-key`,
  current level before retained, then MapLibre's order: the data tile
  (`SymbolInstance.sourceTile`: deepest zoom first, then x, then y),
  the feature's index in it, the anchor's part and its distance along
  that part, and last `PlacedSymbol.order` (insertion order). The
  layouter numbers features over the data tile's source layer, never
  per display tile, so the display tiles cut from one data tile agree;
  a term read from the screen (as screen y once was) would let a pan or
  a rotation swap two labels. Both sorts in `LabelPainter` are
  non-stable; `order` is unique per frame, which keeps the winner
  deterministic frame to frame. Two labels of one name — the parallel
  carriageways of a street — are two ids, and only the one on screen
  is an incumbent, which keeps the name on its carriageway when a zoom
  crossing swaps the tiles and features the two sort by. Copies of
  *one* id (seam twins, the two levels' at a crossing) draw once — but
  they can sit up to the identity match radius apart, with geometry of
  their own, so the copy is part of the decision: `_drawnCopy`
  remembers which one each label was last drawn from, replay frames
  draw that one (another copy only once it is gone),
  `_promoteDrawnCopies` tries it first on a pass (reordering only
  *within* one id, never across labels), and ghosts are drawn from it.
  Replaying whichever copy sorted first drew the copy the pass had
  rejected — a label hopping between two copies at every interval.
- **A replay frame must reproduce the pass, not re-derive it.** Anything
  a placement decides that is not a pure function of the current frame's
  geometry has to be remembered in the `SittingPlacement` `_prepare`
  looks up (`anchor`, `flip`, `textDropped`) and replayed, because replay
  frames run against a permissive collision index. A new space-dependent
  choice added to `_prepare` without one shows up as that choice
  flickering at the placement interval. The converse holds for
  *geometry-dependent rejections*: curved text's `text-max-angle` and
  the fit-on-its-line checks (curved text in `_prepareCurved`, every
  other along-line symbol, shields and arrows included, in `_fitsLine`)
  are placement decisions too, so on a permissive index (replay frames
  and fade-out ghosts) a winner is never dropped by them — the bend
  check is skipped, curved text that outgrew its line is drawn straight
  at its anchor, and anything else keeps drawing where it was.
  Re-judging them per frame made a winner vanish with no ghost (the
  ghost runs the same check): Schmuzerstraße blinked 24× per stability
  run, and street names popped out at full opacity on every zoom-out. On a pass, an incumbent gets 1.25× `text-max-angle`. The
  upright guard (no glyph of a kept-upright curved label more than
  `_uprightSlack`, 30°, past vertical) follows the same split: a pass
  rejects (`upright`), a replay or ghost draws straight. It catches
  hairpins, which pass `text-max-angle` at every step; never relax it
  for incumbents.
  `LabelPainter.debugRejectProbe` reports every such rejection for the
  bench.
- **Placement state belongs in `PlacementMemory`, never on the
  `SymbolInstance`.** Instances are rebuilt per display-tile layout, so
  anything stored on one is lost at every zoom crossing and republish —
  precisely when a label is most visibly on screen, and with its fade
  unchanged, so the re-decision lands as a hard jump. The memory, the
  fades and the winners are all keyed by label id, which the successor
  inherits.
- **Label ids come from `LabelIdentityIndex`, and every id taken is
  handed back.** A holder (`_DisplayTile`, a parked `_GhostLabels`
  cohort) takes ids when it publishes and releases them when it stops
  offering them: replaced symbols (`_setTileSymbols` passes the old ids
  as `replacing`), the retention pin, disposal, ghost expiry. A parked
  cohort takes its tile's ids over instead of re-assigning. A missed
  release keeps a label known with nothing left to draw it — it still
  matches the next copy at that place, so nothing visible breaks, but the
  index grows; `VectorTileLayer.debugLabelIds` checks held == offered.
  Do not store ids on `SymbolInstance`: the finished-tile cache shares
  instances between layers with the same style, and each layer has its
  own index. Do not quantize positions into the key instead of matching
  within a radius: a grid boundary splits a label's two copies into two
  labels, which cross-fade against each other.
- **Never put a font size (or unquantized opacity/halo width) into the
  text-shape cache key.** Text is shaped once at the 16 px reference size
  and drawn scaled; a size-bearing key re-creates the full-screen re-shape
  per pinch that this design removed. The halo stroke is baked as a
  1/128-em quantized ratio of the font size — px-exact halo width at draw
  time is impossible because paragraph paints are encoded at build time.
- **Read `minIntrinsicWidth` only after an unconstrained layout.**
  `_shapeTimed` reads it to find wrapping text with a word wider than
  `text-max-width`, and Skia reports the widest unbreakable run there
  and nowhere else: after a constrained layout that broke a word,
  `minIntrinsicWidth` depends on where it broke (14 of
  LUDWIGSVORSTADT's 15 letters, or one). Such text gets its line breaks
  spelled out by `breakAroundWideRuns`, since MapLibre breaks only
  between words: each too-wide word on a line of its own, the words
  between them wrapping at `text-max-width`. Laying the whole label out
  at its widest word's width also keeps words whole, but lets the
  greedy line breaker pull short words onto lines past
  `text-max-width`. Text that fits on one line keeps a single layout,
  and only text with a too-wide word pays a layout per word.
- **`minIntrinsicWidth` is wrong for a run with no space in it.** Skia
  reports a run of ideographs (or of Thai, Lao, Khmer, …) as one
  unbreakable run as wide as the whole label, though its line breaker
  breaks Chinese between characters. So `breakAroundWideRuns` does not
  keep a word whole that `_breaksBetweenIdeographs` (MapLibre's set:
  Han, kana, Bopomofo, Yi — not Hangul) says may break: it wraps at the
  width. The spaceless scripts staying on one line is what MapLibre
  does too, so that is left alone.
- **`breakAroundWideRuns` assigns graphemes to lines, never code
  units.** A code unit inside a cluster (শা, an emoji, a letter with a
  combining mark) has no selection box of its own; stepping by code
  units left a cluster that opened a line on the line before.
- **A label's direction is set per line, with isolates.** Labels are
  laid out left to right; each line of a paragraph whose first strong
  character is right-to-left (`_readsRightToLeft`, the bidi rule
  MapLibre follows) is wrapped in a right-to-left isolate if it needs
  one (`_needsIsolate`: a left-to-right letter or direction control in
  it, or something other than a letter or mark at either end). A
  newline ends every isolate, so the lines `breakAroundWideRuns` spells
  out get one each, carrying the direction of the paragraph they came
  from; a paragraph the line breaker wraps stays in one. Left-to-right
  text, and right-to-left lines that resolve the same either way (most
  Arabic and Hebrew names), are laid out exactly as before: an isolate
  is two characters a font must map, and a line drawn from two fonts
  comes out taller. Right-to-left text is never curve-safe, so the
  isolate controls never reach `_computeClusters`.
- **Curved labels draw from `GlyphAtlas`, and the atlas is a
  `toImageSync` image like any tile.** Keep `rasterizeGlyphs` tied to
  the layer's `_foregrounded` and `discardGlyphAtlas()` in
  `_discardSuspectRasters`, or a magenta glyph page survives a resume.
  The paragraph path stays as the fallback for labels whose glyphs are
  not all in the atlas. `test/curved_text_test.dart` compares the two
  pixel by pixel; keep that test passing when touching either path.
- **Draw text through `_snapTextScale`, never the raw scale.** Impeller
  keys its glyph atlas by the device text scale rounded to 1/200, so a
  continuous `text-size` ramp re-rasterizes every visible glyph and halo
  at each eval-zoom step. Snapped to whole device pixels of font size,
  the raster-thread p90 on a Snapdragon 778G+ dropped from ~34–40 ms to
  ~18 ms during zoom sweeps. Collision and layout keep the exact scale;
  only drawing snaps, about its centre, and always down, so a label is
  never drawn larger than the box that kept its neighbours clear.
- **Collision boxes and cluster metrics are reference-size × scale.**
  Every use of a laid-out text's `size`/`clusters` must be multiplied by
  the symbol's `textScale`; a missed multiplication shows up as collision
  drift between text sizes, not as a crash.
- **`toImageSync` keeps rasters on the GPU** — no async readback. Do not
  replace it with `toImage()`. The corollary is that a raster is only as
  durable as the process's GPU access: iOS revokes it while the app is
  backgrounded, and Impeller fills a rejected texture with solid magenta
  instead of failing, so a raster made at the wrong moment looks entirely
  legitimate. `VectorTileLayer` works around it by gating the render pump
  on the app lifecycle and re-rasterizing on the way back — anything new
  that mints a `ui.Image` (as `PatternResolver` does) has to be reachable
  from that recovery, or it will hold magenta for the life of the
  process. The workaround is temporary by intent: the engine parks async
  snapshots when the GPU is disabled and just doesn't do it for the sync
  path, so see the block above `_foregrounded` in `vector_tile_layer.dart`
  for the removal condition.
- **Whatever disposes text painters between frames drops `_lastDrawn`
  first.** A rendered-feature query reads the last frame's drawables
  lazily — their text painters give the label boxes — so `trimCaches`,
  `paintTile` (which runs `_disposeRetired` outside a frame), `reset`
  and `dispose` all clear it before painters go. A new path that
  disposes painters between frames must do the same, or a query after
  it reads a disposed `TextPainter`.
- **Feature state never reaches the finished-tile cache.** It belongs
  to one controller and the cache is shared by every layer over the
  style; the layer neither stores a tile drawn with state nor serves
  one that may draw a feature with state (unknown counts as may). A
  layer that reads state must have `readsFeatureState` set, or its
  tiles are neither redrawn on a change nor kept out of the cache.
- **A mask filter is a render pass per path.** `line-blur` draws
  through `MaskFilter.blur`, which the GPU backends implement as an
  offscreen pass for every `drawPath` it is on — Liberty with every road
  blurred, drawn per feature, fell from 56 to 20 fps on the Nothing Phone
  while tiles rasterized (49 fps with each layer batched into one path),
  and the pass never shows in a frame's RASTER time, only in frames
  missing. So `_blurFilter` gives no mask filter below three quarters of
  a device pixel of σ (Americana's 0.5 px road blurs fall under it; the
  stroke keeps only the narrowing that makes its ink match MapLibre's),
  and `_paintLine` draws a layer's shared, opaque blurred stroke above
  it as one batched path. Two Impeller faults shape the rest (found on
  an iPhone, reproduced with `flutter test --enable-impeller`; Skia
  draws both): a mask-blurred `BlendMode.clear` stroke on a bent path
  erases the whole layer, so a casing blurs its outer stroke only, and
  a mask-blurred path of several contours on one horizontal or vertical
  line draws nothing, so `_drawStroke` drops the mask filter there. The
  two tests after the blur profiles fail under Impeller without these. Do not put a mask filter on
  something drawn per feature without measuring frames delivered on a
  phone (`bench/` fps, `compare/`).
- **SDF icons need the SDF paint path** (`_sdfPaint` with an edge threshold
  scaled by device pixel ratio); tinting an SDF sprite as a normal image
  produces dark blobs, a bug this code has already been fixed for once.
- `PatternResolver` owns the images it crops and must be disposed with the
  layer; `dispose()` on `LabelPainter` releases cached text painters.
- **The text caches are per live painter, and only two things free
  them:** LRU eviction at their cap and `trimCaches()`, which
  `VectorTileLayer.clearMemoryCache()` calls on every mounted layer.
  The trim keeps what was used since the last *placement* pass began
  (each `paintTile` counts as one), not since the last frame: a
  replayed frame lays out only the decision's winners, and keying on it
  would drop on-screen losers the next pass shapes again inside a
  frame. A tile whose shaping straddles a pass loses its earlier-shaped
  text to a trim, which is why the layer's `_trimLabelCaches` also
  rewinds every queued symbol job's shaping cursor, so the pump, not
  paint, shapes it again. A pass looks up only labels near the screen,
  so before trimming the layer also `prewarm`s every published tile's
  symbols (cache hits), keeping the buffer ring's text the pump already
  shaped. Anything new that looks text up must go
  through `_layoutText` / `_glyphPainters`, which stamp the pass, or a
  trim releases text the screen still needs and the next frame shapes
  it again.
- **A shaped text's clusters remember their glyph-cache entry, but the
  cache owns it.** `_Cluster.glyph` exists so `_glyphPainters` need not
  build `styleKey#grapheme` per glyph per frame (6.8 % of UI-thread
  samples in an Oct 2026 phone profile): within one placement pass a
  remembered glyph is reused without asking the cache at all, and
  across passes it is looked up by the key string the cache already
  holds. So the glyph LRU is ordered by the pass a glyph was last used
  in, not the frame — deliberately, since promoting every on-screen
  glyph on every replayed frame was a map removal plus insertion each,
  rehashes included. The one guard is `_GlyphText.evicted`, set by the
  cache's eviction callback: the glyph cache evicts and trims
  independently of the text cache, and an evicted glyph's painters are
  disposed before the next frame. Reuse a remembered entry only while
  it is not evicted — `curved_text_test.dart` covers a glyph evicted
  within its pass and one trimmed under text kept by the trim.
- **Hot-path keys are hashed once.** `SymbolInstance.continuityKey` is a
  `ContinuityKey` and a curved glyph's atlas key an `_AtlasKey`: both
  compare their fields like the records they replaced, but carry their
  hash, which the label pass would otherwise recompute several times
  per candidate (fade tracker, placement memory, fallbacks) or per
  glyph per frame. `ContinuityKey.toString` keeps the record's
  `(layer, text, icon)` form, which `bench/`'s `BENCH_WATCH` matches.

### Testing Requirements

- `test/symbol_layouter_test.dart` — placement candidates, tile-seam behaviour.
  Note the boundary tolerance band is intentional design, not a dedup bug
- `test/placement_order_test.dart` — which of two colliding labels of one
  layer wins: MapLibre's tile and feature order, never the screen.
- `test/curved_text_test.dart` — along-line text, the sharp-bend fallback,
  and the sticky reading direction of a near-vertical road, including
  across a change of instance; `trimCaches` keeping the glyphs of the
  label on screen
- `test/sdf_icon_test.dart` — SDF tinting
- `test/variable_anchor_test.dart` — variable text anchors, including the
  remembered anchor a label is tried at first and its survival of a
  republish
- `test/fill_pattern_test.dart`, `test/line_pattern_test.dart` — pattern paints
- `test/paint_properties_test.dart` — translate, `line-offset`, `line-blur`
  against MapLibre's ramp, `line-miter-limit`, sort keys, circle strokes
  and `circle-blur`, `background-pattern`, raster resampling
- `test/fill_extrusion_test.dart` — `fill-extrusion-opacity` blended once
  over overlapping buildings, constant and per-feature colour and
  patterned, the alpha of `fill-extrusion-color` ignored (constant and
  per-feature), no outline, with a plain `fill` as the control that
  shows a double blend
- `test/matched_features_test.dart` — zoom-free filters resolved once;
  `test/tile_filters_test.dart` — worker-resolved matches equal the UI's scan
  per prepared tile: cached matches equal a full scan, an unfiltered
  layer shares the source list, a zoom-reading filter is never cached
  and still flips across zooms, and later display tiles of one data
  tile — rasterizer and symbol layouter alike — evaluate no filter
- `test/label_wrap_test.dart` — `text-max-width` wrapping, read off the
  collision box: a word wider than the width stays whole, words still
  wrap between them; `breakAroundWideRuns` giving a wide word its own
  line while the rest wraps at the width, keeping explicit breaks, and
  moving a cluster that opens a line there whole
- `test/scripts/` — labels in 23 scripts drawn with real (bundled
  Noto) fonts, asserted on pixels: reading order and direction,
  joining, pre-base vowels, stacking, emoji sequences, combining marks,
  line breaks per script, halos, curved vs straight; plus goldens of
  each. Any change to shaping, wrapping, curved text or halos must keep
  it green — see `test/scripts/AGENTS.md`
- `test/label_replay_test.dart` — replay frames, which sort only the
  last pass's winners: they draw exactly what the pass placed, in the
  same order, and still fade out a label that lost the pass
- `test/geometry_clipper_test.dart` — polyline/ring clipping, start distances,
  and the closed-ring contour rejoin
- `test/fade_test.dart` — fade progress arithmetic (a widget test cannot pin
  it: fade progress reads the wall clock)
- `test/tile_culling_test.dart` — culling + clipping pixel-equivalence at
  overzoom (via `TileRasterizer.debugDisableCulling`)
- `test/label_painter_zoom_test.dart` — label zoom quantization and cache-key
  stability under fractional zoom sweeps
- `test/label_painter_prewarm_test.dart` — the resumable `prewarm`
  contract: the cursor it returns, guaranteed progress with no budget,
  no double shaping across slices; and that the text cache holds a
  three-level zoom round trip without re-shaping
- `test/label_painter_dispose_test.dart` — evicted painters disposed one
  pass late, never mid-frame; `trimCaches` keeping what the last
  placement pass used (cache hits included, the losers a replayed frame
  skipped too) and what the pump shaped since, and releasing the rest
- `test/label_zoom_gating_test.dart` — the layouter's band and `exact` gates, per-frame layer zoom-range gate, the
  `maxzoom` fade-out ramp, near-zero `text-size` skip, insertion-order
  collision tiebreak
- `test/label_identity_test.dart` — `LabelIdentityIndex`: a republish
  keeps every id (and prefers its own over a neighbour's), a label that
  moved too far gets a new one, point labels across levels both ways,
  nested along-line anchors keeping their ids at the next level (through
  the real layouter), seam twins sharing an id while same-named labels
  either side of a seam stay apart, the twin rule judged against each
  same-level holder's own copy (not another level's), one-to-one and
  nearest-first matching, holders and release — every case run twice,
  scanning names and looking them up by position, plus a common name of
  hundreds of labels on which both must agree id for id
- `test/label_identity_layer_test.dart` — the index through the layer:
  labels keep their ids through zoom crossings (overzoom, four seam
  twins per label), every id a tile takes is handed back across pans and
  crossings (held == offered), and `LabelMode.tile` holds none
- `test/label_continuity_test.dart` — the per-label fade model: key
  identity, `LabelFadeTracker` semantics (rise/fall, resume mid-fade,
  per-frame idempotence, self-pruning), clearing in-progress state when
  fades are disabled at runtime, the guarantee that a placed
  label is never held invisible (a key arriving mid-fade rising at
  once, a label drawn on every frame it is placed on through 60 frames
  of churn, a continuous stream of arrivals fading in continuously —
  these are the 2.7.1 regression tests and they fail against 2.7.0),
  `PlacementThrottle` semantics
  (camera/candidate generations wait for the next due pass, only a resize
  forces one, and an unchanged settling repaint creates no new debt),
  the painter wiring (no re-fade across a level swap, a republished
  winner drawn from its first frame, a missing winner held until a pass,
  ghosts that draw without claiming space, the `minzoom`-cut ease-out,
  never-visible candidates never fading), frozen placement between
  passes (a mid-interval overlap is not acted on; a name on two
  carriageways stays on the one it is drawn on), incumbency surviving a
  republish with and without fades, copies of one label drawing once
  (also where `*-allow-overlap` means nothing collides, and the copy
  that fits drawing when the first one does not), which copy draws (a
  replay draws the copy the pass drew, or another once it is gone; a
  pass keeps its copy when a rotation reorders them; a ghost is drawn
  from the copy the label was drawn from),
  and the outgoing-cohort pin (`drawnLabels` — a candidate a zoom-cut
  label was suppressing must not pop in mid-transition)
- `test/label_mode_test.dart` — `LabelMode.tile`: `paintTile` drops
  labels (allow-overlap ones too) that would cross the tile edge, resolves
  collision within the tile and leaves the screen pass's state and counters
  alone; widget-level, labels land in the tile images with no per-frame pass,
  rotate with the map (and stay upright in screen mode), the finished-tile
  cache keeps the modes apart, toggling `showLabels` re-renders, and no image
  or picture leaks; with a zero pump budget, a tile's `paintTile` never
  shares a frame with shaping, and a `clearMemoryCache` trim
  mid-shaping still lets every tile finish with its labels
- `test/rasterize_benchmark_test.dart` — manual overzoom cost benchmark
  (`--run-skipped`)
- `test/tile_precision_test.dart` — transform precision
- `test/tile_lifecycle_test.dart` — end-to-end painting through the widget
- `test/feature_query_test.dart` — `HitArea` geometry (holes, edge
  crossings, line half-widths, circles, rotated boxes, clipping) and
  `FeatureQuery.hitTile` deciding as the rasterizer draws: widths at
  the tile zoom with casing, filters and zoom ranges, overzoom windows,
  descendants clipped to their extent; `drawsAny` finding only the
  display tiles a feature reaches
- `test/rendered_features_test.dart` — widget-level queries (labels
  first, layer ids, a seam-crossing rectangle, rotation, tile-mode
  labels, `retainAllProperties`) and feature state (only the tiles
  drawing the feature re-rendered and no label re-laid out, the
  finished-tile cache never serving a stateful render, a promoted id,
  a controller handed over, no image or picture leaked, a label style
  following state at a steady zoom)

### Common Patterns

- Static methods over instances for the rasterizer: it holds no state, and a
  paint call is a pure function of (layer, data, zoom, canvas).
- `switch` over the sealed `ThemeLayer` hierarchy in `paint()` — a new layer
  type surfaces here as a compile error.
- Constant style props are evaluated once outside per-feature loops.

## Dependencies

### Internal

- `style/theme.dart` + `style/expression.dart` (what to draw), `pipeline/prepared_tile.dart`
  (the geometry), `style/sprite_atlas.dart` (icons and patterns), `grid/` (raster tiles)

### External

- `dart:ui` (`Canvas`, `Picture`, `Paint`, `Path`, `ImageShader`), `characters`
  (grapheme clustering for text layout)

<!-- MANUAL:
`line-gap-width` casings use a per-feature `saveLayer` +
`BlendMode.clear`. The per-feature isolation is semantically
load-bearing (one feature's gap must not erase another's casing at
junctions, matching MapLibre) and the layer is bounded to the stroked
path — do not widen it back to null/full-tile. Replacing the erase with
two geometrically offset strips was evaluated and rejected: correct
polyline offsetting (miter/round joins, hairpin bends) is large and
artifact-prone for no remaining measurable win.
-->
