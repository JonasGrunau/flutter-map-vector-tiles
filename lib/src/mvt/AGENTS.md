<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-08-09 | Updated: 2026-08-09 -->

# mvt

## Purpose

A self-contained Mapbox Vector Tile (MVT 2.1) decoder — a hand-written
protobuf wire-format reader plus the decoded tile model. There is no
`protobuf` package dependency and no generated code; this is the reason the
package ships as a single dependency.

## Key Files

| File | Description |
|------|-------------|
| `mvt_decoder.dart` | `decodeMvt(Uint8List)` — the whole decoder: `_Reader` (varint/float/double/string/submessage/skip over a byte range), layer and feature decoding, the geometry command loop (`MoveTo`/`LineTo`/`ClosePath` with zigzag deltas), and `_shoelace` ring-winding classification in y-down screen coordinates |
| `mvt_tile.dart` | The decoded model: `MvtTile` → `MvtLayer` → `MvtFeature` (including per-feature `minX/minY/maxX/maxY` bounds folded in during decode, which the renderer's overzoom culling depends on), plus `MvtGeomType` (unknown/point/lineString/polygon) |

## For AI Agents

### Working In This Directory

- **This code runs inside worker isolates**, called from
  `pipeline/tile_processor.dart`. Keep it pure Dart — no Flutter imports, no
  I/O, no logging that assumes a UI thread.
- **Winding matters.** `_shoelace` returns positive area for exterior rings in
  y-down coordinates; polygon interior/exterior classification (and therefore
  holes) depends on that sign convention. Do not "fix" it to y-up.
- Malformed input must fail as a `FormatException` (`truncated varint`,
  `unsupported wire type`), which the pipeline turns into an empty tile — never
  let it become an unhandled async error.
- Output geometry is in tile-extent units (typically 4096); the mapping to
  pixels happens later in `render/tile_rasterizer.dart`.

### Testing Requirements

`test/mvt_decoder_test.dart` decodes tiles built by `test/fixtures/mvt_builder.dart`
— an independent encoder written against the spec, so encoder and decoder
don't share bugs. Add round-trip cases there for any new wire-format handling,
including a truncated/garbage input case.

Run the file under `--platform chrome` as well as the VM. Negative coordinate
deltas are the tripwire: `int` is 64-bit on native but dart2js truncates
bitwise ops to 32 bits, so a decoder change can be correct on the VM and
silently wrong on web. `decodes negative coordinate deltas`, `zigzag
round-trips the full delta range` and `decodes negative sint property
values` exist to catch exactly that.

### Common Patterns

- Geometry is accumulated into `Float32List` runs (not `List<Offset>`) so it
  stays cheap to transfer between isolates.
- The reader operates over `(start, end)` ranges of the original buffer rather
  than copying sublists.

## Dependencies

### Internal

- None (leaf); consumed by `pipeline/tile_processor.dart`

### External

- `dart:typed_data`, `dart:convert`

<!-- MANUAL: -->
