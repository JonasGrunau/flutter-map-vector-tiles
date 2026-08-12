import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_map_vector_tiles/src/render/label_painter.dart';
import 'package:flutter_map_vector_tiles/src/render/symbol_layouter.dart';
import 'package:flutter_map_vector_tiles/src/style/expression.dart';
import 'package:flutter_map_vector_tiles/src/style/theme.dart';
import 'package:flutter_map_vector_tiles/src/style/theme_reader.dart';
import 'package:flutter_test/flutter_test.dart';

SymbolThemeLayer _symbolLayer({List<String>? variableAnchor}) {
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
          if (variableAnchor != null) 'text-variable-anchor': variableAnchor,
          if (variableAnchor != null) 'text-radial-offset': 0.5,
        },
      },
    ],
  });
  return theme.layers.single as SymbolThemeLayer;
}

PlacedSymbol _symbolAt(
  SymbolThemeLayer layer,
  Offset screenAnchor,
  String text,
) =>
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
    );

List<PlacedSymbol> _paint(SymbolThemeLayer layer, List<PlacedSymbol> symbols) {
  final painter = LabelPainter();
  final recorder = ui.PictureRecorder();
  final placed = painter.paint(
    canvas: Canvas(recorder),
    screenSize: const Size(400, 400),
    styleZoom: 12,
    symbols: symbols,
  );
  recorder.endRecording().dispose();
  painter.dispose();
  return placed;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('theme reader parses text-variable-anchor and radial offset', () {
    final layer = _symbolLayer(variableAnchor: ['top', 'bottom']);
    const ctx = EvalContext(zoom: 12);
    expect(layer.textVariableAnchor!.eval(ctx), ['top', 'bottom']);
    expect(layer.textRadialOffset.eval(ctx), 0.5);
    expect(_symbolLayer().textVariableAnchor, null);
  });

  test('fixed anchor: second symbol at the same spot is dropped', () {
    final layer = _symbolLayer();
    final placed = _paint(layer, [
      _symbolAt(layer, const Offset(200, 200), 'Alpha'),
      _symbolAt(layer, const Offset(200, 200), 'Beta'),
    ]);
    expect(placed, hasLength(1));
  });

  test('variable anchors: both symbols find a spot', () {
    final layer =
        _symbolLayer(variableAnchor: ['top', 'bottom', 'left', 'right']);
    final placed = _paint(layer, [
      _symbolAt(layer, const Offset(200, 200), 'Alpha'),
      _symbolAt(layer, const Offset(200, 200), 'Beta'),
    ]);
    expect(placed, hasLength(2));
  });

  test('variable anchors exhausted: extra symbols are dropped', () {
    final layer = _symbolLayer(variableAnchor: ['top']);
    final placed = _paint(layer, [
      _symbolAt(layer, const Offset(200, 200), 'Alpha'),
      _symbolAt(layer, const Offset(200, 200), 'Beta'),
      _symbolAt(layer, const Offset(200, 200), 'Gamma'),
    ]);
    expect(placed, hasLength(1));
  });

  test('a label stays at the anchor it was placed at', () {
    // Anchors are tried in style order, so a neighbour that crowds a
    // label off its first choice for one pass would send it back the
    // moment it leaves — a label hopping around its own point. The
    // anchor it is sitting at is tried ahead of the style's order.
    final layer = _symbolLayer(variableAnchor: ['top', 'bottom']);
    final alpha = _symbolAt(layer, const Offset(200, 200), 'Alpha');
    final beta = _symbolAt(layer, const Offset(200, 190), 'Beta');

    expect(_paint(layer, [alpha]), hasLength(1));
    expect(alpha.instance.anchorMemo, 'top', reason: 'the style order');

    _paint(layer, [beta, alpha]);
    expect(alpha.instance.anchorMemo, 'bottom',
        reason: 'the neighbour sorts first and takes the top anchor');

    _paint(layer, [alpha]);
    expect(alpha.instance.anchorMemo, 'bottom',
        reason: 'the neighbour is gone, but a label that already fits '
            'does not move');
  });

  test('distant symbols are unaffected by variable anchors', () {
    final layer = _symbolLayer(variableAnchor: ['top', 'bottom']);
    final placed = _paint(layer, [
      _symbolAt(layer, const Offset(100, 100), 'Alpha'),
      _symbolAt(layer, const Offset(300, 300), 'Beta'),
    ]);
    expect(placed, hasLength(2));
  });
}
