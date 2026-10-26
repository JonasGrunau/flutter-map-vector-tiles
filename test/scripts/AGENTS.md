<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-10-26 | Updated: 2026-10-26 -->

# scripts

## Purpose

How labels in every script are drawn, locked in: Latin with stacked
diacritics, Cyrillic, Greek, Armenian, Georgian, Arabic, Persian, Urdu,
Hebrew, mixed right-to-left with Latin and digits, Devanagari, Bengali,
Tamil, Thai, Lao, Khmer, Myanmar, Sinhala, Tibetan, Chinese, Japanese,
Korean, emoji sequences and combining marks — each straight with a
halo, wrapped at `text-max-width`, and along a curved line. Everything
goes through the real `LabelPainter` with real fonts. It is the guard
for any change to shaping, wrapping or curved text (the glyph shaper of
piece 07 above all): such a change keeps this suite green or says, in
the same change, which drawing it changes and why.

## Key Files

| File | Description |
|------|-------------|
| `script_samples.dart` | The text: per script a name, a longer label and the lines it wraps into at 5 em today, and whether it bends along a curve; the mixed-direction, emoji, combining-mark, pre-base-vowel and stacking probes. Pure Dart, read by `fonts/charset.dart` |
| `script_harness.dart` | Loads the fonts (`loadScriptFonts`, which names them in `LabelPainter.debugFontFamilies`), builds label candidates (`label`), paints them (`paintLabels`, `drawLabel`) and measures the pixels (`LabelImage`: ink boxes, coverage of one drawing by another within a pixel, gap columns, the droop of a curved label). Knows nothing of how the painter draws |
| `script_rendering_test.dart` | The structural assertions, on pixels: no `.notdef` box or empty glyph anywhere; wrapping only where the script breaks lines (each expected line found in place); halos around the letters and off them; curve-safe scripts bending glyph by glyph, the others drawn straight; first letter rightmost in right-to-left scripts, digits and Latin words on the right side, each line in its own direction; Arabic joining, lam-alef, vowel marks; pre-base vowel signs drawn before their consonant; conjuncts; marks stacked over or under; ZWJ, flag and skin-tone sequences as one glyph; decomposed text drawn like precomposed, straight and curved. VM and Chrome |
| `script_goldens_test.dart` | One golden per script (name with halo, the name on an arc, the wrapped label) plus mixed directions and combining marks, in `goldens/`. No emoji: Noto Emoji's detailed outlines rasterize 16–18 px apart on macOS and Linux, past the comparator's limit; the rendering test covers them. VM only |
| `tolerant_golden_comparator.dart` | `TolerantGoldenComparator`: compares the text mask and the halo mask of a golden within a device pixel and fails on any connected patch over 12 device pixels — what a missing mark or a moved letter leaves, and rasterizer anti-aliasing never does. `tolerant_golden_comparator_web.dart` is the no-op the browser build compiles instead |
| `script_fonts_io.dart`, `script_fonts_web.dart` | Font bytes from disk, or from the test server in the browser; and, in the browser, `allowLoadedFonts`, which lifts the test environment's forced box-glyph font |
| `fonts/` | Noto subset fonts, `OFL.txt`, and `build.sh` + `charset.dart` that rebuild them |

## For AI Agents

### Working In This Directory

- **The assertions are about what a reader sees, not how the painter
  gets there.** Keep `LabelImage` free of painter internals: the suite
  must hold for any renderer that draws a script correctly, which is
  what lets it judge one that replaces the paragraph path.
- **Added a sample string? Rebuild the fonts** (`fonts/build.sh`, needs
  `pip install fonttools` and network). The fonts hold only the
  characters the samples use; anything else draws as a `.notdef` box,
  and the coverage test says which code point. `build.sh` downloads
  from a pinned google/fonts commit, so a rebuild changes a font only
  when the text does.
- **Fonts are a fallback list, the stand-in for a phone's system fonts.**
  `flutter test` has no system fonts and no font fallback, so the
  harness loads the fonts and names them, in order, through
  `LabelPainter.debugFontFamilies` (null in apps). The order matters:
  each font keeps only the characters no font before it maps, and an
  invisible joiner only where a sample puts it next to a letter it
  draws — a font that maps ZWNJ but not the Arabic around it, ahead of
  the Arabic font, makes the fallback draw the letters as `.notdef`.
- **Regenerating the goldens**, after a deliberate change, on macOS:

  ```
  flutter test --update-goldens test/scripts/script_goldens_test.dart
  ```

  Look at every image that changed before committing it. CI compares
  them on Linux through `TolerantGoldenComparator`; if CI fails while
  macOS passes, the message gives the size of the differing patch —
  raise `maxPatch` only for anti-aliasing, never past what a mark is.
- **Do not go back to `matchesGoldenFile` here.** Given a `ui.Image`,
  it runs the comparator through `binding.runAsync`, which only parks
  an error for `testWidgets` to report: in these plain `test`s every
  mismatch passed (forcing every comparison to fail left all 25 green).
  `script_goldens_test.dart` calls `goldenFileComparator` directly.
- **The browser run uses the fonts too.** The web test environment
  forces the box-glyph test font on every family; `allowLoadedFonts`
  swaps in one that does not, with font fallback still off so no test
  reaches the network. The goldens are VM-only (web rasterizes text
  differently), and their file still compiles for the browser suite —
  hence the conditional import of the comparator.
- **`lines` in the samples are today's breaks, reviewed by hand.** Korean
  breaks between syllables of 세종대로, where MapLibre would break only
  at spaces; the comment there says so. Change a sample's lines only
  together with the behaviour, and say why in the change.

### Testing Requirements

```
flutter test test/scripts                       # VM: structural + goldens
flutter test --platform chrome test/scripts     # browser: structural
```

About 4 s on the VM, 15 s in Chrome.

## Dependencies

### Internal

- `lib/src/render/label_painter.dart`, `symbol_layouter.dart`,
  `lib/src/style/theme_reader.dart`

### External

- `flutter_test`, `http` (fonts in the browser), `characters`
- Noto fonts (SIL Open Font License 1.1, see `fonts/OFL.txt`)

<!-- MANUAL: -->
