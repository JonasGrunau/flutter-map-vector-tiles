import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map_vector_tiles/src/render/label_painter.dart';
import 'package:flutter_map_vector_tiles/src/text/glyph_source.dart';
import 'package:flutter_test/flutter_test.dart';

import 'script_fonts_io.dart'
    if (dart.library.js_interop) 'script_fonts_web.dart';
import 'script_harness.dart';

/// A font that arrives after the labels it covers were shaped — on the
/// web, every font for a script outside Flutter's own: Chinese,
/// Japanese, Korean, Thai, Devanagari… Flutter lays such a label out at
/// once, in `.notdef` boxes, fetches a fallback font that covers it and
/// says so (`fontsChange`, which the layer hands to
/// [LabelPainter.fontsChanged]). Here the late font is the bundled
/// Chinese one, under a family name of its own, loaded only after the
/// label was first drawn.
const _late = 'LateNotoSansSC';

var _generation = 0;

/// [text] as one label, painted by [painter] — kept across drawings,
/// unlike `drawLabel`'s, so that what it cached is what it draws.
Future<LabelImage> _draw(LabelPainter painter, String text) async {
  const size = Size(400, 120);
  const devicePixelRatio = 2.0;
  final symbol = label(text);
  await painter.glyphsPending([symbol.instance], 12);
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)..scale(devicePixelRatio);
  final placed = painter.paint(
    canvas: canvas,
    screenSize: size,
    styleZoom: 12,
    symbols: [symbol],
    devicePixelRatio: devicePixelRatio,
    placementGeneration: _generation++,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage((size.width * devicePixelRatio).round(),
      (size.height * devicePixelRatio).round());
  picture.dispose();
  final bytes =
      await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
  image.dispose();
  return LabelImage(
    width: (size.width * devicePixelRatio).round(),
    height: (size.height * devicePixelRatio).round(),
    devicePixelRatio: devicePixelRatio,
    rgba: bytes!.buffer.asUint8List(),
    placed: placed.isNotEmpty,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadScriptFonts);
  tearDown(() => LabelPainter.debugFontFamilies = scriptFonts);

  test(
      'a label drawn before its font arrived is drawn in it once the '
      'fonts change', () async {
    LabelPainter.debugFontFamilies = [
      for (final family in scriptFonts) family == 'NotoSansSC' ? _late : family,
    ];
    final painter = LabelPainter();
    addTearDown(painter.dispose);
    const text = '北京市';

    final boxes = await _draw(painter, text);
    await (FontLoader(_late)..addFont(fontBytes('NotoSansSC.ttf'))).load();
    final fresh = LabelPainter();
    addTearDown(fresh.dispose);
    final drawn = await _draw(fresh, text);
    expect(boxes.placed && drawn.placed, isTrue);
    expect(boxes.looksLike(drawn), isFalse,
        reason: 'before its font, the label is .notdef boxes');

    // What the web showed for good: the shaped label is cached, and
    // nothing in it knows that a font has arrived.
    expect((await _draw(painter, text)).looksLike(boxes), isTrue);

    expect(painter.fontsChanged(), isTrue);
    expect((await _draw(painter, text)).looksLike(drawn), isTrue,
        reason: 'shaped again, in the font that arrived');
  });

  test('text drawn from the style glyphs is not shaped again', () async {
    final glyphs = GlyphSource(
      load: (stack, start) async {
        final bytes = await glyphBytes('$start-${start + 255}.pbf');
        return bytes.buffer
            .asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
      },
      signature: 'font-arrival',
    );
    addTearDown(glyphs.dispose);
    final painter = LabelPainter()..glyphs = glyphs;
    addTearDown(painter.dispose);

    // Georgian from the glyphs, Chinese from the platform.
    await _draw(painter, 'თბილისი');
    await _draw(painter, '北京市');
    expect(painter.debugGlyphShapedTextCount, 1);
    final shaped = painter.debugShapedTextCount;

    expect(painter.fontsChanged(), isTrue);
    await _draw(painter, 'თბილისი');
    await _draw(painter, '北京市');
    expect(painter.debugShapedTextCount, shaped + 1,
        reason: 'only the paragraph is shaped again');
    expect(painter.debugGlyphShapedTextCount, 1);
  });
}
