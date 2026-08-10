import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_map_vector_tiles/src/render/label_painter.dart';
import 'package:flutter_map_vector_tiles/src/render/symbol_layouter.dart';
import 'package:flutter_map_vector_tiles/src/style/theme.dart';
import 'package:flutter_map_vector_tiles/src/style/theme_reader.dart';
import 'package:flutter_test/flutter_test.dart';

SymbolThemeLayer _symbolLayer({Object? textSize = 14}) {
  final theme = const ThemeReader().read({
    'layers': [
      {
        'id': 'poi',
        'type': 'symbol',
        'source': 's',
        'source-layer': 'poi',
        'layout': {'text-field': '{name}', 'text-size': textSize},
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
    expect(symbol.instance.textCacheZoom, 16.125);

    painter.dispose();
  });

  test(
      'the per-instance memo survives fractional-zoom frames within '
      'one step', () {
    final painter = LabelPainter();
    final layer = _symbolLayer();
    final symbol = _symbol(layer, 'Marienplatz');

    _paintFrame(painter, [symbol], 16.0);
    final key = symbol.instance.textCacheKey;
    final zoom = symbol.instance.textCacheZoom;
    expect(key, isNotNull);

    // Every zoom in [15.9375+ε, 16.0625) rounds to 16.0: the memo must
    // hold across all of them, exactly as during a pinch gesture.
    for (final z in [16.01, 16.02, 16.03, 16.04, 16.05, 16.06]) {
      _paintFrame(painter, [symbol], z);
      expect(symbol.instance.textCacheKey, key,
          reason: 'zoom $z must not rebuild the cache key');
      expect(symbol.instance.textCacheZoom, zoom);
    }

    painter.dispose();
  });

  test(
      'a text-size zoom ramp produces a bounded number of cache keys '
      'across a full-level pinch', () {
    final painter = LabelPainter();
    final layer = _symbolLayer(textSize: [
      'interpolate',
      ['linear'],
      ['zoom'],
      14, 12, //
      20, 24,
    ]);
    final symbol = _symbol(layer, 'Marienplatz');

    final keys = <String>{};
    for (var z = 16.0; z < 17.0; z += 0.01) {
      _paintFrame(painter, [symbol], z);
      keys.add(symbol.instance.textCacheKey!);
    }
    // 8 quantization steps per level -> at most 9 distinct keys, instead
    // of one per frame.
    expect(keys.length, lessThanOrEqualTo(9));
    expect(keys.length, greaterThan(1),
        reason: 'the ramp must actually change the size across the level');

    painter.dispose();
  });
}
