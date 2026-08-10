<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-08-09 | Updated: 2026-08-09 -->

# cache

## Purpose

The package's cache layer, deliberately small and deterministic. A stated
design goal is *no external cache framework* — these files replace what
`stash` did in `vector_map_tiles`, with no disk index file that can corrupt.
Two primitives (an in-memory LRU and a disk byte store) sit behind the
platform-neutral `ByteCache` interface, with conditional-import resolvers
selecting the disk implementation on IO platforms and none on web.

## Key Files

| File | Description |
|------|-------------|
| `lru_cache.dart` | `LruCache<K, V>` — insertion-ordered LRU with optional per-entry cost accounting (`costOf`), an adjustable cost budget (`setMaxCost`) and an `onEvict` callback. Bounded by entry count and/or total cost, with predicate-based pruning via `removeWhere` |
| `byte_cache.dart` | `ByteCache` — the platform-neutral interface callers hold (`get`/`getStale`/`put`); `DiskCache` implements it on IO platforms |
| `disk_cache.dart` | `DiskCache` — raw bytes on disk keyed by an FNV-1a hash of the URL, one file per entry. Freshness TTL plus a total-size sweep; the sweep is single-flight (`_sweepInFlight`) and fired opportunistically after writes |
| `cache_resolver.dart` | Conditional-import facade: `obtainTileCache()` / `openStyleCache()` resolve to the IO implementation or the web stub |
| `cache_resolver_io.dart` | IO resolver — `path_provider` directories, size/TTL wiring |
| `cache_resolver_stub.dart` | Web resolver — resolves to null (no persistent cache; the browser HTTP cache applies) |

## For AI Agents

### Working In This Directory

- **`onEvict` is how images get disposed.** Every raster cache passes a
  disposer; if you add a new `LruCache` holding `ui.Image`s and forget it, you
  leak GPU memory silently. Same for `clear()` paths.
- **The `whenComplete` footgun.** `_sweep()` uses
  `_sweepInFlight ??= _doSweep().whenComplete(() { … })` in *block* body. An
  arrow-bodied `whenComplete` that returns the in-flight future deadlocks it —
  do not "simplify" that into an expression body.
- `DiskCache` has a static `reset()` used by tests to drop the shared instance;
  the cache is shared process-wide so that reopening a map reuses it.
- Disk caching depends on `path_provider`, which has no web support — callers
  therefore hold the interface as `ByteCache?` (see `grid/tile_byte_loader.dart`,
  `style/style_reader.dart`, `vector_tile_layer.dart`) and treat null as
  "no persistent cache".

### Testing Requirements

`test/lru_cache_test.dart` (eviction order, cost accounting, evict callbacks)
and `test/disk_cache_test.dart` (TTL, size sweep, corrupt/missing files) run
against a temp directory. Any change to eviction or sweep semantics needs a
test there — these bugs surface as unbounded memory or missing tiles much
later, never at the edit site.

### Common Patterns

- Bounds are always *both* count and bytes where entries vary in size.
- The disk layer stores opaque `Uint8List`s and knows nothing about tiles,
  styles or sprites — callers own the key namespace.

## Dependencies

### Internal

- `../logger.dart`; used by `grid/`, `style/style_reader.dart`,
  `vector_tile_layer.dart`

### External

- `dart:io` (`File`, `Directory`) behind conditional imports,
  `dart:typed_data`, `path_provider` (IO resolver only)

<!-- MANUAL: -->
