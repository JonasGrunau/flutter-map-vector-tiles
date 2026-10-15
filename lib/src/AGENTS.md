<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-08-09 | Updated: 2026-08-09 -->

# src

## Purpose

Every implementation file in the package, grouped by concern. The dependency
direction runs roughly top-down: `vector_tile_layer.dart` orchestrates the
grid, stores and renderers; stores drive the pipeline and providers; the
pipeline consumes `mvt/` and `style/`; `core/` and `cache/` are leaf utilities
depended on by everything.

## Key Files

| File | Description |
|------|-------------|
| `vector_tile_layer.dart` | The `VectorTileLayer` widget and its state — the orchestrator (~2400 lines). Owns tile stores, the display-tile map, retained-tile pruning (also release-on-readiness from the publish jobs and the fade tick, since a rebuild needs a camera change the end of a gesture never delivers), the raster job queue and its budgeted pump (both phases are resumable: a raster job records its layers in slices across frames — `_RenderJob.layerCursor` / `geometryParts` — and a symbol job shapes its labels in slices; `VectorTileLayer.debugPumpBudgetMicros` lets tests shrink the budget). The budget follows the camera: 4 ms per frame while it moves, 12 ms once it has been still for 150 ms (`_cameraStill`). `_cameraMoved` restarts that clock from `build` and from flutter_map's `mapEventStream` (`MapEventWithMove`, size changes excepted) — tickers run before `build`, so only the event reaches the first frame of a gesture in time; `VectorTileLayer.debugPumpCameraStill` reports what the last pump saw. The static `_mounted` set registers every live layer state, which is how the static `VectorTileLayer.clearMemoryCache()` reaches each one's `_trimLabelCaches`: `LabelPainter.trimCaches`, then every queued symbol job's shaping cursor rewound to 0, so text a trim took from a half-shaped tile is shaped again by the pump rather than in paint. Also the fade ticker, and the `CustomPainter` that draws tile images then labels. Cache-served tiles fade in only when retained imagery lies beneath them (`_coveredByRetained`) — a fade over the bare background is the zoom-out ring shimmer. A pending source renders provisionally from its nearest cached ancestor, or — zoom-out, no ancestor — from its cached descendants composed into the tile (geometry only). Its label-continuity duties are down to feeding the painter: pinning an outgoing level's cohorts to what was drawn (`_drawnLastFrame`), splitting retained tiles into placement candidates vs ghost-only fallbacks, parking a disposed retained tile's labels (`_ghostLabels`) for one fade duration, and bumping `_labelGeneration` whenever the camera or candidate set changes. The painter picks a changed generation up on its throttled cadence; ticker-only repaints keep the same generation and create no new placement debt — the fades and the placement decision itself live in the painter. With `LabelMode.tile` (`_tileLabels`) none of that runs: the raster job records the geometry in slices as usual but takes no image, handing the composed picture to the symbol job it enqueues (`_RenderJob.geometry`); the symbol job lays out and shapes as usual and then publishes the tile once, labels drawn over that picture by `LabelPainter.paintTile` and snapshotted together (`_rasterizeWithLabels`), with an empty candidate list. That last step is one unit of work, so a symbol job whose shaping used up the frame's budget is requeued and runs it in a later frame rather than on top of a full one; the pump pops tile-major, and the per-frame label pass is skipped (`_screenLabels`). A mode change, or `showLabels` toggled in tile mode, re-renders the live tiles and retires the retained tiles' queued jobs |
| `label_mode.dart` | `LabelMode` — public enum: `screen` (default, per-frame screen-space label pass) or `tile` (labels baked into each tile's raster, `vector_map_tiles`' raster mode). Its doc comment carries the trade-off table |
| `tile_providers.dart` | `TileProviders` (providers keyed by style source id) and `RasterTileSource` (a raster source declared inside a vector style) |
| `tile_offset.dart` | `TileOffset` — relates display zoom to data/style zoom. `TileOffset.maplibre` (offset −1, 512px convention) is the default |
| `logger.dart` | `Logger` abstraction plus a console implementation; the only sanctioned diagnostic channel (`avoid_print` is enforced) |

