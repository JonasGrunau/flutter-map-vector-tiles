<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-08-09 | Updated: 2026-08-09 -->

# test

## Purpose

The package's test suite — flat, no mocking framework, no golden files. Pure
logic is unit tested directly; anything involving `ui.Image` ownership, tile
lifecycle or painting is covered by widget tests that pump a real
`FlutterMap`. Tests import package internals via
`package:flutter_map_vector_tiles/src/…` where needed.

## Key Files

| File | Description |
|------|-------------|
| `expression_test.dart` | Style expression compilation: operators, interpolation, legacy syntax, coercions |
| `tile_lifecycle_test.dart` | Widget-level: first paint, zoom changes, pan, cache attachment, disposal. The heaviest and most integration-shaped test |
| `app_lifecycle_raster_test.dart` | The app-backgrounding defence: no rasterizing below `resumed` on iOS, an unfocused (`inactive`) window rendering on every other platform, parked work resuming, re-rasterization and cache distrust after a departure (including by a layer mounted only after the return), and an `inactive`-only interruption costing nothing. Drives lifecycle with `tester.binding.handleAppLifecycleStateChanged`; note that `pump()` is inert from `hidden` on, because the scheduler disables frames there — the assertions that need frames use `inactive` |
| `symbol_layouter_test.dart` | Label placement candidates, tile-seam behaviour, overzoom |
| `raster_source_test.dart` | Raster sources declared inside vector styles, image ref-counting |
| `tile_store_test.dart` | Memory/disk cache keying, miss paths, disposal, stale-while-revalidate (expired entries served instantly, `onRefreshed` on changed content only, corrupt expired entries refetched, `revalidateIfStale` for results served without the stores) |
| `curved_text_test.dart` | Text along lines and the sharp-bend fallback; the upright guard on a hairpin (dropped on a pass, drawn straight on a replay, kept without `text-keep-upright`, no false rejection near vertical); `trimCaches` keeping the on-screen label's glyphs |
| `icon_rotation_test.dart` | `icon-rotate`/`icon-rotation-alignment`, anchor/offset pivot semantics, and rotated collision bounds |
| `label_repeat_test.dart` | Screen-space line-repeat suppression, layer priority, and invisible/gated fallback candidates |
| `sdf_icon_test.dart` | SDF sprite tinting |
| `sprite_packer_test.dart` | Sprite sheet repacking: a magnified icon from an edge-to-edge sheet picks up its neighbour (the control) and from the padded sheet does not; byte-exact copies inside a transparent gutter; aliases, flags and off-sheet sprites; a sprite hanging off the sheet keeps its whole cell; a packed sheet over 4096 px on either side keeps the original; a failed pixel decode errors instead of hanging |
| `tile_retention_test.dart` | The pure retention predicates (17 cases) |
| `descendant_substitution_test.dart` | Zoom-out substitution: the `findDescendants` walk (partial cover, depth and maxzoom bounds), descendant rasterization into sub-squares with buffer-spill clipping (vector and raster sources), and widget-level: a reopened map below the cached level paints from descendants while its own tiles never arrive |
| `theme_reader_test.dart` | Layer parsing and MapLibre spec defaults; `filterReadsZoom` for absent, legacy, expression and zoom-reading filters (including `let`/`step`/`case`/`interpolate` and zoom-keyed legacy functions inside an expression) |
| `matched_features_test.dart` | Zoom-free filters resolved once per prepared tile: cached matches equal a full scan, a zoom-reading filter is never cached and still flips across zooms, and later display tiles of one data tile — rasterizer and symbol layouter alike — evaluate no filter (counted through a property map that tallies reads, not a hook in the renderer) |
| `line_pattern_test.dart`, `fill_pattern_test.dart` | Pattern paints |
| `fill_extrusion_test.dart` | `fill-extrusion-opacity` per layer: overlapping buildings blended once (constant and per-feature colour), a plain fill as the double-blend control, no outline on extrusions |
| `disk_cache_test.dart`, `lru_cache_test.dart` | Cache eviction, TTL, size sweep |
| `style_reader_cache_test.dart` | Stale-while-revalidate style loading |
| `style_reader_sources_test.dart` | Source URL resolution: relative TileJSON/tile templates (ArcGIS `root.json` shape), `{key}` substitution |
| `attribution_test.dart` | `StyleAttribution.parse` (link spans, entities, stray markup) and the reader's collection: source over TileJSON, dedup, order |
| `pmtiles_test.dart` | PMTiles: Hilbert tile IDs (spec anchors + bijection), directory decode/lookup, range-request provider (leaves, coalescing, cancellation), `pmtiles://` style wiring |
| `pmtiles_gzip_test.dart` | VM-only: gzip-compressed archives via `dart:io` gzip; brotli/zstd rejection |
| `pmtiles_gunzip_web_test.dart` | Browser-only: `DecompressionStream` gunzip round-trip |
| `mvt_decoder_test.dart` | MVT decoding against independently built fixtures |
| `variable_anchor_test.dart` | Variable text anchors |
| `tile_precision_test.dart` | Tile transform precision |
| `grid_layout_test.dart` | Visible tile set, load ordering, tile rects |
| `css_color_test.dart` | All CSS colour syntaxes |
| `executor_test.dart` | Executor contract: priority ordering, silent cancellation, disposal |
| `tile_key_test.dart` | Tile coordinate arithmetic and equality |
| `fade_test.dart` | Tile/label fade progress arithmetic, including sub-millisecond durations |
| `label_replay_test.dart` | Replay frames, which sort only the last pass's winners: they draw exactly what the pass placed, in the same order, whatever order the candidates arrive in, and still find a fallback to fade out a label that lost the pass |
| `label_continuity_test.dart` | Per-label fade and placement continuity, including idle repaints not creating placement debt and clearing an in-progress fade when `labelFadeDuration` is disabled at runtime |
| `show_labels_test.dart` | End-to-end label enable/disable, sub-millisecond fades and fade-ticker settlement on an unchanged map, and `VectorTileLayer.clearMemoryCache` trimming an open map's label text to the labels on screen (counted as live `TextPainter`s) |
| `label_mode_test.dart` | `LabelMode.tile`: `paintTile` edge drops (allow-overlap too), in-tile collision and untouched screen-pass state; widget-level, labels baked with no per-frame pass, rotating with the map (upright in screen mode), the result cache kept apart per mode, `showLabels` re-rendering, and image/picture leak counting that also holds on web (see below); and, with `VectorTileLayer.debugPumpBudgetMicros = 0` (one layer or label per frame), the same map in both modes as with the normal budget, every recording spread over one frame per layer, and no slice leaked by a layer disposed mid-recording |
| `render_job_queue_test.dart` | Render pump queue: phase-major and tile-major pop order, replacement and supersede |
| `sliced_recording_test.dart` | `TileRasterizer.recordSlice` / `compose`: one layer per slice stacks into exactly the pixels one `record` makes (a translucent line over a fill shows any reordering), symbol and out-of-zoom layers get no slice of their own, a slice always makes progress, and a sliced tile still counts as one rasterization |
| `sprite_atlas_signature_test.dart` | `SpriteAtlas.signature` — equal sheets agree, different ones do not (the render-signature cache key) |

## Subdirectories

| Directory | Purpose |
|-----------|---------|
| `fixtures/` | Test data builders (see `fixtures/AGENTS.md`) |

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
