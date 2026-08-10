import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_map_vector_tiles/src/render/label_painter.dart';
import 'package:flutter_map_vector_tiles/src/render/symbol_layouter.dart';
import 'package:flutter_map_vector_tiles/src/style/theme.dart';
import 'package:flutter_map_vector_tiles/src/style/theme_reader.dart';
import 'package:flutter_test/flutter_test.dart';

SymbolThemeLayer _symbolLayer({
  double? minzoom,
  double? maxzoom,
  Object textSize = 14,
}) {
  final theme = const ThemeReader().read({
    'layers': [
      {
        'id': 'road-name',
        'type': 'symbol',
        'source': 's',
        'source-layer': 'road',
        if (minzoom != null) 'minzoom': minzoom,
        if (maxzoom != null) 'maxzoom': maxzoom,
        'layout': {
          'text-field': '{name}',
          'text-size': textSize,
        },
      },
    ],
  });
  return theme.layers.single as SymbolThemeLayer;
}

PlacedSymbol _symbolAt(
  SymbolThemeLayer layer,
  Offset screenAnchor,
  String text, {
  int order = 0,
}) =>
    PlacedSymbol(
      instance: SymbolInstance(
        layer: layer,
        layerIndex: 0,
        anchor: Offset.zero, // tile-space anchor unused by the painter
        angle: 0,
        alongLine: false,
        text: text,
        iconName: null,
        sortKey: 0,
        properties: const {},
        geometryType: 'Point',
        featureId: null,
      ),
      screenAnchor: screenAnchor,
      screenAngle: 0,
      order: order,
    );

List<PlacedSymbol> _paint(
  SymbolThemeLayer layer,
  List<PlacedSymbol> symbols, {
  double styleZoom = 12,
}) {
  final painter = LabelPainter();
  final recorder = ui.PictureRecorder();
  final placed = painter.paint(
    canvas: Canvas(recorder),
    screenSize: const Size(400, 400),
    styleZoom: styleZoom,
    symbols: symbols,
  );
  recorder.endRecording().dispose();
  painter.dispose();
  return placed;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('per-frame layer zoom range', () {
    // Symbols are laid out once per integer band, but the layer's
    // minzoom/maxzoom is continuous: the painter must gate each frame
    // at the fractional style zoom, or labels from the previous level
    // linger below their threshold during zoom transitions.
    test('a symbol paints only inside [minzoom, maxzoom)', () {
      final layer = _symbolLayer(minzoom: 14, maxzoom: 16);
      List<PlacedSymbol> paintAt(double styleZoom) => _paint(
            layer,
            [_symbolAt(layer, const Offset(200, 200), 'Main St')],
            styleZoom: styleZoom,
          );
      expect(paintAt(14.0), hasLength(1), reason: 'minzoom is inclusive');
      expect(paintAt(14.5), hasLength(1));
      expect(paintAt(13.9), isEmpty, reason: 'below minzoom');
      expect(paintAt(16.0), isEmpty, reason: 'maxzoom is exclusive');
    });
  });

  group('near-zero text-size', () {
    test('text shrunk away by a zoom ramp is not drawn', () {
      final layer = _symbolLayer(
        textSize: [
          'interpolate',
          ['linear'],
          ['zoom'],
          10,
          0,
          14,
          12,
        ],
      );
      List<PlacedSymbol> paintAt(double styleZoom) => _paint(
            layer,
            [_symbolAt(layer, const Offset(200, 200), 'Main St')],
            styleZoom: styleZoom,
          );
      // ~0.75px at zoom 10.2: skipped instead of inflated to a visible
      // floor that would also flood the collision grid with tiny boxes.
      expect(paintAt(10.2), isEmpty);
      expect(paintAt(14), hasLength(1));
    });

    test('small but visible text renders at its true size', () {
      final layer = _symbolLayer(textSize: 2);
      final placed =
          _paint(layer, [_symbolAt(layer, const Offset(200, 200), 'Main St')]);
      expect(placed, hasLength(1));
    });
  });

  group('collision tiebreak', () {
    test('lowest insertion order wins an exact tie, on every frame', () {
      final layer = _symbolLayer();
      List<PlacedSymbol> frame() => [
            for (var i = 39; i >= 0; i--)
              _symbolAt(layer, const Offset(200, 200), 'Main St', order: i),
          ];
      // Passed in reverse insertion order: the sort alone (layer, sort
      // key and y all tie) must still let order 0 — the current level
      // in production — win the spot, and keep winning across frames.
      final first = _paint(layer, frame());
      expect(first, hasLength(1));
      expect(first.single.order, 0);
      final second = _paint(layer, frame());
      expect(second.single.order, 0);
    });
  });
}
