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
| `vector_tile_layer.dart` | The `VectorTileLayer` widget and its state — the orchestrator (~2400 lines). Owns tile stores, the display-tile map, retained-tile pruning (also release-on-readiness from the publish jobs and the fade tick, since a rebuild needs a camera change the end of a gesture never delivers), the raster job queue and its budgeted pump (both phases are resumable: a raster job records its layers in slices across frames — `_RenderJob.layerCursor` / `geometryParts` — and a symbol job shapes its labels in slices; `VectorTileLayer.debugPumpBudgetMicros` lets tests shrink the budget). The budget follows the camera: 4 ms per frame while it moves, 12 ms once it has been still for 150 ms (`_cameraStill`). `_cameraMoved` restarts that clock from `build` and from flutter_map's `mapEventStream` (`MapEventWithMove`, size changes excepted) — tickers run before `build`, so only the event reaches the first frame of a gesture in time; `VectorTileLayer.debugPumpCameraStill` reports what the last pump saw. The static `_mounted` set registers every live layer state, which is how the static `VectorTileLayer.clearMemoryCache()` reaches each one's `_trimLabelCaches`: `LabelPainter.trimCaches`, then every queued symbol job's shaping cursor rewound to 0, so text a trim took from a half-shaped tile is shaped again by the pump rather than in paint. Also the fade ticker, and the `CustomPainter` that draws tile images, then heatmap layers (`HeatmapPainter`, fed every tile's `HeatmapPoints` — laid out where a tile's image publishes and cached with it — and, during a crossing, the retained level's only where the current one has none, `_heatmapTiles`; `_heatmapGeneration` rides on `_labelCandidatesChanged`), then labels. Cache-served tiles fade in only when retained imagery lies beneath them (`_coveredByRetained`) — a fade over the bare background is the zoom-out ring shimmer. A pending source renders provisionally from its nearest cached ancestor, or — zoom-out, no ancestor — from its cached descendants composed into the tile (geometry only). Its label-continuity duties are down to feeding the painter: pinning an outgoing level's cohorts to what was drawn (`_drawnLastFrame`), splitting retained tiles into placement candidates vs ghost-only fallbacks, parking a disposed retained tile's labels (`_ghostLabels`) for one fade duration, and bumping `_labelGeneration` whenever the camera or candidate set changes. The painter picks a changed generation up on its throttled cadence; ticker-only repaints keep the same generation and create no new placement debt — the fades and the placement decision itself live in the painter. With `LabelMode.tile` (`_tileLabels`) none of that runs: the raster job records the geometry in slices as usual but takes no image, handing the composed picture to the symbol job it enqueues (`_RenderJob.geometry`); the symbol job lays out and shapes as usual and then publishes the tile once, labels drawn over that picture by `LabelPainter.paintTile` and snapshotted together (`_rasterizeWithLabels`), with an empty candidate list. That last step is one unit of work, so a symbol job whose shaping used up the frame's budget is requeued and runs it in a later frame rather than on top of a full one; the pump pops tile-major, and the per-frame label pass is skipped (`_screenLabels`). A mode change, or `showLabels` toggled in tile mode, re-renders the live tiles. A symbol job first asks the painter which glyph ranges its labels need (`LabelPainter.glyphsPending`); while any is loading the job leaves the queue (`_SymbolsOutcome.parked`, `_parkedJobs`) and is requeued once they have loaded or failed — or dropped if its tile moved on meanwhile; `_clearTiles` drops whatever is still parked. Every such re-render (`_refreshTiles`: sprites, glyphs, `showLabels`, label mode, resume recovery) also retires the retained tiles' queued jobs, which were built before the change and would otherwise publish and cache its old content under the new signature. `raster-dem` sources (`_demEncodings`) get a store like any raster source, plus neighbour loading in `_loadTile`: the DEM tiles bordering the data tile (`_demNeighbourKeys`, all eight or at overzoom those of the edges the display tile touches) are peeked or obtained alongside the other sources, awaited before the final render but never by themselves a reason for a provisional one (whose own in-memory neighbours `_peekDemNeighbours` adds), count as missing when they failed rather than being absent, and enter `renderedWith`, so a retry re-renders when they arrive; the job owns their handles (`_RenderJob.neighbourRasters`). A layer with DEM sources starts `HillshadePrograms.load` in `_buildStores` and awaits it before a final render. `_reloadRefreshed` takes a predicate, so a refreshed DEM tile also re-renders the display tiles whose edges read it It is also the `FeatureQueryHost` a `VectorTileLayerController` attaches to: `queryRenderedFeatures` maps the query through the inverse of the painter's camera transform onto each current tile, takes label hits from the painter (`hitTestLabels`) or, in tile mode, from `_DisplayTile.labelHits`, geometry hits from `FeatureQuery.hitTile` over the decoded data (`peekWithAncestors`), and dedups per layer by id; `featureStateChanged` re-renders only the live tiles `FeatureQuery.drawsAny` finds, through `_renderForFeatureState` (priority −1, no fade, and `_RenderJob.keepSymbols` — geometry only — when the tile's labels are published). `_cacheResult` never stores a tile drawn with state (`_drewFeatureState`) or one whose job began under another state version (`_RenderJob.stateVersion`), and `_loadTile` never serves one that may draw a stateful feature (`_mayDrawFeatureState`): the result cache is shared across layers, state belongs to one controller. With a controller attached, live tiles hold the decoded data their image came from (`_DisplayTile.sources`, fetched by `_adoptSources` after a cache hit), so queries and state changes still answer after the decoded-tile cache let go; keepSymbols applies only to a current tile whose resolved sources equal those its labels came from. The controller is attached in `initState`/`activate` and detached (identity-guarded) in `deactivate`/`dispose`; the last layer to attach wins, which is how a keyed remount takes it over. `retainAllProperties` lifts the keep-lists in `_buildStores`, which also folds each source's `promoteId` into them and into the stores |
| `vector_tile_layer_controller.dart` | `VectorTileLayerController` (public) — `queryRenderedFeatures` / `queryRenderedFeaturesInRect` and `setFeatureState` / `removeFeatureState` / `getFeatureState`; owns the `FeatureStates`, so state outlives the layer it is attached to. `RenderedFeature` (public) — what a query returns. `FeatureQueryHost` (`@internal`) — what the layer implements to attach |
| `label_mode.dart` | `LabelMode` — public enum: `screen` (default, per-frame screen-space label pass) or `tile` (labels baked into each tile's raster, `vector_map_tiles`' raster mode). Its doc comment carries the trade-off table |
| `tile_providers.dart` | `TileProviders` (providers keyed by style source id), `RasterTileSource` (a raster source declared inside a vector style — imagery, or with an `encoding` a `raster-dem` source for hillshading) and `DemEncoding` (how a DEM's red/green/blue pack metres: `terrarium`, `mapbox`, or the factors of a `custom` one) |
| `tile_offset.dart` | `TileOffset` — relates display zoom to data/style zoom. `TileOffset.maplibre` (offset −1, 512px convention) is the default |
| `logger.dart` | `Logger` abstraction plus a console implementation; the only sanctioned diagnostic channel (`avoid_print` is enforced). Redacts API keys in every message through `core/redact.dart`, so no call site has to |

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
| `text/` | Label text from the style's glyph PBFs: decoding, the script classifier, the pure-Dart shaper, and `GlyphSource` (see `text/AGENTS.md`) |

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
