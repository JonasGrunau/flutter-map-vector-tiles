<!-- Generated: 2026-08-09 | Updated: 2026-08-09 -->

# flutter_map_vector_tiles

## Purpose

A published Flutter package (pub.dev) that renders MapLibre / Mapbox GL vector
styles as a plain `flutter_map` layer. It is a clean-room, self-contained
rewrite of the ideas behind `vector_map_tiles`: MVT decoding, the style engine,
the tile pipeline, caching and rendering all live in this one package — no
renderer / cache / executor satellite packages.

The design commitments that shape almost every file: geometry is rasterized
**once** per display tile into a GPU-resident `ui.Image`; labels are **not**
baked into those rasters but drawn per frame in screen space with one global
collision pass; cancellation is a **state**, never an exception; every
`ui.Image` has exactly one owner and is disposed on eviction.

## Key Files

| File | Description |
|------|-------------|
| `pubspec.yaml` | Package manifest — name, `version:` (source of truth for the README install snippet), dependency constraints, SDK/Flutter minimums |
| `README.md` | User-facing documentation: quick start, configuration, style support, offline behaviour, troubleshooting |
| `CHANGELOG.md` | One section per released version; every user-visible change lands here. Fixed shape — heading, one-sentence summary line, emoji-prefixed bullets grouped by kind in a fixed order (see `CLAUDE.md`) |
| `CLAUDE.md` | Agent working agreements — doc-sync rules, README/version rules, release gate. Imports this file via `@AGENTS.md` |
| `analysis_options.yaml` | `flutter_lints` + strict casts/inference/raw-types, plus `prefer_final_locals`, `unawaited_futures`, `avoid_print`, `directives_ordering` |
| `.gitignore` | Repo exclusions |
| `.pubignore` | Publish exclusions. Pub uses this **instead of** `.gitignore`, so it repeats every entry there and adds the agent docs |
| `LICENSE` | BSD-3-Clause |

## Subdirectories

| Directory | Purpose |
|-----------|---------|
| `lib/` | Package source — the entire library (see `lib/AGENTS.md`) |
| `test/` | Unit and widget tests, no mocking framework (see `test/AGENTS.md`) |
| `bench/` | On-device frame-timing and label-stability harness for zoom crossings — profile-mode app that sweeps a zoom band (or records while you zoom by hand in `manual` mode) and reports UI/raster frame-time distributions, cache-hit counters and, in `stability` mode, label pop/blink counts. Not published (see `bench/AGENTS.md`) |
| `example/` | Runnable example app driven by `--dart-define` (see `example/AGENTS.md`) |
| `doc/` | `ARCHITECTURE.md` — the prose companion to this file; update it when the data flow, rendering model, concurrency model or cache layers change |
| `screenshots/` | pub.dev gallery images (WebP, framed in an iPhone bezel), wired up via `screenshots:` in `pubspec.yaml` — these ship in the package; regeneration recipe in `screenshots/AGENTS.md` |

## For AI Agents

### Working In This Directory

- **Docs are part of the change.** Any behaviour, structure or public-API
  change updates `README.md`, `doc/ARCHITECTURE.md`, `CHANGELOG.md` and the
  affected `AGENTS.md` in the *same* change. See `CLAUDE.md`.
- **Version identity.** The install snippet in `README.md` must match
  `version:` in `pubspec.yaml`, as must the `flutter_map` constraint shown
  there. Bumping one without the other is an incomplete change.
- **Ignore files come in pairs.** Pub reads `.pubignore` *instead of*
  `.gitignore` for this directory — not in addition to it. Any entry added to
  `.gitignore` must be added to `.pubignore` as well, or the thing you just
  excluded from the repo still ships to pub.dev. Verify with
  `dart pub publish --dry-run`, which prints the exact file list.
- **There is no CI.** Every gate is local and must be run by hand.
- **Frame-time claims need `bench/`, not reasoning.** Rendering costs here
  split across two threads — rasterization, symbol layout and text shaping on
  the UI thread, `saveLayer` on the raster thread — and a `saveLayer` only
  records an op during picture recording, so no Dart-side stopwatch can see
  what it costs. Before attributing a stutter to either, measure it on a real
  device in profile mode, across a zoom band where the style actually opens its
  label gates.
- **The public API is what `lib/flutter_map_vector_tiles.dart` exports.**
  Anything else under `lib/src/` is private and may be changed freely; adding
  an export is a semver-relevant decision.
- **Web is supported since 2.0.0** — tile preparation runs on a yielding
  event-loop executor there instead of isolates, PMTiles gunzip uses
  `DecompressionStream`, and web-only tests exist (`flutter test --platform
  chrome`). The one real limitation: there is no persistent disk cache on web
  (`path_provider` has no web support) — tiles and styles fall back to the
  in-memory caches and the browser's HTTP cache. Keep changes web-safe: no
  bare `dart:io` outside conditional imports, no bitwise ops on values past
  32 bits (see the MVT decoder's arithmetic). Losing the web platform tag in
  `pana` is a release blocker, so run the browser suite when touching
  anything platform-sensitive.
- **This package takes no native dependencies.** Anything needing `dart:ffi`
  or a platform channel belongs in a companion package behind
  `VectorTileProvider` — as MBTiles does, in
  `flutter_map_vector_tiles_mbtiles`. That is what keeps this one installable
  everywhere with no setup. Adding a provider hook the companion needs is
  fine and expected; adding the dependency itself is not.

### Testing Requirements

```
dart format .        # no CI — format drift silently costs pub points
flutter analyze      # must be clean
flutter test         # all green
```

Before publishing, additionally run `dart pub publish --dry-run` and a `pana`
run; the package holds full pub points and regressions there are treated as
release blockers.

### Common Patterns

- **Cancellation is a state.** `CancellationToken.isCancelled` is polled;
  cancelled work resolves to `TileResponseCancelled`, never a thrown exception,
  so cancellations never appear in crash reporting.
- **One owner per `ui.Image`.** Images are disposed on cache eviction, tile
  replacement and layer dispose. Shared raster-source images are handed out as
  ref-counted `clone()`s.
- **Deterministic caching only.** Plain LRU implementations in `lib/src/cache/`,
  no external cache framework, no disk index files to corrupt.
- **Tolerant style parsing.** Unknown layer types, paint properties and
  unparseable expressions degrade per-layer with a `Logger.warn`, never failing
  the whole style.
- **Isolate-transferable data.** Anything crossing into the worker isolate
  (`PrepareInput` / `PreparedTile`) must stay transferable — geometry lives in
  `Float32List`s, not object graphs.

## Dependencies

### External

- `flutter_map` ^8.2.0 — host map framework; it owns camera, gestures, layers
- `http` ^1.2.0 — tile and style fetching
- `path_provider` ^2.1.0 — disk cache directory (no web support)
- `latlong2`, `characters`, `meta` — coordinates, grapheme clustering for label
  layout, annotations
- `flutter_lints` ^6.0.0 (dev)

### Companions

- [`flutter_map_vector_tiles_mbtiles`](https://pub.dev/packages/flutter_map_vector_tiles_mbtiles)
  — MBTiles archives, kept out of this package because they need SQLite via
  `dart:ffi`. It consumes only the public barrel; `cacheBytesToDisk`,
  `StyleReader.resolveProvider` and the `SingleFlight` export exist for it and
  for anyone else writing a provider, so think twice before changing their
  semantics

<!-- MANUAL: Any manually added notes below this line are preserved on regeneration -->
