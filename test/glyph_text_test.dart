import 'dart:typed_data';

import 'package:flutter_map_vector_tiles/src/text/glyph_pbf.dart';
import 'package:flutter_map_vector_tiles/src/text/glyph_script.dart';
import 'package:flutter_map_vector_tiles/src/text/glyph_shaper.dart';
import 'package:flutter_map_vector_tiles/src/text/glyph_source.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/glyph_pbf_builder.dart';

/// The pure-Dart half of the glyph text path: decoding glyph PBFs,
/// deciding which text they can draw, and laying it out the way
/// MapLibre does.
void main() {
  group('decodeGlyphPbf', () {
    test('reads every glyph field, negative offsets included', () {
      final glyphs =
          decodeGlyphPbf(GlyphPbfBuilder().stack('Test Regular', '0-255', [
        TestGlyph(0x48, width: 13, height: 17, left: 2, top: -9, advance: 17),
        TestGlyph(0x67, width: 12, height: 19, left: -1, top: -13),
        TestGlyph(0x20, width: 0, height: 0, top: -26, advance: 6, blank: true),
      ]).build());
      final h = glyphs[0x48]!;
      expect(
          (h.width, h.height, h.left, h.top, h.advance), (13, 17, 2, -9, 17));
      expect(h.bitmap!.length, h.bitmapWidth * h.bitmapHeight);
      expect((h.bitmapWidth, h.bitmapHeight), (19, 23));
      expect(h.hasBitmap, isTrue);
      expect(glyphs[0x67]!.left, -1);
      expect(glyphs[0x67]!.top, -13);
      final space = glyphs[0x20]!;
      expect(space.hasBitmap, isFalse);
      expect(space.advance, 6);
    });

    test('skips unknown fields, length-delimited ones included', () {
      // Regression: skipping a length-delimited field added its length
      // to the position from before the length's own bytes, so every
      // real glyph server's file — whose stack name is skipped — was
      // read misaligned and failed.
      final glyphs = decodeGlyphPbf(GlyphPbfBuilder().stack(
        'Test Regular, Test Fallback Regular',
        '256-511',
        [TestGlyph(0x100), TestGlyph(0x101)],
        extraFields: [
          (4, 26),
          (5, List.filled(200, 7)),
        ],
      ).build());
      expect(glyphs.keys, unorderedEquals([0x100, 0x101]));
    });

    test('a second stack only fills gaps', () {
      final glyphs = decodeGlyphPbf(GlyphPbfBuilder().stack(
          'A', '0-255', [TestGlyph(0x41, advance: 10)]).stack('B', '0-255', [
        TestGlyph(0x41, advance: 20),
        TestGlyph(0x42, advance: 30)
      ]).build());
      expect(glyphs[0x41]!.advance, 10);
      expect(glyphs[0x42]!.advance, 30);
    });

    test('rejects a truncated file', () {
      final bytes =
          GlyphPbfBuilder().stack('A', '0-255', [TestGlyph(0x41)]).build();
      expect(() => decodeGlyphPbf(bytes.sublist(0, bytes.length - 20)),
          throwsFormatException);
    });
  });

  group('isGlyphShapeable', () {
    // The scripts of the script test suite, by the path they take.
    const glyphs = {
      'Latin with diacritics': ['Đà Nẵng', 'Ærø', 'Øresund', 'Śląsk'],
      'Latin and punctuation': ['München (Süd)', 'St. Paul’s – Nord', '12/14'],
      'Cyrillic': ['Москва', 'Невский проспект'],
      'Greek': ['Αθήνα', 'Θεσσαλονίκη'],
      'Armenian': ['Երևան'],
      'Georgian': ['თბილისი'],
      'explicit line break': ['Altes\nRathaus'],
    };
    const paragraphs = {
      'Arabic': ['القاهرة', 'شارع الملك فهد'],
      'Persian and Urdu': ['تهران', 'لاہور'],
      'Hebrew': ['תל אביב'],
      'mixed RTL with digits or Latin': ['شارع 12', 'Rue 5 ‎תל‎'],
      'Devanagari': ['मुंबई', 'क्षत्रिय'],
      'Bengali': ['ঢাকা'],
      'Tamil': ['சென்னை'],
      'Thai': ['กรุงเทพมหานคร'],
      'Lao': ['ວຽງຈັນ'],
      'Khmer': ['ភ្នំពេញ'],
      'Myanmar': ['ရန်ကုန်'],
      'Sinhala': ['කොළඹ'],
      'Tibetan': ['ལྷ་ས'],
      'CJK': ['東京', '北京市'],
      'Japanese with kana': ['しんじゅく駅', 'トウキョウ'],
      'Korean': ['서울특별시'],
      'emoji and ZWJ sequences': ['Café ☕', '👨‍👩‍👧', 'Bar 🍺'],
      'combining marks': ['Đà Nẵng', 'é'],
      'variation selector': ['Ⓜ️'],
    };

    for (final MapEntry(key: script, value: texts) in glyphs.entries) {
      test('draws $script from glyphs', () {
        for (final text in texts) {
          expect(isGlyphShapeable(text), isTrue, reason: text);
        }
      });
    }
    for (final MapEntry(key: script, value: texts) in paragraphs.entries) {
      test('leaves $script to the platform', () {
        for (final text in texts) {
          expect(isGlyphShapeable(text), isFalse, reason: text);
        }
      });
    }

    test('any one complex character sends the whole label to the platform', () {
      expect(isGlyphShapeable('Berlin Hbf'), isTrue);
      expect(isGlyphShapeable('Berlin Hbf ب'), isFalse);
      expect(isGlyphShapeable('Berlin\t'), isFalse);
    });
  });

  group('shapeGlyphs', () {
    // Every letter 10 px wide, advancing 12; a space advances 6.
    final font = {
      for (final c in 'abcdefghijklmnopqrstuvwxyzABC-()'.codeUnits)
        c: SdfGlyph(
            id: c,
            width: 10,
            height: 14,
            left: 1,
            top: -10,
            advance: 12,
            bitmap: Uint8List.fromList(boxField(10, 14))),
      0x20: SdfGlyph(
          id: 0x20,
          width: 0,
          height: 0,
          left: 0,
          top: 0,
          advance: 6,
          bitmap: null),
    };
    ShapedGlyphs? shape(String text,
            {double letterSpacingEm = 0, double? maxWidthEm}) =>
        shapeGlyphs(text, (c) => font[c],
            letterSpacingEm: letterSpacingEm, maxWidthEm: maxWidthEm);

    List<String> lines(ShapedGlyphs shaped) {
      final byLine = <double, StringBuffer>{};
      for (var i = 0; i < shaped.glyphs.length; i++) {
        (byLine[shaped.positions[i * 2 + 1]] ??= StringBuffer())
            .writeCharCode(shaped.glyphs[i].id);
      }
      return [for (final line in byLine.values) line.toString()];
    }

    test('advances glyph by glyph; spaces only move the pen', () {
      final shaped = shape('ab c')!;
      expect(shaped.glyphs.map((g) => g.id), 'abc'.codeUnits);
      expect(_rounded(shaped.positions), [0, 14.4, 12, 14.4, 30, 14.4]);
      expect(shaped.width, 42); // 12 + 12 + 6 + 12
      expect(shaped.height, closeTo(28.8, 1e-9)); // one 1.2 em line
      expect(shaped.lineCount, 1);
    });

    test('letter spacing goes between glyphs, not after the last', () {
      // 0.25 em = 6 px after every glyph but the last.
      final shaped = shape('abc', letterSpacingEm: 0.25)!;
      expect(_rounded(shaped.positions), [0, 14.4, 18, 14.4, 36, 14.4]);
      expect(shaped.width, 48);
    });

    test('a missing glyph means the text is not drawn from glyphs', () {
      expect(shape('abé'), isNull);
    });

    test('a zero-width space draws nothing and takes no room', () {
      expect(shapeGlyphs('ab​c', (c) => font[c])!.width, 36);
    });

    test('lines are centred on the widest and 1.2 em apart', () {
      final shaped = shape('abcd\nab')!;
      expect(lines(shaped), ['abcd', 'ab']);
      // "ab" (24 px) centred in "abcd" (48 px).
      expect(shaped.positions[8], 12);
      expect(shaped.positions[9], closeTo(43.2, 1e-4));
      expect(shaped.height, closeTo(57.6, 1e-9));
    });

    test('text-justify aligns the lines to either side', () {
      // "ab" (24 px) in "abcd" (48 px): its first glyph at 0, 12 or 24.
      double secondLine(double justify) =>
          shapeGlyphs('abcd\nab', (c) => font[c], justify: justify)!
              .positions[8];
      expect([secondLine(0), secondLine(0.5), secondLine(1)], [0, 12, 24]);
    });

    test('justified realigns shaped text as shaping it so would', () {
      final centred = shape('abcd\nab')!;
      for (final justify in const [0.0, 1.0]) {
        final shaped =
            shapeGlyphs('abcd\nab', (c) => font[c], justify: justify)!;
        final realigned = centred.justified(justify);
        expect(realigned.positions, shaped.positions);
        expect(realigned.justify, justify);
      }
      final single = shape('abc')!;
      expect(single.justified(0), same(single));
    });

    test('text-line-height sets the line pitch and the block height', () {
      // 2 em lines: middles 24 and 72 px down, a 96 px block.
      final shaped = shapeGlyphs('abcd\nab', (c) => font[c], lineHeightEm: 2)!;
      expect(shaped.positions[1], 24);
      expect(shaped.positions[9], 72);
      expect(shaped.height, 96);
    });

    test('no wrapping without a width, or when the text fits', () {
      expect(lines(shape('aaa bbb ccc')!), ['aaabbbccc']);
      expect(lines(shape('aaa bbb ccc', maxWidthEm: 10)!), ['aaabbbccc']);
    });

    test('balanced: lines come out alike, not greedily filled', () {
      // 'aaaa bbbb cccc dd': 48 + 6 + 48 + 6 + 48 + 6 + 24 = 186 px. At
      // 6 em (144 px) a greedy wrap gives "aaaa bbbb" + "cccc dd"
      // already, so take 7 em (168 px): greedy fills the first line with
      // three words (150 px) and leaves "dd" dangling; balanced aims for
      // two lines of ~93 px.
      expect(lines(shape('aaaa bbbb cccc dd', maxWidthEm: 7)!),
          ['aaaabbbb', 'ccccdd']);
    });

    test('prefers a shorter last line to a longer one', () {
      // 120 px at 4 em (96 px): two lines, aiming at 60 px each. "aaa
      // bbb" + "ccc" (78 + 36) and "aaa" + "bbb ccc" (36 + 78) are
      // equally ragged; the one whose last line is the short one wins.
      expect(lines(shape('aaa bbb ccc', maxWidthEm: 4)!), ['aaabbb', 'ccc']);
    });

    test('judges a line by its letters, not its spaces', () {
      // 132 px with spaces at 5 em (120 px): two lines of ~66. Counted
      // with its space, "bbbbb cc" (90) would lose to three lines; as
      // MapLibre measures it, without (84), it wins.
      expect(lines(shape('aaa bbbbb cc', maxWidthEm: 5)!), ['aaa', 'bbbbbcc']);
    });

    test('a line break always breaks, the rest balanced around it', () {
      expect(
          lines(shape('aaaa bbbb\ncc', maxWidthEm: 10)!), ['aaaabbbb', 'cc']);
      // Along a line there is no wrapping, but a line break still is one.
      expect(lines(shape('aaaa bbbb\ncc')!), ['aaaabbbb', 'cc']);
    });

    test('avoids leaving an opening parenthesis at the end of a line', () {
      // After "(" both lines would be 96 px, a near-perfect balance; the
      // parenthesis penalty sends the break to the space before it.
      expect(lines(shape('aaaaaaa (bbbbbbb)', maxWidthEm: 5)!),
          ['aaaaaaa', '(bbbbbbb)']);
    });

    test('a word wider than the limit stays whole', () {
      expect(lines(shape('abcdefghijklmnop qr', maxWidthEm: 2)!),
          ['abcdefghijklmnop', 'qr']);
    });

    test('breaks after a hyphen, keeping it on the first line', () {
      expect(lines(shape('aaaaaaa-bbbbbbb', maxWidthEm: 5)!),
          ['aaaaaaa-', 'bbbbbbb']);
    });

    test('the bitmap sits on the middle of its line per MapLibre', () {
      // A glyph's bitmap top is 17 px above the line middle, less its
      // `top`: with top -10, 7 px above — so for a one-line label the
      // baseline of a font with a 26 px reference line lands 9 px below
      // the middle, centring capitals on the anchor.
      expect(glyphLineMiddleToReference, 17);
      expect(glyphLineHeightEm * glyphPbfEm, closeTo(28.8, 1e-9));
    });
  });

  group('GlyphSource.glyphRangeUrl', () {
    test('encodes the stack but keeps its commas', () {
      expect(
          GlyphSource.glyphRangeUrl(
              'https://x/fonts/{fontstack}/{range}.pbf?key=k',
              'Noto Sans Regular,Arial Unicode MS Regular',
              256),
          'https://x/fonts/Noto%20Sans%20Regular,Arial%20Unicode%20MS%20Regular'
          '/256-511.pbf?key=k');
    });
  });
}

/// [values] to four decimals: positions are `Float32List`s.
List<double> _rounded(List<double> values) =>
    [for (final v in values) (v * 1e4).round() / 1e4];
