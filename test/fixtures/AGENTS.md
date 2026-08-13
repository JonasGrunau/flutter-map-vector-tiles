<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-08-09 | Updated: 2026-08-09 -->

# fixtures

## Purpose

Test data builders. There are no checked-in binary tile fixtures — test tiles
are constructed programmatically so the input to a failing test is readable in
the test itself.

## Key Files

| File | Description |
|------|-------------|
| `mvt_builder.dart` | `MvtTileBuilder` / `MvtLayerBuilder` — a minimal MVT (protobuf) encoder: layers, features, tags, geometry commands, varint and tag writing |
| `pmtiles_builder.dart` | `PmTilesArchiveBuilder` — a minimal PMTiles v3 archive writer: header, delta-varint directories, optional leaf splitting and pluggable compression. Web-safe (arithmetic only) so the same fixtures run in the browser suite |
| `lifecycle_harness.dart` | The widget-test harness: `app()` (a `FlutterMap` with one `VectorTileLayer` at a fixed 600×600), `CountingProvider` / `EverywhereProvider`, the pixel readers (`centrePixel`, `fullyPainted`) and the waits (`pumpUntil`, `settle`, `settleLoads`, `sampleDuring`) |

## For AI Agents

### Working In This Directory

- **This encoder is written independently against the MVT 2.1 spec**, deliberately
  *not* by inverting `lib/src/mvt/mvt_decoder.dart`. That independence is the
  whole point: if the builder were derived from the decoder, a shared
  misreading of the spec would round-trip cleanly and prove nothing. Do not
  refactor the two to share code.
- When adding wire-format support to the decoder, add the corresponding
  *encoding* here from the spec, not from the decoder's implementation.

### Testing Requirements

Exercised through `test/mvt_decoder_test.dart` and any test needing a tile with
specific geometry. It has no tests of its own — a bug here shows up as a
failing decoder test.

### Common Patterns

- Builders return `Uint8List` ready to hand to `decodeMvt` or to a
  `MemoryVectorTileProvider`.
- **Widget tests wait on the wall clock, never on a frame count.** The decode
  isolates and disk IO these tests wait for run outside the fake clock, so a
  `for (var i = 0; i < 30; i++) pump()` loop is a *shorter* deadline the busier
  the machine is — which is how the lifecycle tests used to flake in a parallel
  suite while passing alone. Wait with `pumpUntil` (or `settle` /
  `settleLoads`, both built on it) and let the timeout be the bound.
- **`settle` returns at the centre pixel; `settleLoads` waits for the grid.**
  Anything that compares what a *later* phase fetches or renders needs
  `settleLoads`: `settle` leaves the rest of the screenful — and the off-screen
  buffer ring — still in flight, and a tile in flight when the layer rebuilds
  is legitimately requested again, which then reads as a refetch of something
  already loaded. Pass `painted: false` when the tiles are not expected to
  paint at all, as during a simulated outage.
- **Assert `reloads`, not a `loads` snapshot**, for "this must reuse what it
  already has". A key fetched twice is unambiguous whenever it happens, where a
  count captured between two phases attributes late arrivals to the wrong one.

## Dependencies

### Internal

- None (deliberately independent of `lib/src/mvt/`)

### External

- `dart:typed_data`, `dart:convert`

<!-- MANUAL: -->
