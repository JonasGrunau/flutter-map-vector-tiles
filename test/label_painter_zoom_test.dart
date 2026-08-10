import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_map_vector_tiles/src/render/label_painter.dart';
import 'package:flutter_map_vector_tiles/src/render/symbol_layouter.dart';
import 'package:flutter_map_vector_tiles/src/style/theme.dart';
import 'package:flutter_map_vector_tiles/src/style/theme_reader.dart';
import 'package:flutter_test/flutter_test.dart';

SymbolThemeLayer _symbolLayer({Object? textSize = 14, Object? textOpacity}) {
  final theme = const ThemeReader().read({
    'layers': [
      {
        'id': 'poi',
        'type': 'symbol',
        'source': 's',
        'source-layer': 'poi',
        'layout': {'text-field': '{name}', 'text-size': textSize},
        if (textOpacity != null) 'paint': {'text-opacity': textOpacity},
      },
    ],
  });
  return theme.layers.single as SymbolThemeLayer;
}

PlacedSymbol _symbol(SymbolThemeLayer layer, String text) => PlacedSymbol(
      instance: SymbolInstance(
        layer: layer,
        layerIndex: 0,
        anchor: Offset.zero,
        angle: 0,
        alongLine: false,
        text: text,
        iconName: null,
        sortKey: 0,
        properties: const {},
        geometryType: 'Point',
        featureId: null,
      ),
      screenAnchor: const Offset(200, 200),
      screenAngle: 0,
    );

void _paintFrame(
    LabelPainter painter, List<PlacedSymbol> symbols, double styleZoom) {
  final recorder = ui.PictureRecorder();
  painter.paint(
    canvas: Canvas(recorder),
    screenSize: const Size(400, 400),
    styleZoom: styleZoom,
    symbols: symbols,
  );
  recorder.endRecording().dispose();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the label eval zoom is quantized to 1/8-level steps', () {
    final painter = LabelPainter();
    final layer = _symbolLayer();
    final symbol = _symbol(layer, 'Marienplatz');

    _paintFrame(painter, [symbol], 16.07);
    // (16.07 * 8).round() / 8
    expect(symbol.instance.textStyleMemo!.zoom, 16.125);

    painter.dispose();
  });

  test(
      'the per-instance memo survives fractional-zoom frames within '
      'one step', () {
    final painter = LabelPainter();
    final layer = _symbolLayer();
    final symbol = _symbol(layer, 'Marienplatz');

    _paintFrame(painter, [symbol], 16.0);
    final memo = symbol.instance.textStyleMemo;
    expect(memo, isNotNull);
    final key = memo!.cacheKey;

    // Every zoom in [15.9375+ε, 16.0625) rounds to 16.0: the memo must
    // hold across all of them, exactly as during a pinch gesture.
    for (final z in [16.01, 16.02, 16.03, 16.04, 16.05, 16.06]) {
      _paintFrame(painter, [symbol], z);
      expect(identical(symbol.instance.textStyleMemo, memo), isTrue,
          reason: 'zoom $z must not rebuild the memo');
      expect(symbol.instance.textStyleMemo!.cacheKey, same(key));
      expect(symbol.instance.textStyleMemo!.zoom, 16.0);
    }

    painter.dispose();
  });

  test(
      'a text-size zoom ramp shapes once — the cache key contains no '
      'font size and the memo survives the whole pinch', () {
    final painter = LabelPainter();
    final layer = _symbolLayer(textSize: [
      'interpolate',
      ['linear'],
      ['zoom'],
      14, 12, //
      20, 24,
    ]);
    final symbol = _symbol(layer, 'Marienplatz');

    _paintFrame(painter, [symbol], 16.0);
    expect(painter.debugShapedTextCount, 1);
    final memo = symbol.instance.textStyleMemo;

    for (var z = 16.0; z < 18.0; z += 0.01) {
      _paintFrame(painter, [symbol], z);
    }
    // Text is shaped at a fixed reference size and drawn scaled: a pure
    // size ramp never re-shapes, never rotates the key.
    expect(painter.debugShapedTextCount, 1);
    expect(identical(symbol.instance.textStyleMemo, memo), isTrue);
    expect(painter.debugTextCacheLength, 1);

    painter.dispose();
  });

  test('a text-opacity ramp rotates the key a bounded number of times', () {
    final painter = LabelPainter();
    final layer = _symbolLayer(textOpacity: [
      'interpolate',
      ['linear'],
      ['zoom'],
      14, 0.2, //
      20, 1.0,
    ]);
    final symbol = _symbol(layer, 'Marienplatz');

    for (var z = 14.0; z < 20.0; z += 0.01) {
      _paintFrame(painter, [symbol], z);
    }
    // Opacity is quantized to 1/32 steps before entering the key: a
    // 0.2→1.0 ramp crosses at most ~26 steps over six zoom levels.
    expect(painter.debugShapedTextCount, lessThanOrEqualTo(27));
    expect(painter.debugShapedTextCount, greaterThan(1),
        reason: 'the ramp must actually change the opacity');

    painter.dispose();
  });

  test('collision boxes scale with the evaluated text size', () {
    // Two labels whose boxes overlap at text-size 28 but not at 14:
    // the second is suppressed only at the large size, proving the
    // reference-shaped text contributes scaled collision boxes.
    int drawnAt(Object? textSize) {
      final painter = LabelPainter();
      final layer = _symbolLayer(textSize: textSize);
      // Short names: neither wraps at the default text-max-width, so
      // the boxes are single-line and their height scales with size.
      final a = _symbol(layer, 'Isar');
      final b = PlacedSymbol(
        instance: _symbol(layer, 'Amper').instance,
        screenAnchor: const Offset(200, 228),
        screenAngle: 0,
      );
      final recorder = ui.PictureRecorder();
      final drawn = painter.paint(
        canvas: Canvas(recorder),
        screenSize: const Size(400, 400),
        styleZoom: 16,
        symbols: [a, b],
      );
      recorder.endRecording().dispose();
      painter.dispose();
      return drawn.length;
    }

    expect(drawnAt(14), 2);
    expect(drawnAt(28), 1);
  });

  test('prewarm shapes everything before the first paint', () {
    final painter = LabelPainter();
    final layer = _symbolLayer();
    final a = _symbol(layer, 'Marienplatz');
    final b = _symbol(layer, 'Odeonsplatz');

    painter.prewarm([a.instance, b.instance], 16.03);
    final shapedByPrewarm = painter.debugShapedTextCount;
    expect(shapedByPrewarm, 2);

    // The paint that follows (same eval zoom after quantization) finds
    // everything shaped.
    _paintFrame(painter, [a, b], 16.0);
    expect(painter.debugShapedTextCount, shapedByPrewarm);

    painter.dispose();
  });
}
