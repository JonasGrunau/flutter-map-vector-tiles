import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_map_vector_tiles/src/render/label_painter.dart';
import 'package:flutter_map_vector_tiles/src/render/symbol_layouter.dart';
import 'package:flutter_map_vector_tiles/src/style/theme.dart';
import 'package:flutter_map_vector_tiles/src/style/theme_reader.dart';
import 'package:flutter_test/flutter_test.dart';

const _screenSize = Size(180, 100);

Theme _theme({
  String placement = 'line',
  Object textOpacity = 1,
  double minzoom = 0,
  bool twoLayers = false,
}) =>
    const ThemeReader().read({
      'layers': [
        {
          'id': 'lower',
          'type': 'symbol',
          'source': 's',
          'source-layer': 'transportation_name',
          'layout': {
            'symbol-placement': placement,
            'symbol-spacing': 100,
            'text-field': '{name}',
            'text-size': 10,
          },
          'paint': {'text-opacity': textOpacity},
        },
        if (twoLayers)
          {
            'id': 'upper',
            'type': 'symbol',
            'source': 's',
            'source-layer': 'transportation_name',
            'minzoom': minzoom,
            'layout': {
              'symbol-placement': placement,
              'symbol-spacing': 100,
              'text-field': '{name}',
              'text-size': 10,
            },
            'paint': {'text-opacity': textOpacity},
          },
      ],
    });

PlacedSymbol _symbol(
  SymbolThemeLayer layer,
  int layerIndex,
  Offset anchor, {
  String text = 'A',
  double opacity = 1,
  double angle = 0,
  SymbolPath? path,
  bool retained = false,
}) =>
    PlacedSymbol(
      instance: SymbolInstance(
        layer: layer,
        layerIndex: layerIndex,
        anchor: Offset.zero,
        angle: angle,
        alongLine: layer.placement.fallback != 'point',
        path: path,
        text: text,
        iconName: null,
        sortKey: 0,
        properties: {'opacity': opacity},
        geometryType: 'LineString',
        featureId: null,
      ),
      screenAnchor: anchor,
      screenAngle: angle,
      retained: retained,
    );

/// A straight 100 px path; only its identity matters to these tests.
SymbolPath _path() => SymbolPath(
      Float32List.fromList([0, 0, 100, 0]),
      Float32List.fromList([0, 100]),
    );

List<PlacedSymbol> _paint(
  List<PlacedSymbol> symbols, {
  double styleZoom = 5,
}) {
  final painter = LabelPainter();
  final recorder = ui.PictureRecorder();
  final drawn = painter.paint(
    canvas: Canvas(recorder),
    screenSize: _screenSize,
    styleZoom: styleZoom,
    symbols: symbols,
    placementGeneration: 0,
  );
  recorder.endRecording().dispose();
  painter.dispose();
  return drawn;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('nearby repeated line text is placed once', () {
    final layer = _theme().layers.single as SymbolThemeLayer;
    final drawn = _paint([
      _symbol(layer, 0, const Offset(50, 50)),
      _symbol(layer, 0, const Offset(90, 50)),
    ]);
    expect(drawn, hasLength(1));
  });

  test('anchors beside each other are different roads and both stay', () {
    // Two carriageways of one motorway, a street's neighbouring
    // switchbacks, parallel same-named roads: the displacement between
    // the anchors runs *across* the line direction, not along it.
    final layer = _theme().layers.single as SymbolThemeLayer;
    final drawn = _paint([
      _symbol(layer, 0, const Offset(50, 40)),
      _symbol(layer, 0, const Offset(50, 80)),
    ]);
    expect(drawn, hasLength(2));
  });

  test(
      'a candidate along the visible label\'s line is suppressed even '
      'when its own line bends away', () {
    final layer = _theme().layers.single as SymbolThemeLayer;
    final drawn = _paint([
      _symbol(layer, 0, const Offset(50, 50)),
      _symbol(layer, 0, const Offset(90, 50), angle: 1.2),
    ]);
    expect(drawn, hasLength(1));
  });

  test('anchors of one feature never suppress each other', () {
    // The layouter spaced them along the path already; a hairpin can
    // bring two of them within symbol-spacing / 2 as the crow flies.
    final layer = _theme().layers.single as SymbolThemeLayer;
    final path = _path();
    final drawn = _paint([
      _symbol(layer, 0, const Offset(50, 50), path: path),
      _symbol(layer, 0, const Offset(90, 50), path: path),
    ]);
    expect(drawn, hasLength(2));
  });

  test('a retained-level candidate neither suppresses nor is suppressed', () {
    final layer = _theme().layers.single as SymbolThemeLayer;
    expect(
      _paint([
        _symbol(layer, 0, const Offset(50, 50), retained: true),
        _symbol(layer, 0, const Offset(90, 50)),
      ]),
      hasLength(2),
    );
    expect(
      _paint([
        _symbol(layer, 0, const Offset(50, 50)),
        _symbol(layer, 0, const Offset(90, 50), retained: true),
      ]),
      hasLength(2),
    );
  });

  for (final placement in ['point', 'line-center']) {
    test('$placement does not use symbol-spacing for repeat suppression', () {
      final layer =
          _theme(placement: placement).layers.single as SymbolThemeLayer;
      final drawn = _paint([
        _symbol(layer, 0, const Offset(50, 50)),
        _symbol(layer, 0, const Offset(90, 50)),
      ]);
      expect(drawn, hasLength(2));
    });
  }

  test('topmost visible layer owns a repeated line label', () {
    final layers = _theme(twoLayers: true).layers.cast<SymbolThemeLayer>();
    final drawn = _paint([
      _symbol(layers[0], 0, const Offset(50, 50)),
      _symbol(layers[1], 1, const Offset(90, 50)),
    ]);
    expect(drawn, hasLength(1));
    expect(drawn.single.instance.layer.id, 'upper');
  });

  test('an opacity-zero candidate does not suppress a visible fallback', () {
    final layer = _theme(
      textOpacity: const ['get', 'opacity'],
    ).layers.single as SymbolThemeLayer;
    final drawn = _paint([
      _symbol(layer, 0, const Offset(50, 50), opacity: 0),
      _symbol(layer, 0, const Offset(90, 50)),
    ]);
    expect(drawn, hasLength(1));
    expect(drawn.single.screenAnchor, const Offset(90, 50));
  });

  test('an exact-zoom-gated upper layer does not suppress the lower layer', () {
    final layers =
        _theme(twoLayers: true, minzoom: 5.5).layers.cast<SymbolThemeLayer>();
    final drawn = _paint([
      _symbol(layers[0], 0, const Offset(50, 50)),
      _symbol(layers[1], 1, const Offset(90, 50)),
    ], styleZoom: 5.25);
    expect(drawn, hasLength(1));
    expect(drawn.single.instance.layer.id, 'lower');
  });
}
