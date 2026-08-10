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
| `tile_retention.dart` | Pure retention predicates extracted for testability: `tilesOverlap()` (equal or differing zooms), `currentLevelReady()` (may the previous zoom level be dropped), `retainedSymbolsNeeded()` (must a retained tile keep contributing labels), and the `CurrentTileStatus` record. A tile with a pending symbol job reports `isLoading` (the layer maps that in `_currentStatuses`), so retained labels cover the raster→symbols gap |
| `render_job_queue.dart` | `RenderJobQueue` — per-tile job queue for the render pump, one job per (tile, phase). Pop order is phase-major (all geometry rasters before any symbol extraction), then by viewport-centre priority; accepting a raster job supersedes the tile's pending symbols job (the raster re-enqueues its own) |
| `tile_store.dart` | `TileStore` — per style source: memory LRU of `PreparedTile` keyed by data tile + theme signature, and dispatch into the executor. Maps display tiles to data tiles via `core/tile_zoom.dart` (overzoom clamp). Stale byte loads schedule a background revalidation; changed content replaces the memory entry and fires `onRefreshed`, which the layer maps back to visible display tiles for a cross-faded re-raster |
| `raster_tile_store.dart` | `RasterTileStore` + `RasterTile` — the same shape for raster sources declared inside a vector style (including `onRefreshed` revalidation; the LRU disposes the replaced master image). Decoded `ui.Image`s are handed out as ref-counted `retain()`/`clone()` handles so several display tiles can share one decode |
| `tile_byte_loader.dart` | `TileByteLoader` — the shared "key → bytes" step both stores consume: fresh disk cache, then an *expired* entry served immediately with `stale: true` (stale-while-revalidate — the store then calls `refresh()`, which refetches, rewrites the disk entry and reports whether the bytes changed; refresh failures are deliberately not throttled so the stale entry stays servable), then the provider, plus the failure throttle (`errorRetryDelay`, which the layer's retry timing keys off). Returns the sealed `TileBytesResult` (loaded/absent/unavailable). Known-absent tiles are persisted as zero-byte disk entries (providers never produce empty `TileResponseData`, so the sentinel is unambiguous) and answered from disk without re-requesting |

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
- `test/render_job_queue_test.dart` — phase order, replacement/supersede
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
