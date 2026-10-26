import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_map_vector_tiles/src/render/label_painter.dart';
import 'package:flutter_map_vector_tiles/src/render/symbol_layouter.dart';
import 'package:flutter_map_vector_tiles/src/style/theme.dart';
import 'package:flutter_map_vector_tiles/src/style/theme_reader.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/label_ids.dart';

/// `text-max-width` wrapping, observed through the collision box: a
/// label's box is as tall as its lines, so whether a second label just
/// below it fits tells how many lines the first one took.

var _nextPlacementGeneration = 0;

SymbolThemeLayer _layer(double maxWidthEm) {
  final theme = const ThemeReader().read({
    'layers': [
      {
        'id': 'place',
        'type': 'symbol',
        'source': 's',
        'source-layer': 'place',
        'layout': {
          'text-field': '{name}',
          'text-size': 14,
          'text-max-width': maxWidthEm,
        },
      },
    ],
  });
  return theme.layers.single as SymbolThemeLayer;
}

PlacedSymbol _symbol(SymbolThemeLayer layer, String text, Offset at) =>
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
      id: labelIdOf((text, at)),
      screenAnchor: at,
      screenAngle: 0,
    );

/// How many of [above] and a one-letter label 24 px below it are drawn:
/// 2 when [above] is a single line (14 px tall at text-size 14), 1 when
/// it wraps onto more and reaches down into the second one's box.
int _drawnWithLabelBelow(double maxWidthEm, String above) {
  final layer = _layer(maxWidthEm);
  final painter = LabelPainter();
  final recorder = ui.PictureRecorder();
  final drawn = painter.paint(
    canvas: Canvas(recorder),
    screenSize: const Size(400, 400),
    styleZoom: 12,
    symbols: [
      _symbol(layer, above, const Offset(200, 200)),
      _symbol(layer, 'X', const Offset(200, 224)),
    ],
    placementGeneration: _nextPlacementGeneration++,
  );
  recorder.endRecording().dispose();
  painter.dispose();
  return drawn.length;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a word wider than text-max-width stays on one line', () {
    // 15 letters against a 2 em width: Flutter alone would break it
    // into seven or eight lines; MapLibre keeps it whole.
    expect(_drawnWithLabelBelow(2, 'LUDWIGSVORSTADT'), 2);
  });

  test('words still wrap at text-max-width', () {
    // Three words, each wider than 2 em: one line each, as in MapLibre.
    expect(_drawnWithLabelBelow(2, 'Altes Rathaus Turm'), 1);
    // A width they fit in together keeps them on one line.
    expect(_drawnWithLabelBelow(30, 'Altes Rathaus Turm'), 2);
  });

  group('breakAroundWideRuns', () {
    // The test font draws every glyph one em wide: at font size 10 a
    // 100 px text-max-width holds ten characters.
    const style = TextStyle(fontSize: 10);
    String broken(String text) =>
        LabelPainter.breakAroundWideRuns(text, style, 100);

    test('gives a wide word its own line and wraps the rest at the width', () {
      // Widening the paragraph to the long word (17 em) would have put
      // "aa bb cc dd ee ff" on one line, 17 em against a 10 em width.
      expect(broken('aa bb cc dd ee ff gg hh LONGWORDXXXXXXXXX'),
          'aa bb cc\ndd ee ff\ngg hh\nLONGWORDXXXXXXXXX');
      expect(broken('LONGWORDXXXXXXXXX aa bb'), 'LONGWORDXXXXXXXXX\naa bb');
    });

    test('keeps explicit line breaks', () {
      expect(broken('aa\nLONGWORDXXXXXXXXX'), 'aa\nLONGWORDXXXXXXXXX');
    });
  });
}
