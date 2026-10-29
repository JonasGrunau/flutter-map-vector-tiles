import 'package:characters/characters.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_map_vector_tiles/src/text/glyph_script.dart';
import 'package:flutter_map_vector_tiles/src/text/glyph_source.dart';
import 'package:flutter_test/flutter_test.dart';

import 'script_fonts_io.dart'
    if (dart.library.js_interop) 'script_fonts_web.dart';
import 'script_harness.dart';
import 'script_samples.dart';

/// The script suite with the style's glyphs attached, as a layer given
/// `glyphs` draws: Noto Sans Regular glyph PBFs from OpenFreeMap,
/// subset to the samples (`glyphs/`, rebuilt by `glyphs/build.sh`).
///
/// The scripts the glyphs can draw — Latin, Greek, Cyrillic, Armenian,
/// Georgian — must draw every grapheme from them, wrap where MapLibre
/// wraps them, keep their halo and bend along a curve. Every other
/// script must not notice the glyphs at all: drawn with them attached,
/// it is the same image, pixel for pixel, as without.
///
/// Measurements are in device pixels at a pixel ratio of 2.
const em = textSize * 2;

/// The lines MapLibre GL JS 4.7.1 breaks the glyph-drawn samples into
/// at a `text-max-width` of 5, with these glyphs — rendered side by
/// side to check. MapLibre balances the lines instead of filling them,
/// so Nordic, Polish and Greek come out in two lines where the
/// platform's greedy breaking (`ScriptSample.lines`) gives three.
const _maplibreLines = {
  'Latin': ['Bãi biển', 'Mỹ Khê', 'Đà Nẵng'],
  'Nordic Latin': ['Øresundsbroen', 'Ærø Færøerne'],
  'Polish Latin': ['Województwo', 'śląskie Łódź'],
  'Cyrillic': ['Улица', 'Большая', 'Морская'],
  'Greek': ['Οδός Ερμού', 'Θεσσαλονίκη'],
  'Armenian': ['Մաշտոցի', 'պողոտա', 'Երևան'],
  'Georgian': ['რუსთაველის', 'გამზირი', 'თბილისი'],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late GlyphSource glyphs;

  setUpAll(() async {
    await loadScriptFonts();
    // One font for every stack: the samples all ask for Noto Sans
    // Regular, and a range without a file fails as on a real server.
    glyphs = GlyphSource(
      load: (stack, start) async {
        final bytes = await glyphBytes('$start-${start + 255}.pbf');
        return bytes.buffer
            .asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
      },
      signature: 'script-suite',
    );
  });

  tearDownAll(() => glyphs.dispose());

  final glyphSamples = [
    for (final sample in scriptSamples)
      if (isGlyphShapeable(sample.name) && isGlyphShapeable(sample.wrapped))
        sample,
  ];
  final platformSamples = [
    for (final sample in scriptSamples)
      if (!glyphSamples.contains(sample)) sample,
  ];

  test('the glyph-drawn scripts are the ones the glyphs serve', () {
    expect(glyphSamples.map((s) => s.script), _maplibreLines.keys);
  });

  for (final sample in glyphSamples) {
    group('${sample.script}, from the glyphs', () {
      test('draws every grapheme from them', () async {
        final graphemes = {
          ...sample.name.characters,
          ...sample.wrapped.characters,
        }.where((g) => g.trim().isNotEmpty);
        for (final grapheme in graphemes) {
          final image = await drawLabel(grapheme, glyphs: glyphs);
          expect(lastGlyphShaped, 1, reason: '$grapheme not from the glyphs');
          expect(image.box(), isNotNull, reason: '$grapheme draws nothing');
        }
      });

      test('wraps at text-max-width where MapLibre does', () async {
        final wrapped = await drawLabel(sample.wrapped,
            layout: {'text-max-width': 5}, glyphs: glyphs);
        expect(lastGlyphShaped, 1);
        await _expectLines(wrapped, _maplibreLines[sample.script]!, glyphs);
      });

      test('keeps its halo around the letters and off them', () async {
        final plain = await drawLabel(sample.name, glyphs: glyphs);
        final haloed = await drawLabel(sample.name,
            paint: {'text-halo-color': '#ffffff', 'text-halo-width': 2},
            glyphs: glyphs);
        _expectHalo(plain, haloed);
      });

      if (sample.curves) {
        test('bends along a curved line, glyph by glyph', () async {
          final path = await arcFor(sample.name);
          final curved = await drawLabel(sample.name,
              path: path, size: curvedSize, glyphs: glyphs);
          expect(lastGlyphShaped, 1);
          final straight = await drawLabel(sample.name,
              at: path.pointAt(path.length / 2),
              size: curvedSize,
              glyphs: glyphs);
          expect(curved.placed, isTrue);
          expect(curved.endDrop() - straight.endDrop(), greaterThan(0.1 * em),
              reason: 'curved ${curved.endDrop()}, '
                  'straight ${straight.endDrop()}');
        });
      }

      test('reads like the same name drawn by the platform', () async {
        // Same font family, two renderers: the glyph path must not move
        // or misshape what the platform draws. Glyph PBF advances are
        // whole pixels at 24 px, so a long name drifts a few percent
        // from the font's own fractional advances — as in MapLibre.
        final fromGlyphs = await drawLabel(sample.name, glyphs: glyphs);
        final fromPlatform = await drawLabel(sample.name);
        _expectAlike(fromGlyphs, fromPlatform, sample.name);
      });
    });
  }

  for (final sample in platformSamples) {
    test('${sample.script} is drawn exactly as without glyphs', () async {
      Future<void> same(String text,
          {Map<String, Object?> layout = const {}, bool curved = false}) async {
        final path = curved ? await arcFor(text) : null;
        final size = curved ? curvedSize : const Size(400, 120);
        final without =
            await drawLabel(text, layout: layout, path: path, size: size);
        final withGlyphs = await drawLabel(text,
            layout: layout, path: path, size: size, glyphs: glyphs);
        expect(lastGlyphShaped, 0, reason: text);
        expect(withGlyphs.rgba, without.rgba, reason: text);
      }

      await same(sample.name);
      await same(sample.wrapped, layout: {'text-max-width': 5});
      await same(sample.name, curved: true);
    });
  }

  test('emoji, marks and mixed directions are drawn exactly as without',
      () async {
    for (final text in [
      emojiInLatin,
      emojiFamily,
      for (final (_, decomposed) in combiningPairs) decomposed,
      mixedRtlDigits,
      mixedRtlFirst,
      mixedLtrFirst,
    ]) {
      final without = await drawLabel(text);
      final withGlyphs = await drawLabel(text, glyphs: glyphs);
      expect(lastGlyphShaped, 0, reason: text);
      expect(withGlyphs.rgba, without.rgba, reason: text);
    }
  });

  test('a precomposed name from the glyphs reads like its decomposed form',
      () async {
    // The decomposed form keeps the platform path (combining marks);
    // the precomposed one is drawn from the glyphs. One name, two
    // renderers, one look.
    for (final (precomposed, decomposed) in combiningPairs) {
      final fromGlyphs = await drawLabel(precomposed, glyphs: glyphs);
      expect(lastGlyphShaped, 1, reason: precomposed);
      final fromPlatform = await drawLabel(decomposed, glyphs: glyphs);
      expect(lastGlyphShaped, 0, reason: decomposed);
      _expectAlike(fromGlyphs, fromPlatform, precomposed);
    }
  });
}

