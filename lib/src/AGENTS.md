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
| `vector_tile_layer.dart` | The `VectorTileLayer` widget and its state — the orchestrator (~1500 lines). Owns tile stores, the display-tile map, retained-tile pruning, the raster job queue, the fade ticker, and the `CustomPainter` that draws tile images then labels. Its label-continuity duties are down to feeding the painter: pinning an outgoing level's cohorts to what was drawn (`_drawnLastFrame`), splitting retained tiles into placement candidates vs ghost-only fallbacks, parking a disposed retained tile's labels (`_ghostLabels`) for one fade duration, and bumping `_labelGeneration` (via `_labelCandidatesChanged`) whenever the candidate set changes so the painter's throttled collision pass re-runs at once — the fades and the placement decision itself live in the painter |
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
| `render/` | Tile rasterization, symbol layout, screen-space label painting (see `render/AGENTS.md`) |
| `style/` | Style document loading, expression compilation, the compiled `Theme` (see `style/AGENTS.md`) |

## For AI Agents

### Working In This Directory

- **`vector_tile_layer.dart` is the hot file** — most behavioural changes touch
  it. It is also where lifecycle bugs live: `_clearTiles`, `dispose` and
  `didUpdateWidget` must keep every `ui.Image`, isolate and pending request
  accounted for.
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
