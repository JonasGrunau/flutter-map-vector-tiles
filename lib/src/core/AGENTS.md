<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-08-09 | Updated: 2026-08-09 -->

# core

## Purpose

The two smallest shared value types in the package. Both are exported publicly
and both are depended on by nearly every other directory, so they sit at the
bottom of the dependency graph and import nothing from the package.

## Key Files

| File | Description |
|------|-------------|
| `tile_key.dart` | `TileKey(z, x, y)` — a slippy-map tile identity, with `ancestorAt()` / ancestor-descendant helpers used by overzoom and parent-tile retention. Value equality and `hashCode` make it a safe cache key |
| `cancellation.dart` | `CancellationToken` — cooperative cancellation as a polled *state* (`isCancelled`), plus `CancellationToken.none`. Eleven lines, deliberately |

## For AI Agents

### Working In This Directory

- **Never make cancellation throw.** The whole pipeline's contract is that a
  cancelled job resolves to `TileResponseCancelled` / a discarded result, so
  cancellations never reach a user's crash reporter. Adding a
  `throwIfCancelled()` helper would violate this.
- `TileKey` is used as a `Map` key across every cache layer. Any change to its
  fields, equality or `hashCode` invalidates cache keying — check
  `grid/tile_store.dart`, `grid/raster_tile_store.dart` and the raster image
  cache in `vector_tile_layer.dart`.
- Both types are re-exported from the public barrel, so signature changes are
  breaking changes.

### Testing Requirements

`test/tile_key_test.dart` covers wrapping, ancestor arithmetic and equality.
Keep coordinate-arithmetic changes covered there — the shifts are easy to get
off by one and the failure mode is a subtly misplaced tile.

### Common Patterns

- Immutable, `const`-constructible, no Flutter imports — these are plain Dart
  so they can cross into worker isolates freely.

## Dependencies

### Internal

- None (leaf)

### External

- None

<!-- MANUAL: -->
