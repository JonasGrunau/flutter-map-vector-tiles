<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-10-26 | Updated: 2026-10-26 -->

# text

## Purpose

Label text drawn from the style's own fonts: MapLibre's glyph PBFs
(`{fontstack}/{range}.pbf`, signed distance fields at a 24 px em),
decoded and laid out here, drawn by `render/label_painter.dart` through
the glyph atlas. Everything except `glyph_source.dart` is pure Dart with
no `dart:ui`, so it could run on any isolate.

## Key Files

| File | Description |
|------|-------------|
| `glyph_pbf.dart` | `decodeGlyphPbf`: a glyph PBF → `SdfGlyph`s by code point (metrics at 24 px, the distance field with its 3 px border). Its own minimal protobuf reader, arithmetic not bitwise, like the MVT decoder's. `glyphPbfEm`, `glyphPbfBorder` |
| `glyph_script.dart` | `isGlyphShapeable`: whether a label can be drawn glyph by glyph with no shaping. A whitelist by code point — Latin (precomposed), Greek, Cyrillic, Armenian, Georgian, digits, punctuation, common symbols; anything else (RTL, Indic and Southeast Asian scripts, combining marks, CJK, emoji, joiners, astral planes) keeps the platform's `Paragraph` path |
| `glyph_shaper.dart` | `shapeGlyphs`: MapLibre's layout from glyph metrics — advance plus letter spacing, `\n` as a forced break, balanced breaking at `text-max-width` with MapLibre's break characters and parenthesis penalty, lines judged without their spaces against the whole text's width over the fewest lines (a word wider than the limit stays whole), lines 1.2 em apart centred on each other — into a `ShapedGlyphs` (glyphs + `Float32List` pen positions). Null when a glyph is missing. `glyphLineMiddleToReference` places a bitmap on its line as MapLibre does |
| `glyph_source.dart` | `GlyphSource` (public): loads ranges through a `GlyphRangeLoader` (or `GlyphSource.network`), at most once each, never failing the caller — a failed range stays failed for the source's life and its labels use the platform. Each loaded range becomes a `GlyphRange`: the glyphs plus one texture with every distance field packed on it (`decodeImageFromPixels`, root isolate only). `ensure` starts loads and returns a future that completes when they settle; `rangeOf`/`isLoading` are what the painter consults. `glyphRangeUrl` encodes a stack, keeping its commas |

## For AI Agents

### Working In This Directory

- **Routing errs toward the platform.** A script added to
  `isGlyphShapeable` must be one whose letters never change shape or
  position with their neighbours, and must come with tests in
  `test/glyph_text_test.dart` (and the script test suite). Drawing a
  script wrongly from glyphs is worse than drawing it in a system font.
- **Keep the shaper pure.** No `dart:ui` in `glyph_pbf.dart`,
  `glyph_script.dart` or `glyph_shaper.dart`; the option of shaping on
  the worker depends on it.
- **Implement from the spec and MapLibre's behaviour, not its code**
  (clean-room package). The metric conventions here (24 px em, 3 px
  border, outline at 192/255, 8 px of distance across the field, the
  17 px line-middle offset) are what every glyph server and MapLibre
  agree on; tests pin them.
- `test/fixtures/glyph_pbf_builder.dart` encodes glyph PBFs from the
  schema, independently of the decoder — keep it that way.

### Testing Requirements

`test/glyph_text_test.dart` (decoder, classifier, shaper),
`test/glyph_label_test.dart` (the painter's glyph path, pixels
included), `test/glyph_layer_test.dart` (the pump waiting for ranges).
All run on Chrome too.

## Dependencies

### Internal

- `../logger.dart`, `../core/redact.dart` (glyph_source)

### External

- `http` (`GlyphSource.network`), `meta`
