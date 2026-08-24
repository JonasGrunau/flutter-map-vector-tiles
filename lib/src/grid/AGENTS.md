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
| `render_job_queue.dart` | `RenderJobQueue` — per-tile job queue for the render pump, one job per (tile, phase). Pop order is phase-major (all geometry rasters before any symbol extraction), then by viewport-centre priority; accepting a raster job supersedes the tile's pending symbols job (the raster re-enqueues its own — including a *part-shaped* one, whose progress is correctly discarded, since the newer sources need laying out again) |
| `tile_result_cache.dart` | `TileResultCache` + `TileResult` — process-wide LRU of *finished* display tiles (rasterized `ui.Image` + `SymbolInstance` list + `renderedWith`), one cache per render signature. The cache owns master images and disposes them on eviction; consumers take `clone()`s. Bounded by `rasterCacheMaxBytes` (GPU texture bytes), and the *registry* is bounded too: signatures outlive their layer for warm reopens, so the least recently used are released once their combined cost exceeds the budget (the two most recent are always kept). `releaseSignature` frees one without creating it |
| `tile_store.dart` | `TileStore` — per style source: memory LRU of `PreparedTile` keyed by data tile + theme signature, and dispatch into the executor. Maps display tiles to data tiles via `core/tile_zoom.dart` (overzoom clamp). Stale byte loads schedule a background revalidation; changed content replaces the memory entry and fires `onRefreshed`, which the layer maps back to visible display tiles for a cross-faded re-raster |
| `raster_tile_store.dart` | `RasterTileStore` + `RasterTile` — the same shape for raster sources declared inside a vector style (including `onRefreshed` revalidation; the LRU disposes the replaced master image). Decoded `ui.Image`s are handed out as ref-counted `retain()`/`clone()` handles so several display tiles can share one decode |
| `tile_byte_loader.dart` | `TileByteLoader` — the shared "key → bytes" step both stores consume: fresh disk cache, then an *expired* entry served immediately with `stale: true` (stale-while-revalidate — the store then calls `refresh()`, which refetches, rewrites the disk entry and reports whether the bytes changed, `TileBytesUnavailable` when it could not reach the source at all), then the provider, plus the failure throttle (`errorRetryDelay`, which the layer's retry timing keys off) and a separate refresh throttle. `expiredBytes()` is the no-decode freshness probe for callers that display a *rendered* result and never reach `load()`. Returns the sealed `TileBytesResult` (loaded/absent/unavailable). Known-absent tiles are persisted as zero-byte disk entries (providers never produce empty `TileResponseData`, so the sentinel is unambiguous) and answered from disk without re-requesting. Every cache access goes through the private `_cache` getter, which resolves to null for providers with `cacheBytesToDisk == false` (MBTiles, memory) — so their tiles are neither written nor read back, and nothing they serve is ever `stale` |

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
  on both stores, `TileResultCache.clearAll()`) so reopening a map paints
  instantly from cache. Anything keyed into them must include the
  theme/provider signature — `TileStore._memorySignature` and the layer's
  `_resultSignature` exist so two styles (or the same style over different
  endpoints) never collide.
- **Outliving the layer means outliving its GPU context.** `TileResultCache`
  and `RasterTileStore` hold `ui.Image`s that iOS can invalidate while the
  app is backgrounded — Impeller hands back solid magenta, which caches like
  any other tile. `VectorTileLayer` clears both on the way back in
  (`_discardSuspectRasters`), so a new cache of GPU-resident images needs a
  static clear the layer can reach, not just an eviction budget.
- **Only final, fully-sourced results enter the result cache.** Caching a
  provisional or partial tile would let a later cache hit mask the retry
  that was supposed to recover the missing source.
- Overzoom is a data-tile clamp, not an image scale: beyond a source's
  `maxZoom` the same data tile is re-rasterized with subdivision.

### Testing Requirements

- `test/grid_layout_test.dart` — visible set, ordering, tile rects
- `test/render_job_queue_test.dart` — phase order, replacement/supersede
- `test/tile_result_cache_test.dart` — ownership, byte accounting,
  invalidation, and the widget-level zoom round-trip (no re-rendering)
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
