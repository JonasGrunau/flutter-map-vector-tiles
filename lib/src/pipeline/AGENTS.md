<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-08-09 | Updated: 2026-08-09 -->

# pipeline

## Purpose

The off-thread decode-and-trim step: raw MVT bytes in, a compact
`PreparedTile` out. Everything here is constrained by isolate transfer — the
input and output must be cheap to send across an isolate boundary, and the
work itself must be a pure function so it can run anywhere.

## Key Files

| File | Description |
|------|-------------|
| `tile_processor.dart` | `PrepareInput` (bytes + tile key + the per-layer properties the theme actually references + `filterIds`, the zoom-free layer filters to resolve per source layer) and `prepareTileSync(PrepareInput, {filters})` — the pure decode + trim step that runs on the worker. Sniffs the gzip magic and inflates first: PMTiles blobs arrive compressed on native platforms so the CPU cost lands here, off the UI isolate. Given the worker's `CompiledFilters`, it also scans each source layer's features against the filters `filterIds` names (one shared `EvalContext` per feature) into `PreparedSourceLayer.matches`; without them — the web executor, the inline fallback — it resolves none |
| `tile_filters.dart` | `TileFilterPlan` — per store, which filter ids a data tile at zoom z gets resolved (`idsAt(z)`, memoized): those of layers drawing in the tile's own band, z alone, or everything past the source's deepest level and before its shallowest. `CompiledFilters` — the worker's cache of filters compiled from their JSON source with the theme reader's `ExpressionParser`, by `FilterIds` id |
| `prepare_gunzip_io.dart` / `prepare_gunzip_web.dart` | Conditional import behind that sniff: synchronous `dart:io` gzip on native; a pass-through on web, where providers inflate at fetch (no worker isolate, and `DecompressionStream` is async) |
| `prepared_tile.dart` | The transferable result model: `PreparedTile` (keyed, with a `byteSize` estimate for cache accounting) → `PreparedSourceLayer` (extent + features + `matches`: per filter id, the ascending `Int32List` of feature indices it selects, null for every feature, absent for not resolved) → `PreparedFeature` (geometry runs plus decode-time `minX/minY/maxX/maxY` bounds that the renderer culls against; infinite defaults mean "unknown, never cull"), plus `PreparedGeomType` (point/line/polygon, in `$type` terms) |

## Subdirectories

| Directory | Purpose |
|-----------|---------|
| `executor/` | The platform-conditional executor that runs `prepareTileSync` (see `executor/AGENTS.md`) |

## For AI Agents

### Working In This Directory

- **Transferability is the hard constraint.** `PrepareInput` and `PreparedTile`
  cross an isolate boundary: geometry lives in `Float32List`s, properties in
  plain maps of primitives. No closures, no `ui.*` types, no `Theme` object —
  which is exactly why the theme is reduced to *layer property name sets*
  before being sent, and its filters to *ids* (`style/filter_ids.dart`)
  whose JSON source each worker is sent once and compiles itself.
- **A worker match list must equal the UI's scan.** `MatchedFeatures`
  trusts `PreparedSourceLayer.matches` without re-checking, so the worker
  evaluates exactly what `MatchedFeatures._match` would: the filter the
  theme reader compiled from the same JSON, against the same trimmed
  properties, geometry type and id, at zoom 0 (the filter is zoom-free).
  `test/tile_filters_test.dart` holds the two equal on Liberty and on a
  filter-heavy synthetic style; extend it with any new filter shape.
- **Trimming is what keeps memory bounded.** Only feature properties the theme
  actually references are retained (`ExpressionParser` records them via
  `_refProp`). If a new style feature reads a property, it must be registered
  there or it will arrive `null` on the worker — a silent, data-dependent bug.
- `prepareTileSync` must stay pure: no logging to the UI, no I/O, no
  `dart:ui` *calls* — every drawing, text and image API is root-isolate
  only. The expression parser it compiles filters with only uses
  `dart:ui`'s `Color` and Flutter's `Cubic` as plain values, which work
  in any isolate.
- `byteSize` feeds the `LruCache` cost function. A wrong estimate does not
  break rendering; it breaks the memory budget quietly.

### Testing Requirements

The prepare step is exercised through `test/mvt_decoder_test.dart` and the
store tests. `test/executor_test.dart` covers the executor contract. Because
isolate failures are asynchronous and easy to swallow, any change to the
worker protocol should be checked with a deliberately malformed tile.

### Common Patterns

- `PreparedTile.empty` stands in for 404s and decode failures, so a missing
  tile is a normal cached value rather than a retry loop.

## Dependencies

### Internal

- `mvt/` (decoding), `core/tile_key.dart`, `core/cancellation.dart`,
  `style/` (`ExpressionParser`, `FilterIds`, `ThemeLayer` for the plan)

### External

- `dart:typed_data`

<!-- MANUAL: -->
