<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-08-09 | Updated: 2026-08-09 -->

# core

## Purpose

The smallest shared primitives in the package. They are depended on by nearly
every other directory, so they sit at the bottom of the dependency graph and
import nothing from the package outside this directory.

## Key Files

| File | Description |
|------|-------------|
| `tile_key.dart` | `TileKey(z, x, y)` — a slippy-map tile identity, with `ancestorAt()` / ancestor-descendant helpers used by overzoom and parent-tile retention. Value equality and `hashCode` make it a safe cache key |
| `cancellation.dart` | `CancellationToken` — cooperative cancellation as a polled *state* (`isCancelled`), plus `CancellationToken.none` and `JoinedCancellationToken`, which reads cancelled only when *every* joined caller token is cancelled (the token coalesced work polls) |
| `single_flight.dart` | `SingleFlight<K, V>` — per-key coalescing of async work. Every store and network provider dedupes requests through it; it joins each caller's token so one abandoned caller never cancels work others still await, and it owns the `whenComplete`-block-body footgun in one place |
| `tile_zoom.dart` | The shared display-zoom→data-zoom mapping (`dataKeyForDisplay`, with the raster never-underzoom cap), the provisional-imagery walks both stores use — `findWithAncestors` (5 levels up, zoom-in) and `findDescendants` (2 levels down, possibly a partial cover, zoom-out) — and `displayTileSize`, the one 256-logical-px constant grid, render and the label pass all reference. Internal, not exported |

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
- `TileKey` and `CancellationToken` are re-exported from the public barrel, so
  signature changes are breaking changes. `SingleFlight` and
  `JoinedCancellationToken` are internal.
- `SingleFlight.run` cancellation semantics are load-bearing: a flight's token
  reads cancelled only when *all* joined tokens are cancelled, and a live
  joiner arriving before the next poll revives the work. Changing this
  reintroduces the coalesced-load poisoning bug it exists to prevent.

### Testing Requirements

`test/tile_key_test.dart` covers wrapping, ancestor arithmetic and equality.
Keep coordinate-arithmetic changes covered there — the shifts are easy to get
off by one and the failure mode is a subtly misplaced tile.
`test/single_flight_test.dart` covers coalescing, all-waiters cancellation
aggregation, and `clear()` not evicting successor flights.

### Common Patterns

- Immutable, `const`-constructible, no Flutter imports — these are plain Dart
  so they can cross into worker isolates freely.

## Dependencies

### Internal

- None outside this directory (`single_flight.dart` imports
  `cancellation.dart`)

### External

- None

<!-- MANUAL: -->
