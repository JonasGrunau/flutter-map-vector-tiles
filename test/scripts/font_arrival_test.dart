import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map_vector_tiles/src/render/label_painter.dart';
import 'package:flutter_map_vector_tiles/src/render/symbol_layouter.dart';
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
/// Chinese or Korean one, under a family name of its own, loaded only
/// after the label was first drawn.

var _generation = 0;

/// A size that follows the zoom, under a halo: the halo's share of the
/// size, part of the text's cache key, differs between the tile's zoom,
/// where the render pump shapes, and the camera's, where the label pass
/// looks the text up.
const _zoomedSize = {
  'text-size': [
    'interpolate',
    ['linear'],
    ['zoom'],
    10,
    10,
    14,
    20,
  ],
};
const _halo = {'text-halo-width': 2, 'text-halo-color': '#ffffff'};

/// [text] as one label, painted by [painter] — kept across drawings,
/// unlike `drawLabel`'s, so that what it cached is what it draws — at
/// [zoom], with `label`'s [layout] and [paint].
Future<LabelImage> _draw(
  LabelPainter painter,
  String text, {
  SymbolPath? path,
  double zoom = 12,
  Map<String, Object?> layout = const {},
  Map<String, Object?> paint = const {},
}) async {
  final size = path == null ? const Size(400, 120) : curvedSize;
  const devicePixelRatio = 2.0;
  final symbol = label(text, path: path, layout: layout, paint: paint);
  await painter.glyphsPending([symbol.instance], zoom);
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)..scale(devicePixelRatio);
  final placed = painter.paint(
    canvas: canvas,
    screenSize: size,
    styleZoom: zoom,
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

  // Chinese straight, as a paragraph; Korean along a curve, grapheme
  // by grapheme from the curved-text atlas.
  for (final (script, family, text, curved) in [
    ('Chinese', 'NotoSansSC', '北京市', false),
    ('curved Korean', 'NotoSansKR', '서울특별시', true),
  ]) {
    test(
        '$script drawn before its font arrived is drawn in it once the '
        'fonts change and the pump shapes it again', () async {
      final late = 'Late$family';
      // The arc is fitted to the label's width in its own font.
      final path = curved ? await arcFor(text) : null;
      LabelPainter.debugFontFamilies = [
        for (final f in scriptFonts) f == family ? late : f,
      ];
      final painter = LabelPainter();
      addTearDown(painter.dispose);

      final boxes = await _draw(painter, text, path: path);
      await (FontLoader(late)..addFont(fontBytes('$family.ttf'))).load();
      final fresh = LabelPainter();
      addTearDown(fresh.dispose);
      final drawn = await _draw(fresh, text, path: path);
      expect(boxes.placed && drawn.placed, isTrue);
      expect(boxes.looksLike(drawn), isFalse,
          reason: 'before its font, the label is .notdef boxes');

      // What the web showed for good: the shaped label is cached, and
      // nothing in it knows that a font has arrived.
      expect((await _draw(painter, text, path: path)).looksLike(boxes), isTrue);

      // Told, the painter still draws what it has: shaping every label
      // on screen in the frame after the fonts arrive would stall it.
      expect(painter.fontsChanged(), isTrue);
      expect((await _draw(painter, text, path: path)).looksLike(boxes), isTrue,
          reason: 'the frame does not shape again');

      // The render pump does, within its budget.
      painter.prewarm([label(text, path: path).instance], 12);
      expect((await _draw(painter, text, path: path)).looksLike(drawn), isTrue,
          reason: 'shaped again, in the font that arrived');
    });
  }

  test(
      'text the pump did not shape again for new fonts is shaped in them '
      'once dropped', () async {
    // Drawn at the camera's zoom, prewarmed at the tile's.
    const family = 'NotoSansSC', late = 'Dropped$family', text = '北京市';
    LabelPainter.debugFontFamilies = [
      for (final f in scriptFonts) f == family ? late : f,
    ];
    final painter = LabelPainter();
    addTearDown(painter.dispose);
    Future<LabelImage> draw(LabelPainter painter) =>
        _draw(painter, text, zoom: 12.5, layout: _zoomedSize, paint: _halo);

    final boxes = await draw(painter);
    await (FontLoader(late)..addFont(fontBytes('$family.ttf'))).load();
    final fresh = LabelPainter();
    addTearDown(fresh.dispose);
    final drawn = await draw(fresh);
    expect(boxes.looksLike(drawn), isFalse,
        reason: 'before its font, the label is .notdef boxes');

    expect(painter.fontsChanged(), isTrue);
    painter
        .prewarm([label(text, layout: _zoomedSize, paint: _halo).instance], 12);
    expect((await draw(painter)).looksLike(boxes), isTrue,
        reason: 'shaped again at the tile zoom only, so still boxes here');

    painter.discardOldFonts();
    expect((await draw(painter)).looksLike(drawn), isTrue,
        reason: 'dropped, and shaped afresh in the font that arrived');
  });

  test(
      'curved text shaped after the fonts changed draws none of its '
      'letters from the old fonts', () async {
    // 서울역 is drawn along a curve, letter by letter, before its font
    // arrives; the letters it shares with 서울특별시, shaped in a frame
    // after the font did, are in the cache under the same style.
    const family = 'NotoSansKR', late = 'Mixed$family';
    const early = '서울역', later = '서울특별시';
    final earlyPath = await arcFor(early);
    final laterPath = await arcFor(later);
    LabelPainter.debugFontFamilies = [
      for (final f in scriptFonts) f == family ? late : f,
    ];
    final painter = LabelPainter();
    addTearDown(painter.dispose);
    Future<LabelImage> draw(
            LabelPainter painter, String text, SymbolPath path) =>
        _draw(painter, text,
            path: path, zoom: 12.5, layout: _zoomedSize, paint: _halo);

    await draw(painter, early, earlyPath);
    await (FontLoader(late)..addFont(fontBytes('$family.ttf'))).load();
    final fresh = LabelPainter();
    addTearDown(fresh.dispose);
    final drawn = await draw(fresh, later, laterPath);

    expect(painter.fontsChanged(), isTrue);
    painter.prewarm([
      label(later, path: laterPath, layout: _zoomedSize, paint: _halo).instance,
    ], 12);
    final after = await draw(painter, later, laterPath);
    expect(after.placed && drawn.placed, isTrue);
    expect(after.looksLike(drawn), isTrue,
        reason: 'every letter in the font that arrived');
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
    painter.prewarm([label('თბილისი').instance, label('北京市').instance], 12);
    expect(painter.debugShapedTextCount, shaped + 1,
        reason: 'only the paragraph is shaped again');
    expect(painter.debugGlyphShapedTextCount, 1);
  });
}