## Subdirectories

| Directory | Purpose |
|-----------|---------|
| `cache/` | LRU memory cache and the TTL/size-capped disk cache (see `cache/AGENTS.md`) |
| `core/` | Tiny shared value types: `TileKey`, `CancellationToken` (see `core/AGENTS.md`) |
| `grid/` | Visible-tile computation, tile retention rules, the vector and raster tile stores (see `grid/AGENTS.md`) |
| `mvt/` | Mapbox Vector Tile protobuf decoding (see `mvt/AGENTS.md`) |
| `pipeline/` | Isolate-transferable prepared-tile model, the pure prepare step, and executors (see `pipeline/AGENTS.md`) |
| `provider/` | The `VectorTileProvider` hierarchy and `TileResponse` result type (see `provider/AGENTS.md`) |
| `render/` | Tile rasterization, symbol layout, label painting in screen space or into tiles (see `render/AGENTS.md`) |
| `style/` | Style document loading, expression compilation, the compiled `Theme` (see `style/AGENTS.md`) |

## For AI Agents

### Working In This Directory

- **`vector_tile_layer.dart` is the hot file** — most behavioural changes touch
  it. It is also where lifecycle bugs live: `_clearTiles`, `dispose` and
  `didUpdateWidget` must keep every `ui.Image`, isolate and pending request
  accounted for.
- **The app-lifecycle members are an engine workaround, and are labelled
  as one.** iOS revokes GPU access for a backgrounded process and
  Impeller fills a rejected `toImageSync` texture with solid magenta
  rather than failing, so the layer refuses to rasterize below
  `AppLifecycleState.resumed` on iOS (below `inactive` elsewhere, where
  `inactive` only means an unfocused window — see `_canRasterizeIn`) and
  rebuilds its GPU-resident images on the way back (`_recoverIfSuspect`,
  `_discardSuspectRasters`). Two things
  to keep true while it lives: the "has been away" mark is `static` on
  purpose — the caches it condemns outlive any one layer — and anything
  new that creates a `ui.Image` must be reachable from that recovery
  (the label painter's glyph atlas is, via `discardGlyphAtlas`; so is
  `LabelMode.tile`'s labelled raster, made only inside the gated pump).
  The block comment above `_foregrounded` records the exact upstream gap
  and the condition for deleting the lot; it is tracked as
  [flutter#191255](https://github.com/flutter/flutter/issues/191255).
  Do not delete the workaround on the strength of the *other* "pink
  images" issues — they are all closed, and all the decode path.
- Respect the layering. `core/` and `cache/` must not import upward; `pipeline/`
  must not import `render/` or the widget.
- New style features usually mean coordinated edits in three places:
  `style/theme.dart` (the compiled layer/property), `style/theme_reader.dart`
  (parsing it), and `render/` (drawing it).

### Testing Requirements

Tests live flat in `test/` and import through
`package:flutter_map_vector_tiles/src/…` where they need internals. Pure logic
(retention predicates, grid layout, expressions, colors) is unit tested;
lifecycle and painting are covered by widget tests in `test/tile_lifecycle_test.dart`.

### Common Patterns

- Compiled-once, evaluated-many: style JSON becomes Dart closures (`Expr`) at
  read time, never re-parsed per frame.
- `switch` over sealed hierarchies (`ThemeLayer`, `TileResponse`) so a new
  variant surfaces as a compile error rather than a silent default.
- `unawaited(...)` is explicit wherever a future is deliberately not awaited
  (the `unawaited_futures` lint is on).

## Dependencies

### Internal

- Consumed by `lib/flutter_map_vector_tiles.dart` (public barrel)

### External

- `flutter_map` (camera/layer integration), `http`, `path_provider`, `latlong2`,
  `characters`, `meta`

<!-- MANUAL: -->
