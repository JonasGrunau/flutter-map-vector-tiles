# Paint properties against MapLibre GL JS (2026-10-26)

Each image is one synthetic style drawn by this package (left) and by
MapLibre GL JS 4.7.1 (right), for the change that taught the rasterizer
`*-translate`, `*-sort-key`, `line-offset`, `line-blur`,
`line-miter-limit`, `circle-blur`, `background-pattern` and raster
`resampling`, and put circle strokes outside the radius.

How they were made: one hand-built MVT tile (10/550/335, built with
`test/fixtures/mvt_builder.dart`), a two-icon sprite sheet and a 256 px
raster tile, with one style per image. Left: `TileRasterizer.rasterize`
over the four zoom-11 display tiles of that data tile at a device pixel
ratio of 2 (`TileOffset.maplibre`, so style zoom 10), under
`flutter_tester` (Skia). Right: `compare/tool/maplibre.html` at the
tile's centre, zoom 10, 512 × 512 CSS px at a device scale factor of 2,
in headless Chrome. Same scale and the same bytes on both sides.

| image | what it shows | difference |
|---|---|---|
| `translate.webp` | `fill-translate` (a Bright-style building top, a translucent fill over its original outline), `line-translate`, `circle-translate` | none visible |
| `offset.webp` | `line-offset` ±14 px on a zigzag, ±10 px on a square and a triangle | at sharp turns MapLibre leaves the outer side open and lets the inner side cross; this package bevels the outside and meets on the inside |
| `blur.webp` | `line-blur` 0, 2, 6 on 12 px lines, 4 on a 4 px line, 0.5 on a 2 px line, 1 on a 6 px line, a blurred casing, a blurred dash | within about 0.05 alpha of MapLibre's ramp for blurs of 2 px and more; a 1 px blur has a steeper edge, up to 0.27 alpha off in single device-pixel rows, holding the same ink to within 10 % (measured at a device pixel ratio of 3 in `test/paint_properties_test.dart`'s set-up) |
| `miter.webp` | 30°, 50°, 70° turns at the default limit (2), at 4, at 1 | the middle row: MapLibre 4.7.1 draws its 30° and 50° miters broken; this package draws them whole |
| `sort.webp` | `fill-sort-key`, `line-sort-key`, `circle-sort-key` against source order | MapLibre draws a fill layer's anti-aliasing outlines after all its fills, so faint edges of lower features show through higher ones |
| `circles.webp` | strokes outside the radius (opaque and 50 %), `circle-blur` 0.5 and 1, a blurred circle with a stroke, small circles | none visible |
| `pattern.webp` | `background-pattern`, and a `fill-pattern` moved by `fill-translate` | none visible |
| `resampling-nearest.webp`, `resampling-linear.webp` | a raster source 16× overzoomed | none visible |

`line-gradient` is not shown: MapLibre refuses the whole style when the
property sits on a vector source ("requires a GeoJSON source with
`lineMetrics` enabled"), and this package draws the line's `line-color`.
