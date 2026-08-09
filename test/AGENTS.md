<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-08-09 | Updated: 2026-08-09 -->

# test

## Purpose

The package's test suite — flat, no mocking framework, no golden files. Pure
logic is unit tested directly; anything involving `ui.Image` ownership, tile
lifecycle or painting is covered by widget tests that pump a real
`FlutterMap`. Tests import package internals via
`package:flutter_map_vector_tiles/src/…` where needed.

## Key Files

| File | Description |
|------|-------------|
| `expression_test.dart` | Style expression compilation: operators, interpolation, legacy syntax, coercions |
| `tile_lifecycle_test.dart` | Widget-level: first paint, zoom changes, pan, cache attachment, disposal. The heaviest and most integration-shaped test |
| `symbol_layouter_test.dart` | Label placement candidates, tile-seam behaviour, overzoom |
| `raster_source_test.dart` | Raster sources declared inside vector styles, image ref-counting |
| `tile_store_test.dart` | Memory/disk cache keying, miss paths, disposal |
| `curved_text_test.dart` | Text along lines and the sharp-bend fallback |
| `sdf_icon_test.dart` | SDF sprite tinting |
| `tile_retention_test.dart` | The pure retention predicates (17 cases) |
| `theme_reader_test.dart` | Layer parsing and MapLibre spec defaults |
| `line_pattern_test.dart`, `fill_pattern_test.dart` | Pattern paints |
| `disk_cache_test.dart`, `lru_cache_test.dart` | Cache eviction, TTL, size sweep |
| `style_reader_cache_test.dart` | Stale-while-revalidate style loading |
| `style_reader_sources_test.dart` | Source URL resolution: relative TileJSON/tile templates (ArcGIS `root.json` shape), `{key}` substitution |
| `pmtiles_test.dart` | PMTiles: Hilbert tile IDs (spec anchors + bijection), directory decode/lookup, range-request provider (leaves, coalescing, cancellation), `pmtiles://` style wiring |
| `pmtiles_gzip_test.dart` | VM-only: gzip-compressed archives via `dart:io` gzip; brotli/zstd rejection |
| `pmtiles_gunzip_web_test.dart` | Browser-only: `DecompressionStream` gunzip round-trip |
| `mvt_decoder_test.dart` | MVT decoding against independently built fixtures |
| `variable_anchor_test.dart` | Variable text anchors |
| `tile_precision_test.dart` | Tile transform precision |
| `grid_layout_test.dart` | Visible tile set, load ordering, tile rects |
| `css_color_test.dart` | All CSS colour syntaxes |
| `executor_test.dart` | Executor contract: priority ordering, silent cancellation, disposal |
| `tile_key_test.dart` | Tile coordinate arithmetic and equality |

## Subdirectories

| Directory | Purpose |
|-----------|---------|
| `fixtures/` | Test data builders (see `fixtures/AGENTS.md`) |

## For AI Agents

### Working In This Directory

- **`tile_lifecycle_test.dart`'s "reopened map paints from cache" case is known
  to flake under parallel test load** (the memory caches are process-wide).
  Re-run it before concluding a regression exists.
- Prefer `MemoryVectorTileProvider` over network stubs; where HTTP is genuinely
  under test, inject an `http.Client`.
- **Test the interface, not the implementation** — especially for the executor,
  where two platform implementations must satisfy one contract.
- Every bug fix gets a regression test. Several tests here exist because a
  specific rendering bug shipped once (SDF blobs, duplicate seam labels, zoom
  jitter); name new ones after the behaviour, not the bug number.
- Widget tests must dispose the map and assert no images leak — image ownership
  bugs are the most common defect class in this package.

### Testing Requirements

```
flutter test                       # whole suite
flutter test test/foo_test.dart    # one file
```

The suite must be green and `flutter analyze` clean before any release; there
is no CI to catch either.

### Common Patterns

- Plain `test()`/`testWidgets()` with `expect` — no mocks, no code generation.
- Fixtures are built in-test from `fixtures/mvt_builder.dart` rather than
  checked in as binary blobs, so the input to a failing test is readable.
- Fixture encoders must be web-safe too. `mvt_builder.dart`'s `zig()` uses
  arithmetic, not `(v << 1) ^ (v >> 31)`: under dart2js the shift form
  mis-encodes negative deltas, which would make the decoder's round-trip
  tests pass on chrome for the wrong reason.

## Dependencies

### Internal

- The package under test, including `src/` internals

### External

- `flutter_test`, `flutter_map` (for widget tests)

<!-- MANUAL: -->
