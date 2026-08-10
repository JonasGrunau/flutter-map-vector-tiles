import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_map_vector_tiles/src/render/label_painter.dart';
import 'package:flutter_map_vector_tiles/src/render/symbol_layouter.dart';
import 'package:flutter_map_vector_tiles/src/style/theme.dart';
import 'package:flutter_map_vector_tiles/src/style/theme_reader.dart';
import 'package:flutter_test/flutter_test.dart';

SymbolThemeLayer _symbolLayer() {
  final theme = const ThemeReader().read({
    'layers': [
      {
        'id': 'poi',
        'type': 'symbol',
        'source': 's',
        'source-layer': 'poi',
        'layout': {
          'text-field': '{name}',
          'text-size': 14,
          // Every candidate lays out and draws, so the cache actually
          // cycles — collision rejections would hide the churn.
          'text-allow-overlap': true,
        },
      },
    ],
  });
  return theme.layers.single as SymbolThemeLayer;
}

PlacedSymbol _symbolAt(SymbolThemeLayer layer, Offset anchor, String text) =>
    PlacedSymbol(
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
      screenAnchor: anchor,
      screenAngle: 0,
    );

void _paintFrame(LabelPainter painter, List<PlacedSymbol> symbols) {
  final recorder = ui.PictureRecorder();
  painter.paint(
    canvas: Canvas(recorder),
    screenSize: const Size(400, 400),
    styleZoom: 12,
    symbols: symbols,
  );
  recorder.endRecording().dispose();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('cache eviction defers TextPainter disposal past the live frame', () {
    // Regression: the text/glyph caches leaked their TextPainters on
    // eviction and clear(). Disposal must also not be immediate — an
    // entry evicted mid-frame can still be referenced by a symbol
    // prepared earlier in the same frame, and drawing a disposed
    // painter throws in debug mode.
    final painter = LabelPainter();
    final layer = _symbolLayer();

    // Overflow the text cache by 100 distinct texts in one frame, so
    // ~100 evictions happen while the evicted painters are still queued
    // to draw. Anchors must stay inside the 400x400 screen (+150px
    // margin) or the off-screen cull skips layout and nothing evicts.
    const count = LabelPainter.textCacheEntries + 100;
    _paintFrame(painter, [
      for (var i = 0; i < count; i++)
        _symbolAt(layer, Offset((i % 40) * 10.0, ((i ~/ 40) % 40) * 10.0),
            'label $i'),
    ]);

    // The next frame disposes the retired painters and re-lays-out
    // evicted texts without touching disposed objects.
    _paintFrame(painter, [_symbolAt(layer, const Offset(50, 50), 'label 0')]);

    painter.dispose();
  });
}
