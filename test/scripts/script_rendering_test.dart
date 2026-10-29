import 'package:characters/characters.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_map_vector_tiles/src/render/label_painter.dart';
import 'package:flutter_test/flutter_test.dart';

import 'script_harness.dart';
import 'script_samples.dart';

/// How labels in every script are drawn, asserted on the pixels the real
/// label painter produces with real fonts: what a reader of the script
/// would call drawn right — letters in reading order, joined where the
/// script joins them, vowel signs where they belong, marks on their
/// letters, lines broken only where the script allows — rather than how
/// the painter gets there. Any renderer that draws a script correctly
/// passes; `script_goldens_test.dart` pins the exact look on top.
///
/// Measurements are in device pixels at a pixel ratio of 2, so [em] is
/// one em of the 16 px text.
const em = textSize * 2;

/// A small canvas for one grapheme at a time.
const _glyphCanvas = Size(120, 80);
const _glyphAt = Offset(60, 40);

String _codes(String text) => text.runes
    .map((r) => 'U+${r.toRadixString(16).toUpperCase().padLeft(4, '0')}')
    .join(' ');

/// [LabelImage.coveredBy] both ways, for failure messages.
String _coverage(LabelImage a, LabelImage b) =>
    'covered ${(a.coveredBy(b) * 100).toStringAsFixed(1)}% / '
    '${(b.coveredBy(a) * 100).toStringAsFixed(1)}%';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadScriptFonts);

  group('every script', () {
    // What a character no font maps looks like: the `.notdef` box,
    // which is a different size in every font.
    final notdefs = <LabelImage>[];
    setUpAll(() async {
      for (final family in scriptFonts) {
        LabelPainter.debugFontFamilies = [family];
        notdefs
            .add(await drawLabel('\uE000', size: _glyphCanvas, at: _glyphAt));
      }
      LabelPainter.debugFontFamilies = scriptFonts;
    });

    for (final sample in scriptSamples) {
      group(sample.script, () {
        test('draws every grapheme as a glyph, none as a .notdef box',
            () async {
          final graphemes = {
            ...sample.name.characters,
            ...sample.wrapped.characters,
          }.where((g) => g.trim().isNotEmpty);
          for (final grapheme in graphemes) {
            final image =
                await drawLabel(grapheme, size: _glyphCanvas, at: _glyphAt);
            final ink = image.box();
            expect(ink, isNotNull, reason: '${_codes(grapheme)} draws nothing');
            for (var i = 0; i < notdefs.length; i++) {
              final box = notdefs[i].box()!;
              final sameSize = (box.width - ink!.width).abs() <= 2 &&
                  (box.height - ink.height).abs() <= 2;
              expect(sameSize && image.looksLike(notdefs[i]), isFalse,
                  reason: '${_codes(grapheme)} draws the .notdef box of '
                      '${scriptFonts[i]}');
            }
          }
        });

        test('wraps at text-max-width only where the script breaks lines',
            () async {
          final wrapped =
              await drawLabel(sample.wrapped, layout: {'text-max-width': 5});
          await _expectLines(wrapped, sample.lines);
        });

        test('keeps its halo around the letters and off them', () async {
          final plain = await drawLabel(sample.name);
          final haloed = await drawLabel(sample.name,
              paint: {'text-halo-color': '#ffffff', 'text-halo-width': 2});
          _expectHalo(plain, haloed);
        });

        if (sample.curves) {
          test('bends along a curved line, glyph by glyph', () async {
            final path = await arcFor(sample.name);
            final curved =
                await drawLabel(sample.name, path: path, size: curvedSize);
            final straight = await drawLabel(sample.name,
                at: path.pointAt(path.length / 2), size: curvedSize);
            expect(curved.placed, isTrue);
            // ignore: avoid_print
            print(
                'DROP ${sample.script} ${curved.endDrop() - straight.endDrop()}');
            // The arc drops away from its apex on both sides.
            expect(curved.endDrop() - straight.endDrop(), greaterThan(0.1 * em),
                reason: 'curved ${curved.endDrop()}, '
                    'straight ${straight.endDrop()}');
            final haloed = await drawLabel(sample.name,
                path: path,
                size: curvedSize,
                paint: {'text-halo-color': '#ffffff', 'text-halo-width': 2});
            _expectHalo(curved, haloed);
          });
        } else {
          test('is drawn straight where it meets a curved line', () async {
            // Shaped as a whole, then turned to the line's direction at
            // the anchor — which at the arc's apex is level.
            final path = await arcFor(sample.name);
            final curved =
                await drawLabel(sample.name, path: path, size: curvedSize);
            final straight = await drawLabel(sample.name,
                at: path.pointAt(path.length / 2), size: curvedSize);
            expect(curved.placed, isTrue);
            expect(curved.looksLike(straight), isTrue,
                reason: _coverage(curved, straight));
          });
        }
      });
    }
  });

  test(
      'a label with a word wider than text-max-width keeps every '
      'grapheme on its line', () async {
    // আন্তর্জাতিক is wider than 4 em, so the painter spells out the
    // breaks itself; হযরত শাহ wraps before শাহ. It used to send the code
    // units of a cluster that opens a line (শা) to the line before.
    const lines = ['হযরত', 'শাহ', 'আন্তর্জাতিক'];
    final label =
        await drawLabel(lines.join(' '), layout: {'text-max-width': 4});
    await _expectLines(label, lines);
  });

  group('right to left', () {
    for (final sample in scriptSamples.where((s) => s.rtl)) {
      test('${sample.script}: the first letter is the rightmost', () async {
        // With the label's left edge pinned, taking the first letter
        // away changes only the right end of the drawing.
        await _expectPartAt(
            sample.name, sample.name.characters.skip(1).toString(),
            anchor: 'left');
      });
    }

    test('Latin, the control: the first letter is the leftmost', () async {
      await _expectPartAt('Øresund', 'resund', anchor: 'right');
    });

    test('a number in an Arabic street name is drawn to its left', () async {
      await _expectPartAt(mixedRtlDigits, 'شارع', anchor: 'right');
    });

    test('a number in a Hebrew road name is drawn to its left', () async {
      await _expectPartAt(hebrewDigits, 'כביש', anchor: 'right');
    });

    test('an Arabic label holding Latin words reads from the right', () async {
      // The label is Arabic, so it starts on the right; before it was
      // laid out left to right, the Arabic word on the left.
      await _expectPartAt(mixedRtlFirst, 'شارع', anchor: 'right');
    });

    test('a Latin label holding Hebrew reads from the left', () async {
      await _expectPartAt(mixedLtrFirst, 'Rue 5', anchor: 'left');
    });

    test('each line takes its own direction', () async {
      // Liberty's labels put the Latin name over the local one. The
      // Arabic line, wider than the Latin one, ends at the box's right
      // edge: drawn alone in the same corner, it must land on itself.
      await _expectPartAt('Cairo\n$mixedRtlFirst', mixedRtlFirst,
          anchor: 'bottom-right', reaches: false);
    });

    test('a wrapped Arabic label reads from the right on every line', () async {
      // The second line starts with a Latin word, but belongs to an
      // Arabic paragraph: it reads from the right like the first.
      const text = 'شارع الملك Fahd الرياض';
      final wrapped = await drawLabel(text, layout: {'text-max-width': 6});
      final fromRight = await drawLabel('شارع الملك\n\u200fFahd الرياض',
          layout: {'text-max-width': 30});
      final fromLeft = await drawLabel('شارع الملك\nFahd الرياض',
          layout: {'text-max-width': 30});
      expect(wrapped.looksLike(fromRight), isTrue,
          reason: _coverage(wrapped, fromRight));
      expect(wrapped.looksLike(fromLeft), isFalse,
          reason: 'the control: a line of its own that starts with Latin '
              'reads from the left');
    });
  });

  group('shaping', () {
    test('Arabic letters join into one stroke', () async {
      final joined = await drawLabel(arabicJoined);
      final apart = await drawLabel(arabicIsolated);
      expect(joined.emptyColumns(), 0, reason: 'a gap between joined letters');
      expect(apart.emptyColumns(), greaterThan(2),
          reason: 'zero-width non-joiners keep the letters apart');
      // Joined forms are not the isolated ones drawn side by side.
      var isolatedWidth = 0;
      for (final letter in arabicJoined.characters) {
        isolatedWidth += (await drawLabel(letter)).box()!.width;
      }
      final width = joined.box()!.width;
      expect((width - isolatedWidth).abs(), greaterThan(0.15 * isolatedWidth),
          reason: 'joined $width, isolated forms $isolatedWidth');
    });

    test('lam and alef make one ligature', () async {
      final ligature = (await drawLabel('لا')).box()!;
      final lam = (await drawLabel('ل')).box()!;
      final alef = (await drawLabel('ا')).box()!;
      expect(ligature.width, lessThan(0.85 * (lam.width + alef.width)));
    });

    test('Arabic vowel marks sit over their letters', () async {
      final bare = await drawLabel(arabicBare);
      final vowelled = await drawLabel(arabicVowelled);
      expect(bare.coveredBy(vowelled), greaterThan(0.9),
          reason: 'the letters are the same');
      expect(bare.box()!.top - vowelled.box()!.top, greaterThan(0.1 * em),
          reason: 'the marks reach above the letters');
    });

    for (final (script, consonant, syllable) in preBaseVowels) {
      test(
          '$script: a vowel sign written after its consonant is drawn '
          'before it', () async {
        // The consonant's right edge is pinned: the sign must appear to
        // its left, the consonant staying where it was.
        await _expectPartAt(syllable, consonant, anchor: 'right');
      });
    }

    test('Devanagari: क्ष is one conjunct, narrower than its parts', () async {
      final conjunct = (await drawLabel('क्ष')).box()!;
      final halant = (await drawLabel('क्')).box()!;
      final ssa = (await drawLabel('ष')).box()!;
      expect(conjunct.width, lessThan(0.8 * (halant.width + ssa.width)));
    });

    for (final (script, letter, stack) in stackedMarks) {
      test('$script: $stack stacks over or under its letter', () async {
        final base = (await drawLabel(letter)).box()!;
        final stacked = (await drawLabel(stack)).box()!;
        expect(stacked.height, greaterThan(base.height + 0.1 * em));
        expect(stacked.width, lessThan(base.width + 0.3 * em),
            reason: 'stacked, not set beside it');
      });
    }
  });

  group('emoji', () {
    test('a ZWJ sequence draws as one glyph', () async {
      final family = (await drawLabel(emojiFamily)).box()!;
      final members = (await drawLabel(emojiFamilyUnjoined)).box()!;
      final man = (await drawLabel(emojiMan)).box()!;
      expect(family.width, lessThan(0.5 * members.width));
      expect(family.width, lessThan(2 * man.width));
    });

    test('a flag draws as one glyph', () async {
      // Unjoined, the two regional indicator letters are a box each:
      // the flag would start with the first one.
      const left = {'text-anchor': 'left'};
      final flag = await drawLabel(emojiFlag, layout: left);
      final letter = await drawLabel(emojiFlag.characters.first.substring(0, 2),
          layout: left);
      expect(letter.coveredBy(flag), lessThan(0.8),
          reason: _coverage(letter, flag));
    });

    test('a skin-tone modifier joins its emoji', () async {
      final toned = (await drawLabel(emojiThumbsSkinTone)).box()!;
      final plain = (await drawLabel(emojiThumbs)).box()!;
      expect(toned.width, lessThan(1.3 * plain.width));
    });

    test('an emoji draws inside Latin text', () async {
      final label = await drawLabel(emojiInLatin);
      final word = await drawLabel('Café', layout: {'text-anchor': 'left'});
      final both =
          await drawLabel(emojiInLatin, layout: {'text-anchor': 'left'});
      expect(label.placed, isTrue);
      expect(word.coveredBy(both), greaterThan(0.95));
      expect(both.box()!.right - word.box()!.right, greaterThan(0.8 * em));
    });
  });

  group('combining marks', () {
    for (final (precomposed, decomposed) in combiningPairs) {
      test('$precomposed spelled with combining marks draws the same',
          () async {
        final a = await drawLabel(precomposed);
        final b = await drawLabel(decomposed);
        expect(b.looksLike(a), isTrue, reason: _coverage(b, a));
      });

      test(
          '$precomposed with combining marks keeps every mark on its '
          'letter along a curved line', () async {
        final path = arcPath();
        final a = await drawLabel(precomposed, path: path, size: curvedSize);
        final b = await drawLabel(decomposed, path: path, size: curvedSize);
        expect(b.looksLike(a), isTrue, reason: _coverage(b, a));
      });
    }
  });
}

