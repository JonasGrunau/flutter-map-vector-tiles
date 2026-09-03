<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-08-09 | Updated: 2026-08-09 -->

# render

## Purpose

All drawing, split along the package's central design line: **geometry is
rasterized once per display tile into a GPU-resident image; labels and icons
are never baked in** — they are laid out per tile and drawn every frame in
screen space with one global collision pass. That split is why text stays
crisp at fractional zoom, upright under rotation, and never duplicates or
clips at tile seams.

## Key Files

| File | Description |
|------|-------------|
| `tile_rasterizer.dart` | `TileRasterizer.paint()` — draws background/fill/line/raster/circle layers of one display tile into a `Canvas` (which the layer turns into an image via `Picture.toImageSync`). Culls features on their decode-time bounds against the display window (+64px buffer) before any expression work, clips geometry to the window from overzoom shift 2 — and descendant tiles standing in on zoom-out to their own extent, unconditionally — and handles fill and line patterns, dash arrays (phase-anchored to the un-clipped run start), raster colour matrices, and the `_TileTransform` from tile-extent units to logical pixels (both directions: ancestor sub-window at overzoom, descendant sub-square under zoom-out substitution) |
| `geometry_clipper.dart` | `clipPolyline` (segment-wise Liang–Barsky, emitting sub-runs plus their distance from the original run start for dash/stamp phase; with `close:` it walks the ring's closing segment and rejoins the contour that crosses vertex 0, so a stroked ring keeps its join there instead of butting two caps) and `clipRing` (Sutherland–Hodgman, winding-preserving) over tile-extent `Float32List`s — pure functions, no canvas |
| `fade.dart` | `fadeProgressOf` — elapsed fraction of a fade, in microseconds. Shared by the tile and label fades; the unit matters (see the file) |
| `label_continuity.dart` | The per-label fade model: `labelContinuityKey` (`(layer, text, icon)` — deliberately position-free, memoized on `SymbolInstance.continuityKey`), `LabelFadeTracker` (one opacity per *sitting* — a key at a screen position, matched within `matchRadius` inside the loose key via `beginFrame`/`showAt`/`sweep`, integrated toward "placed this frame ? 1 : 0". The loose-key-plus-position-match shape carries three guarantees at once: cross-level copies of one label land on the same sitting despite simplification noise, so a crossing never cross-fades a label against itself; same-key labels far apart — every parking icon, every housenumber "12", the re-spaced repeats of a street name — fade independently instead of popping while any one of them holds the key's opacity; and resume-not-restart stops dips from becoming blinks. **Nothing may park a placed sitting at zero** — `sweep` drops anything at or below zero, so a state resting there is destroyed by one lost frame; see the invariant below. `sweep` reports each fading sitting's position so the painter can ghost it where it was; `isVisibleAt` reports a full-opacity sitting, which is how placement recognises incumbents across instance replacement), `PlacementThrottle` (which frames re-run the collision pass: once per fade duration, or at once when the viewport size changed; `deferred` reports the pass it owes), `PlacementMemory` (the choices a label is sitting on — `SittingPlacement.anchor`/`flip`/`textDropped` — keyed by continuity key *and* screen position, so they outlive the `SymbolInstance` that took them) and `drawnLabels` (a cohort filtered to what the last frame actually drew — retention pins outgoing cohorts to it so they can keep labels but never introduce them). Pure and clock-agnostic; the painter drives both |
| `label_painter.dart` | `LabelPainter` — the per-frame screen-space pass (~1300 lines): text shaped once at a 16 px reference size and drawn scaled through the canvas transform, grapheme clustering, halos (baked as a quantized em-ratio stroke), variable text anchors, curved text along lines (with a max-angle bail-out to an icon-only fallback), SDF icon tinting, upright rotation, the per-label fades (a `LabelFadeTracker` keyed on `SymbolInstance.continuityKey`, every label via `showAt` with its screen anchor — one fade per sitting, so same-key POIs fade independently and a re-spaced street name cross-fades between its per-level sittings instead of teleporting; sittings no longer placed draw ghosts — laid out past the zoom gate, claiming no collision space — from the surviving candidate nearest the fading sitting within `_ghostRadius`) compounded with the `zoomRangeOpacity` ramp out before a declared `maxzoom` into `_DrawableSymbol.opacity` and drawn via per-opacity-bucket `saveLayer`s (a bucket's bounds are the union of its members', so on a label-dense screen each one is effectively full-screen — the bucket *count* is the cost, but see the invariant below before trading anything for it: a key on its first frame takes the one-step floor rather than drawing at zero), the throttled placement (a `PlacementThrottle` decides pass vs replay; replay frames prepare only `_winners` and use `_CollisionIndex.permissive()`, so the frozen decision is reproduced rather than re-derived), `prewarm()` for shaping a tile's labels inside the render pump — **resumable**, taking a `from` cursor and an `outOfBudget` predicate and returning where to continue, because shaping one dense tile costs several times a whole frame's render budget; its caller must not publish a batch as placement candidates before it completes, or the label pass will shape the remainder during paint, and `_CollisionIndex`, a grid-bucketed screen-space collision index (which is where tile-seam duplicates are removed — the layouter deliberately lets both neighbours claim a feature on the seam rather than risk neither doing so). Evaluates at a 1/8-level-quantized zoom so its memos survive pinch gestures |
| `symbol_layouter.dart` | `SymbolLayouter.layout()` — extracts label/icon placement candidates (`SymbolInstance`, with its `TextStyleMemo` label-pass memo; placement state deliberately lives in `PlacementMemory` instead, since instances are replaced under labels that stay on screen) from a prepared tile: polygon centroids, line midpoints, and spaced placements along lines via `SymbolPath` (precomputed cumulative lengths, `pointAt`/`angleAt`). Bounds-culls features before expression evaluation; along-line targets are enumerated only within the tile window while keeping their full-line parametrization. Gates layers by zoom-band intersection (`coversZoomBand`) — the precise per-frame cut is the label pass's job. `anySymbolLayerCovers()` lets the render pump skip the symbol phase when no symbol layer intersects the tile's band |
| `display_tile_data.dart` | `DisplayTileData` — the prepared data backing one display tile, per style source, plus its raster tiles and any descendant tiles composing a provisional zoom-out cover (geometry only; the symbol layouter never sees descendants) |
| `pattern_resolver.dart` | `PatternResolver` — crops `fill-pattern` / `line-pattern` sprites out of the atlas into standalone images suitable for a tiled `ImageShader` |

## For AI Agents

### Working In This Directory

- **Never move labels into the tile raster.** Anything that must stay crisp
  under fractional zoom, stay upright under rotation, or participate in global
  collision belongs in `label_painter.dart`, not `tile_rasterizer.dart`.
- **Collision is global across tiles.** The `_CollisionIndex` is built once per
  frame for the whole screen, then every tile's candidates are tested against
  it. Per-tile collision would reintroduce duplicate labels at seams — the
  exact bug this design exists to prevent.
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
- **Along-line anchor parametrization must stay global.** Anchors sit at
  `spacing/2 + k·spacing` measured over the *full* line; windowing may skip
  enumeration, never re-base the distances, or labels jump between display
  tiles.
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
  winner set is frozen by *instance identity*, and republishes/level
  swaps replace every instance — so an un-shown sitting on a replay
  frame usually means succession, not departure. `LabelFadeTracker.sweep`'s
  `hold:` (passed on replay frames) keeps such sittings at their opacity,
  their ghosts drawn from the successor candidates, until a pass
  decides. Decaying through the churn window fades a label into itself
  at every crossing — the regression that added the flag. A fade a pass
  *has* started advances every frame, held or not; one step per pass
  would stretch a 150ms fade across minutes.

- **Disabling label fades clears the tracker.** A no-fade paint must
  discard every tracked sitting, including an in-progress one. Otherwise
  `LabelFadeTracker.anyActive` stays true without any future `beginFrame`
  call to advance it, and the widget's fade ticker repaints forever.

- **A visible label is never evicted by a same-layer arrival.** On
  placing frames `_flagIncumbents` marks candidates whose label is
  steadily on screen (last pass's winners by instance identity, plus
  `LabelFadeTracker.isVisibleAt` full-opacity sittings — the latter is
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
- **Placement ties break on `PlacedSymbol.order`** (insertion order —
  the layer adds current-level tiles before retained ones). Both sorts
  in `LabelPainter` are non-stable; the tiebreaker is what keeps the
  winner deterministic frame to frame. The full priority is layer,
  incumbency (see above), `symbol-sort-key`, screen y, order. After the
  sort, `_promoteIncumbents` additionally reorders candidates *within
  one continuity key* so the instance already drawn is tried first; it
  must never reorder across keys, or one label would start outranking
  another.
- **A replay frame must reproduce the pass, not re-derive it.** Anything
  a placement decides that is not a pure function of the current frame's
  geometry has to be remembered in the `SittingPlacement` `_prepare`
  looks up (`anchor`, `flip`, `textDropped`) and replayed, because replay
  frames run against a permissive collision index. A new space-dependent
  choice added to `_prepare` without one shows up as that choice
  flickering at the placement interval.
- **Placement state belongs in `PlacementMemory`, never on the
  `SymbolInstance`.** Instances are rebuilt per display-tile layout, so
  anything stored on one is lost at every zoom crossing and republish —
  precisely when a label is most visibly on screen, and with its
  continuity key (and so its opacity) unchanged, so the re-decision
  lands as a hard jump. The memory is keyed by continuity key *and*
  position; that is deliberate and the opposite of `labelContinuityKey`,
  which is position-free. Both choices are argued in
  `label_continuity.dart` — read them before changing either key.
- **Never put a font size (or unquantized opacity/halo width) into the
  text-shape cache key.** Text is shaped once at the 16 px reference size
  and drawn scaled; a size-bearing key re-creates the full-screen re-shape
  per pinch that this design removed. The halo stroke is baked as a
  1/128-em quantized ratio of the font size — px-exact halo width at draw
  time is impossible because paragraph paints are encoded at build time.
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
- **SDF icons need the SDF paint path** (`_sdfPaint` with an edge threshold
  scaled by device pixel ratio); tinting an SDF sprite as a normal image
  produces dark blobs, a bug this code has already been fixed for once.
- `PatternResolver` owns the images it crops and must be disposed with the
  layer; `dispose()` on `LabelPainter` releases cached text painters.

### Testing Requirements

- `test/symbol_layouter_test.dart` — placement candidates, tile-seam behaviour.
  Note the boundary tolerance band is intentional design, not a dedup bug
- `test/curved_text_test.dart` — along-line text, the sharp-bend fallback,
  and the sticky reading direction of a near-vertical road, including
  across a change of instance
- `test/sdf_icon_test.dart` — SDF tinting
- `test/variable_anchor_test.dart` — variable text anchors, including the
  remembered anchor a label is tried at first and its survival of a
  republish
- `test/fill_pattern_test.dart`, `test/line_pattern_test.dart` — pattern paints
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
  no double shaping across slices
- `test/label_zoom_gating_test.dart` — per-frame layer zoom-range gate, the
  `maxzoom` fade-out ramp, near-zero `text-size` skip, insertion-order
  collision tiebreak
- `test/label_continuity_test.dart` — the per-label fade model: key
  identity, `LabelFadeTracker` semantics (rise/fall, resume mid-fade,
  per-frame idempotence, self-pruning), clearing in-progress state when
  fades are disabled at runtime, the guarantee that a placed
  label is never held invisible (a key arriving mid-fade rising at
  once, a label drawn on every frame it is placed on through 60 frames
  of churn, a continuous stream of arrivals fading in continuously —
  these are the 2.7.1 regression tests and they fail against 2.7.0),
  `PlacementThrottle` semantics
  (the interval as the only cadence — a publish waits for the next due
  pass, only a resize forces one — and the deferred flag),
  the painter wiring (no re-fade across a level swap, ghosts that draw
  without claiming space, the `minzoom`-cut ease-out, never-visible
  candidates never fading), frozen placement between passes (a
  mid-interval overlap is not acted on; a label keeps the candidate it
  is drawn from), the two-copies-collide case a zoom crossing produces,
  and the outgoing-cohort pin (`drawnLabels` — a candidate a zoom-cut
  label was suppressing must not pop in mid-transition)
- `test/rasterize_benchmark_test.dart` — manual overzoom cost benchmark
  (`--run-skipped`)
- `test/tile_precision_test.dart` — transform precision
- `test/tile_lifecycle_test.dart` — end-to-end painting through the widget

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
