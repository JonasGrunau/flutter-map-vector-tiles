<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-08-09 | Updated: 2026-08-09 -->

# lib

## Purpose

The package source root. Contains exactly one public file — the barrel that
defines the package's entire public API — and `src/`, which holds every
implementation detail.

## Key Files

| File | Description |
|------|-------------|
| `flutter_map_vector_tiles.dart` | The public API barrel. Exports `VectorTileLayer`, `StyleReader`/`Style`, `Theme`/`ThemeReader`, the provider hierarchy (incl. `PmTilesVectorTileProvider` and the PMTiles format API: `PmTilesHeader`, `PmTilesDirectory`, `PmTilesEntry`, `PmTilesCompression`, `PmTilesException`, `zxyToTileId`, `pmTilesMaxAddressableZoom`, plus `MbTilesVectorTileProvider`, `MbTilesMetadata` and `MbTilesException`), `TileKey`, `TileOffset`, `TileProviders`, `SpriteAtlas`, `StyleAttribution`/`AttributionSpan`, `Logger`, and the `show`-limited `CancellationToken` (from `src/core/cancellation.dart` — `JoinedCancellationToken` stays internal) and `EvalContext` (from `src/style/expression.dart`) |

## Subdirectories

| Directory | Purpose |
|-----------|---------|
| `src/` | All implementation code, grouped by concern (see `src/AGENTS.md`) |

## For AI Agents

### Working In This Directory

- **The barrel is the API contract.** Adding an `export` here widens the public
  surface and is a semver-relevant decision — do not add one incidentally to
  make a test compile (tests may import `package:flutter_map_vector_tiles/src/…`
  directly).
- Everything under `src/` is private by convention; renaming or restructuring
  there is free as long as the barrel's exported names and signatures hold.
- Exports are kept alphabetically ordered (`directives_ordering` lint).

### Testing Requirements

`flutter test` from the package root. Changes to the barrel should be sanity
checked against `example/lib/main.dart`, which consumes the package through it
with a `vt.` prefix.

### Common Patterns

- Library-level doc comment on `flutter_map_vector_tiles.dart` is what pub.dev
  shows as the library description — keep it in step with the `pubspec.yaml`
  description.

## Dependencies

### Internal

- `lib/src/` — everything re-exported here

### External

- None directly; see the root `AGENTS.md`

<!-- MANUAL: -->
