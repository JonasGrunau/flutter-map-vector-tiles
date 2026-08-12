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

    test('the range is gated at the exact zoom, not the quantized one', () {
      // Size expressions are evaluated at the zoom rounded to 1/8 so the
      // expression memos keep hitting during a pinch. Visibility is a
      // discrete cut and must not inherit that rounding: both zooms here
      // are inside [14, 16) but round to a bound, so gating on the
      // rounded value moves the threshold by up to 1/16 of a level.
      final layer = _symbolLayer(minzoom: 14, maxzoom: 16);
      List<PlacedSymbol> paintAt(double styleZoom) => _paint(
            layer,
            [_symbolAt(layer, const Offset(200, 200), 'Main St')],
            styleZoom: styleZoom,
          );
      expect(paintAt(13.9375), isEmpty,
          reason: 'below minzoom, though it rounds up to exactly 14');
      expect(paintAt(15.9375), hasLength(1),
          reason: 'still below maxzoom, though it rounds up to exactly 16');
    });
  });

  group('zoom-range fade-out', () {
    test('full opacity until the window before a declared maxzoom', () {
      final layer = _symbolLayer(minzoom: 10, maxzoom: 16);
      expect(LabelPainter.zoomRangeOpacity(layer, 12), 1);
      expect(LabelPainter.zoomRangeOpacity(layer, 15.5), 1);
    });

    test('ramps down to zero approaching maxzoom', () {
      final layer = _symbolLayer(maxzoom: 16);
      final ramp = [15.8, 15.85, 15.9, 15.95, 16.0]
          .map((z) => LabelPainter.zoomRangeOpacity(layer, z))
          .toList();
      expect(ramp.first, lessThan(1));
      expect(ramp.last, 0, reason: 'fully faded exactly at the threshold');
      for (var i = 1; i < ramp.length; i++) {
        expect(ramp[i], lessThanOrEqualTo(ramp[i - 1]),
            reason: 'monotonic: $ramp');
      }
    });

    test('is quantized, so a fade spans few saveLayer buckets', () {
      final layer = _symbolLayer(maxzoom: 16);
      for (final zoom in [15.79, 15.83, 15.87, 15.91, 15.97]) {
        final opacity = LabelPainter.zoomRangeOpacity(layer, zoom);
        expect((opacity * 8) % 1, 0, reason: 'off the 1/8 grid at $zoom');
      }
    });

    test('a layer with no declared maxzoom never ramps', () {
      // The reader substitutes 24 for an absent maxzoom; that stands for
      // "unset", not for an edge the style drew.
      final layer = _symbolLayer(minzoom: 10);
      expect(LabelPainter.zoomRangeOpacity(layer, 23.9), 1);
      expect(LabelPainter.zoomRangeOpacity(layer, 20), 1);
    });

    test('a band narrower than the window still peaks at full opacity', () {
      // The ramp shrinks to fit the declared band: with a fixed window a
      // minzoom 14 / maxzoom 14.2 layer would sit at 0.8 even at its
      // inclusive minzoom and never reach full opacity anywhere.
      final layer = _symbolLayer(minzoom: 14, maxzoom: 14.2);
      expect(LabelPainter.zoomRangeOpacity(layer, 14.0), 1,
          reason: 'full opacity at the inclusive minzoom');
      expect(LabelPainter.zoomRangeOpacity(layer, 14.1), lessThan(1));
      expect(LabelPainter.zoomRangeOpacity(layer, 14.2), 0,
          reason: 'still fully faded exactly at the threshold');
    });

    test('minzoom never ramps — it is inclusive', () {
      // A symmetric ramp would leave a `minzoom: 14` layer invisible on a
      // map resting at exactly zoom 14, which is both the common resting
      // case and the first zoom the style asks for that label.
      final layer = _symbolLayer(minzoom: 14, maxzoom: 18);
      expect(LabelPainter.zoomRangeOpacity(layer, 14.0), 1);
      expect(
        _paint(layer, [_symbolAt(layer, const Offset(200, 200), 'Main St')],
            styleZoom: 14.0),
        hasLength(1),
      );
    });

    test('a symbol mid-ramp still draws; at the threshold it does not', () {
      final layer = _symbolLayer(maxzoom: 16);
      List<PlacedSymbol> paintAt(double styleZoom) => _paint(
            layer,
            [_symbolAt(layer, const Offset(200, 200), 'Main St')],
            styleZoom: styleZoom,
          );
      expect(paintAt(15.8), hasLength(1), reason: 'mid-ramp, still visible');
      expect(paintAt(15.99), isEmpty,
          reason: 'ramped to zero — inside the range, but painting nothing');
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
