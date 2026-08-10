<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-08-09 | Updated: 2026-08-09 -->

# grid

## Purpose

Everything between "where is the camera" and "here is a decoded tile": which
display tiles are visible, in what order they should load, which previous-zoom
tiles must be retained to avoid white flashes, and the per-source stores that
turn tile keys into prepared vector tiles or decoded raster images.

## Key Files

| File | Description |
|------|-------------|
| `grid_layout.dart` | `GridLayout` — the visible display tiles at `floor(zoom)` for a camera, with `keysByDistance()` and `priorityOf()` (viewport-centre first) driving load order, plus `displayTileRect()` for world-pixel placement |
| `tile_retention.dart` | Pure retention predicates extracted for testability: `tilesOverlap()` (equal or differing zooms), `currentLevelReady()` (may the previous zoom level be dropped), `retainedSymbolsNeeded()` (must a retained tile keep contributing labels), and the `CurrentTileStatus` record |
| `tile_store.dart` | `TileStore` — per style source: memory LRU of `PreparedTile` keyed by data tile + theme signature, and dispatch into the executor. Maps display tiles to data tiles via `core/tile_zoom.dart` (overzoom clamp) |
| `raster_tile_store.dart` | `RasterTileStore` + `RasterTile` — the same shape for raster sources declared inside a vector style. Decoded `ui.Image`s are handed out as ref-counted `retain()`/`clone()` handles so several display tiles can share one decode |
| `tile_byte_loader.dart` | `TileByteLoader` — the shared "key → bytes" step both stores consume: fresh disk cache, provider fetch, stale-entry offline fallback, and the failure throttle (`errorRetryDelay`, which the layer's retry timing keys off). Returns the sealed `TileBytesResult` (loaded/absent/unavailable) |

## For AI Agents

### Working In This Directory

- **Retention logic is why there are no white flashes.** The rules in
  `tile_retention.dart` are deliberately pure functions with no widget or
  camera types — keep new rules there rather than inlining them into
  `vector_tile_layer.dart`, so they stay unit-testable.
- **Image ownership.** `RasterTile.retain()` returns a *clone*; whoever takes
  a handle disposes it. Returning the same image to two owners produces a
  use-after-dispose that only shows up as a blank tile under memory pressure.
- **Memory caches are static/shared across map opens** (`clearMemoryCaches()`
  on both stores) so reopening a map paints instantly from cache. Anything
  keyed into them must include the theme/provider signature —
  `TileStore._memorySignature` exists so two styles never collide.
- Overzoom is a data-tile clamp, not an image scale: beyond a source's
  `maxZoom` the same data tile is re-rasterized with subdivision.

### Testing Requirements

- `test/grid_layout_test.dart` — visible set, ordering, tile rects
- `test/tile_retention_test.dart` — the predicates, exhaustively (17 cases)
- `test/tile_store_test.dart`, `test/raster_source_test.dart` — cache keying,
  miss paths, disposal
- `test/tile_lifecycle_test.dart` — the widget-level consequences. Its
  "reopened map paints from cache" case is known to flake under parallel test
  load; re-run it before concluding a regression.

### Common Patterns

- Display tile (what is drawn, at `floor(zoom)`) and data tile (what was
  fetched, clamped to source max zoom) are distinct concepts throughout — keep
  the naming exact, most bugs here start as a conflation of the two.

## Dependencies

### Internal

- `core/`, `cache/`, `provider/`, `pipeline/`, `style/theme.dart`

### External

- `flutter_map` (`MapCamera`), `dart:ui` (`Image`, `Rect`)

<!-- MANUAL: -->
