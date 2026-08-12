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
| `mbtiles_builder.dart` | `MbTilesArchiveBuilder` — writes a `.mbtiles` file to a path: metadata rows, tiles at TMS coordinates, and optionally the deduplicating `map`/`images` view schema. Also `dropTilesTable()`, for the invalid-archive case. The write sits behind a conditional import (`_io` / `_stub`) |

## For AI Agents

### Working In This Directory

- **This encoder is written independently against the MVT 2.1 spec**, deliberately
  *not* by inverting `lib/src/mvt/mvt_decoder.dart`. That independence is the
  whole point: if the builder were derived from the decoder, a shared
  misreading of the spec would round-trip cleanly and prove nothing. Do not
  refactor the two to share code.
- When adding wire-format support to the decoder, add the corresponding
  *encoding* here from the spec, not from the decoder's implementation.
- **`mbtiles_builder.dart` is the one exception, and cannot be otherwise** —
  SQLite is the container, so only SQLite writes it; there is no independent
  implementation to write. The independence that matters is kept a level up:
  fixtures are laid out with plain `CREATE TABLE` / `INSERT` against the
  spec's schema, so the table shape and the TMS row convention under test are
  expressed separately from the provider's read query. Keep it that way —
  never build a fixture by calling into `lib/src/provider/mbtiles/`.
- **Never import `package:sqlite3` from a file under `test/` directly** — only
  through `mbtiles_builder_io.dart`, behind the conditional import.
  `@TestOn('vm')` gates when a test *runs*, not whether it compiles: `dart:io`
  survives a web compile (the web SDK has it, and it throws at runtime),
  but `package:sqlite3` reaches `dart:ffi`, which does not exist there. One
  direct import breaks `flutter test --platform chrome` for the entire suite,
  with an error naming `sqlite3`'s generated bindings rather than your file.

### Testing Requirements

Exercised through `test/mvt_decoder_test.dart` and any test needing a tile with
specific geometry. It has no tests of its own — a bug here shows up as a
failing decoder test.

### Common Patterns

- Builders return `Uint8List` ready to hand to `decodeMvt` or to a
  `MemoryVectorTileProvider`.

## Dependencies

### Internal

- None (deliberately independent of `lib/src/mvt/`)

### External

- `dart:typed_data`, `dart:convert`

<!-- MANUAL: -->
