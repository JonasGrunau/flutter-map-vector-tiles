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
| `tile_rasterizer.dart` | `TileRasterizer.paint()` — draws background/fill/line/raster/circle layers of one display tile into a `Canvas` (which the layer turns into an image via `Picture.toImageSync`). Culls features on their decode-time bounds against the display window (+64px buffer) before any expression work, clips geometry to the window from overzoom shift 2, and handles fill and line patterns, dash arrays (phase-anchored to the un-clipped run start), raster colour matrices, and the `_TileTransform` from tile-extent units to logical pixels |
| `geometry_clipper.dart` | `clipPolyline` (segment-wise Liang–Barsky, emitting sub-runs plus their distance from the original run start for dash/stamp phase) and `clipRing` (Sutherland–Hodgman, winding-preserving) over tile-extent `Float32List`s — pure functions, no canvas |
| `label_painter.dart` | `LabelPainter` — the per-frame screen-space pass (~900 lines): text layout with grapheme clustering, halos, variable text anchors, curved text along lines (with a max-angle bail-out to an icon-only fallback), SDF icon tinting, upright rotation, and `_CollisionIndex`, a grid-bucketed screen-space collision index. Evaluates at a 1/8-level-quantized zoom so its caches survive pinch gestures |
| `symbol_layouter.dart` | `SymbolLayouter.layout()` — extracts label/icon placement candidates (`SymbolInstance`) from a prepared tile: polygon centroids, line midpoints, and spaced placements along lines via `SymbolPath` (precomputed cumulative lengths, `pointAt`/`angleAt`). Bounds-culls features before expression evaluation; along-line targets are enumerated only within the tile window while keeping their full-line parametrization |
| `display_tile_data.dart` | `DisplayTileData` — the prepared data backing one display tile, per style source, plus its raster tiles |
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
  and `_dashPath`/`_stampLinePattern` resume the pattern there — otherwise
  dashes and stamps tear at every display-tile seam at overzoom.
- **Along-line anchor parametrization must stay global.** Anchors sit at
  `spacing/2 + k·spacing` measured over the *full* line; windowing may skip
  enumeration, never re-base the distances, or labels jump between display
  tiles.
- **`LabelPainter` quantizes its eval zoom** (1/8-level steps). Don't key
  anything on the exact fractional zoom — it changes every pinch frame.
- **`toImageSync` keeps rasters on the GPU** — no async readback. Do not
  replace it with `toImage()`.
- **SDF icons need the SDF paint path** (`_sdfPaint` with an edge threshold
  scaled by device pixel ratio); tinting an SDF sprite as a normal image
  produces dark blobs, a bug this code has already been fixed for once.
- `PatternResolver` owns the images it crops and must be disposed with the
  layer; `dispose()` on `LabelPainter` releases cached text painters.

### Testing Requirements

- `test/symbol_layouter_test.dart` — placement candidates, tile-seam behaviour.
  Note the boundary tolerance band is intentional design, not a dedup bug
- `test/curved_text_test.dart` — along-line text and the sharp-bend fallback
- `test/sdf_icon_test.dart` — SDF tinting
- `test/variable_anchor_test.dart` — variable text anchors
- `test/fill_pattern_test.dart`, `test/line_pattern_test.dart` — pattern paints
- `test/geometry_clipper_test.dart` — polyline/ring clipping and start distances
- `test/tile_culling_test.dart` — culling + clipping pixel-equivalence at
  overzoom (via `TileRasterizer.debugDisableCulling`)
- `test/label_painter_zoom_test.dart` — label zoom quantization and cache-key
  stability under fractional zoom sweeps
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