/// [part] of [text], drawn alone with its box pinned by the same
/// `text-anchor`, lands where it is in [text], and [text] reaches past
/// it on the other side.
Future<void> _expectPartAt(String text, String part,
    {required String anchor, bool reaches = true}) async {
  final layout = {'text-anchor': anchor, 'text-max-width': 30};
  final whole = await drawLabel(text, layout: layout);
  final alone = await drawLabel(part, layout: layout);
  expect(alone.coveredBy(whole), greaterThan(0.9),
      reason: '"$part" is not where it is drawn alone; '
          '${_coverage(alone, whole)}');
  if (!reaches) return;
  final reach = anchor.endsWith('right')
      ? alone.box()!.left - whole.box()!.left
      : whole.box()!.right - alone.box()!.right;
  expect(reach, greaterThan(0.2 * em),
      reason: 'the rest of "$text" is not beside "$part"');
}

/// The halo of [haloed] surrounds its letters by about the halo width
/// (2 px, 4 device pixels), and covers none of them: the letters keep
/// most of the ink [plain] gives them.
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

/// [label] shows [lines] one under the other, centred, as a label does:
/// each line, drawn alone, lands in [label] where its line belongs, in
/// order, and [label] draws nothing besides. Lines are found within a
/// few pixels of their place, because a line's height depends on the
/// fonts in it — a line ending in a space taken from the Latin font
/// stands a little taller than one that does not.
Future<void> _expectLines(LabelImage label, List<String> lines) async {
  const pitch = textSize * 1.2 * 2;
  var inkOfLines = 0;
  for (var k = 0; k < lines.length; k++) {
    final alone = await drawLabel(lines[k], layout: {'text-max-width': 30});
    final dy = ((k - (lines.length - 1) / 2) * pitch).round();
    final (covered, _, _) = alone.bestCoveredBy(label, dy: dy, range: 8);
    expect(covered, greaterThan(0.95),
        reason: 'line ${k + 1} of $lines is not drawn where it belongs '
            '(${(covered * 100).toStringAsFixed(1)}% found)');
    inkOfLines += alone.count();
  }
  final ink = label.count();
  expect((ink - inkOfLines).abs() / ink, lessThan(0.05),
      reason: 'the label draws more or less than $lines');
}