/// [a] and [b] draw the same text alike: as wide within 6 %, and most
/// of [a]'s ink on [b]'s within a few pixels. Most, not nearly all: the
/// advance drift adds up along a long name, which a single shift cannot
/// follow (78 % for "Ærø Øresund" in the browser, 86 % on the VM); a
/// letter missing or out of place costs far more than that.
void _expectAlike(LabelImage a, LabelImage b, String text) {
  final boxA = a.box()!, boxB = b.box()!;
  expect((boxA.width - boxB.width).abs() / boxB.width, lessThan(0.06),
      reason: '$text: ${boxA.width} px wide against ${boxB.width}');
  final (covered, _, _) = a.bestCoveredBy(b, range: 3);
  expect(covered, greaterThan(0.75),
      reason: '$text: ${(covered * 100).toStringAsFixed(1)}% on the other');
}

/// The halo checks of `script_rendering_test.dart`: a halo all round
/// the letters, at least 3 device pixels out, leaving the letters
/// themselves visible.
void _expectHalo(LabelImage plain, LabelImage haloed) {
  final fill = haloed.box(haloed.isFill)!;
  final halo = haloed.box(haloed.isHalo);
  expect(halo, isNotNull, reason: 'no halo drawn');
  expect(fill.left - halo!.left, greaterThanOrEqualTo(3));
  expect(halo.right - fill.right, greaterThanOrEqualTo(3));
  expect(fill.top - halo.top, greaterThanOrEqualTo(3));
  expect(halo.bottom - fill.bottom, greaterThanOrEqualTo(3));
  final kept = haloed.count(haloed.isFill) / plain.count();
  expect(kept, greaterThan(0.8),
      reason: 'a halo is drawn over the letters (${kept.toStringAsFixed(2)} '
          'of their ink left)');
}

/// [label] shows [lines] one under the other, centred, 1.2 em apart
/// (MapLibre's line height, which glyph-drawn text keeps): each line,
/// drawn alone, lands where its line belongs, and [label] draws nothing
/// besides.
Future<void> _expectLines(
    LabelImage label, List<String> lines, GlyphSource glyphs) async {
  const pitch = textSize * 1.2 * 2;
  var inkOfLines = 0;
  for (var k = 0; k < lines.length; k++) {
    final alone = await drawLabel(lines[k],
        layout: {'text-max-width': 30}, glyphs: glyphs);
    final dy = ((k - (lines.length - 1) / 2) * pitch).round();
    final (covered, _, _) = alone.bestCoveredBy(label, dy: dy, range: 2);
    expect(covered, greaterThan(0.95),
        reason: 'line ${k + 1} of $lines is not drawn where it belongs '
            '(${(covered * 100).toStringAsFixed(1)}% found)');
    inkOfLines += alone.count();
  }
  final ink = label.count();
  expect((ink - inkOfLines).abs() / ink, lessThan(0.05),
      reason: 'the label draws more or less than $lines');
}
