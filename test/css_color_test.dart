import 'package:flutter/painting.dart';
import 'package:flutter_map_vector_tiles/src/style/css_color.dart';
import 'package:flutter_test/flutter_test.dart';

/// Colour parsing sits under every paint property in a style, so a
/// regression here silently miscolours the entire map rather than
/// throwing. These cases are drawn from the formats real MapLibre
/// styles emit — MapTiler's dark styles, for instance, express all but
/// one of their 81 colour literals as `hsl()`/`hsla()`, in both spaced
/// and unspaced forms.
void main() {
  group('hex', () {
    test('parses #rgb, #rgba, #rrggbb and #rrggbbaa', () {
      expect(parseCssColor('#f00'), const Color(0xffff0000));
      expect(parseCssColor('#ff0000'), const Color(0xffff0000));
      // Short forms expand by digit duplication, not zero-padding.
      expect(parseCssColor('#abc'), const Color(0xffaabbcc));
      expect(parseCssColor('#0f08'), const Color(0x8800ff00));
      expect(parseCssColor('#0000ff80'), const Color(0x800000ff));
    });

    test('is case insensitive and tolerates surrounding space', () {
      expect(parseCssColor('#ABCDEF'), parseCssColor('#abcdef'));
      expect(parseCssColor('  #abcdef  '), const Color(0xffabcdef));
    });
  });

  group('rgb()/rgba()', () {
    test('parses integer channels and fractional alpha', () {
      expect(parseCssColor('rgb(255, 0, 0)'), const Color(0xffff0000));
      expect(parseCssColor('rgba(255, 255, 255, 1)'), const Color(0xffffffff));
      final half = parseCssColor('rgba(0, 0, 0, 0.5)')!;
      expect(half.a, closeTo(0.5, 0.01));
    });
  });

  group('hsl()/hsla()', () {
    test('achromatic values collapse to greys', () {
      expect(parseCssColor('hsl(0, 0%, 0%)'), const Color(0xff000000));
      expect(parseCssColor('hsl(0, 0%, 100%)'), const Color(0xffffffff));
      final grey = parseCssColor('hsl(0, 0%, 50%)')!;
      expect(grey.r, closeTo(0.5, 0.01));
      expect(grey.r, grey.g);
      expect(grey.g, grey.b);
    });

    test('primaries land on the right hue', () {
      expect(parseCssColor('hsl(0, 100%, 50%)'), const Color(0xffff0000));
      expect(parseCssColor('hsl(120, 100%, 50%)'), const Color(0xff00ff00));
      expect(parseCssColor('hsl(240, 100%, 50%)'), const Color(0xff0000ff));
    });

    test('whitespace between arguments is optional', () {
      // Real styles mix both spellings within one document.
      expect(parseCssColor('hsl(0,0%,21%)'), parseCssColor('hsl(0, 0%, 21%)'));
      expect(parseCssColor('hsl(208,100%,66%)'),
          parseCssColor('hsl(208, 100%, 66%)'));
    });

    test('hsla alpha is honoured', () {
      final translucent = parseCssColor('hsla(216, 95%, 9%, 0.75)')!;
      expect(translucent.a, closeTo(0.75, 0.01));
      // The RGB part matches the opaque form.
      final opaque = parseCssColor('hsl(216, 95%, 9%)')!;
      expect(translucent.r, closeTo(opaque.r, 0.001));
      expect(translucent.g, closeTo(opaque.g, 0.001));
      expect(translucent.b, closeTo(opaque.b, 0.001));
    });

    test('a representative style colour resolves to its known value', () {
      // The transit blue in MapTiler's dark style.
      expect(parseCssColor('hsl(208, 100%, 66%)'), const Color(0xff52aeff));
    });

    test('hue wraps rather than clamping', () {
      expect(parseCssColor('hsl(360, 100%, 50%)'),
          parseCssColor('hsl(0, 100%, 50%)'));
    });
  });

  group('unparseable input', () {
    test('returns null instead of throwing', () {
      // A style with a bad colour must degrade, not crash the map.
      for (final bad in [
        '',
        'not-a-color',
        '#',
        '#12345',
        'rgb()',
        'hsl(1, 2)',
      ]) {
        expect(parseCssColor(bad), isNull, reason: 'input: "$bad"');
      }
    });
  });
}
