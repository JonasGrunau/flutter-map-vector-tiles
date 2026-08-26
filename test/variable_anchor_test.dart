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
  String text, {
  int layerIndex = 0,
}) =>
    PlacedSymbol(
      instance: SymbolInstance(
        layer: layer,
        layerIndex: layerIndex,
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

/// Paints one frame. Pass [painter] to keep the placement memory across
/// frames, the way the layer does — a throwaway painter remembers
/// nothing.
List<PlacedSymbol> _paint(
  SymbolThemeLayer layer,
  List<PlacedSymbol> symbols, {
  LabelPainter? painter,
}) {
  final own = painter ?? LabelPainter();
  final recorder = ui.PictureRecorder();
  final placed = own.paint(
    canvas: Canvas(recorder),
    screenSize: const Size(400, 400),
    styleZoom: 12,
    symbols: symbols,
  );
  recorder.endRecording().dispose();
  if (painter == null) own.dispose();
  return placed;
}

/// The anchor [painter] remembers for [symbol]'s label.
String? _anchorOf(LabelPainter painter, PlacedSymbol symbol) =>
    painter.debugPlacement
        .lookup(symbol.instance.continuityKey, symbol.screenAnchor)
        ?.anchor;

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

  test('a label keeps its anchor against a same-layer arrival', () {
    // The arrival sorts higher on screen y and historically shoved the
    // sitting label to its second anchor. Incumbency reverses that: a
    // label already on screen is tried first within its layer and keeps
    // its anchor; the arrival takes what is still free.
    final layer = _symbolLayer(variableAnchor: ['top', 'bottom']);
    final alpha = _symbolAt(layer, const Offset(200, 200), 'Alpha');
    final beta = _symbolAt(layer, const Offset(200, 190), 'Beta');
    final painter = LabelPainter();
    addTearDown(painter.dispose);

    expect(_paint(layer, [alpha], painter: painter), hasLength(1));
    expect(_anchorOf(painter, alpha), 'top', reason: 'the style order');

    _paint(layer, [beta, alpha], painter: painter);
    expect(_anchorOf(painter, alpha), 'top',
        reason: 'the incumbent keeps its anchor');
    expect(_anchorOf(painter, beta), 'bottom',
        reason: 'the arrival takes the anchor that is still free');
  });

  test('a label stays at the anchor it was placed at', () {
    // A *higher-layer* neighbour still outranks an incumbent — the
    // style hierarchy holds — and crowds the label off its first
    // choice. The anchor it lands on is then remembered: deciding cold
    // once the neighbour leaves would hop the label straight back, so
    // the anchor it is sitting at is tried ahead of the style's order.
    final layer = _symbolLayer(variableAnchor: ['top', 'bottom']);
    final alpha = _symbolAt(layer, const Offset(200, 200), 'Alpha');
    final beta =
        _symbolAt(layer, const Offset(200, 190), 'Beta', layerIndex: 1);
    final painter = LabelPainter();
    addTearDown(painter.dispose);

    expect(_paint(layer, [alpha], painter: painter), hasLength(1));
    expect(_anchorOf(painter, alpha), 'top', reason: 'the style order');

    _paint(layer, [beta, alpha], painter: painter);
    expect(_anchorOf(painter, alpha), 'bottom',
        reason: 'the higher layer sorts first and takes the top anchor');

    _paint(layer, [alpha], painter: painter);
    expect(_anchorOf(painter, alpha), 'bottom',
        reason: 'the neighbour is gone, but a label that already fits '
            'does not move');
  });

  test('a label that changes instance keeps its anchor', () {
    // A tile republish (provisional→final, a zoom level handing over)
    // replaces the instance under a label that never left the screen.
    // Deciding the anchor cold there sends it back to the style's first
    // choice — the label hops, instantly, with no fade to cover it.
    final layer = _symbolLayer(variableAnchor: ['top', 'bottom']);
    final alpha = _symbolAt(layer, const Offset(200, 200), 'Alpha');
    final beta = _symbolAt(layer, const Offset(200, 190), 'Beta');
    final painter = LabelPainter();
    addTearDown(painter.dispose);

    _paint(layer, [beta, alpha], painter: painter);
    expect(_anchorOf(painter, alpha), 'bottom');

    // Same label, one pixel over, from a freshly laid-out tile.
    final republished = _symbolAt(layer, const Offset(200, 201), 'Alpha');
    _paint(layer, [republished], painter: painter);
    expect(_anchorOf(painter, republished), 'bottom',
        reason: 'the arriving instance inherits where the label was sitting');
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
