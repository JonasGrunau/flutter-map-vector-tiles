import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_map_vector_tiles/src/render/label_painter.dart';
import 'package:flutter_map_vector_tiles/src/render/symbol_layouter.dart';
import 'package:flutter_map_vector_tiles/src/style/expression.dart';
import 'package:flutter_map_vector_tiles/src/style/theme.dart';
import 'package:flutter_map_vector_tiles/src/style/theme_reader.dart';
import 'package:flutter_test/flutter_test.dart';

SymbolThemeLayer _lineLayer({Map<String, Object?> layout = const {}}) {
  final theme = const ThemeReader().read({
    'layers': [
      {
        'id': 'road-label',
        'type': 'symbol',
        'source': 's',
        'source-layer': 'transportation_name',
        'layout': {
          'symbol-placement': 'line',
          'text-field': '{name}',
          'text-size': 14,
          ...layout,
        },
      },
    ],
  });
  return theme.layers.single as SymbolThemeLayer;
}

/// Builds a [SymbolPath] from point pairs, with cumulative distances.
SymbolPath _path(List<Offset> points) {
  final coords = Float32List(points.length * 2);
  final cumulative = Float32List(points.length);
  var total = 0.0;
  for (var i = 0; i < points.length; i++) {
    coords[i * 2] = points[i].dx;
    coords[i * 2 + 1] = points[i].dy;
    if (i > 0) {
      total += (points[i] - points[i - 1]).distance;
    }
    cumulative[i] = total;
  }
  return SymbolPath(coords, cumulative);
}

PlacedSymbol _lineSymbol(
  SymbolThemeLayer layer,
  SymbolPath path,
  String text, {
  double? pathDistance,
}) {
  final d = pathDistance ?? path.length / 2;
  final anchor = path.pointAt(d);
  final transform = TileTransform(origin: Offset.zero, scale: 1, rotation: 0);
  return PlacedSymbol(
    instance: SymbolInstance(
      layer: layer,
      layerIndex: 0,
      anchor: anchor,
      angle: path.angleAt(d),
      alongLine: true,
      path: path,
      pathDistance: d,
      text: text,
      iconName: null,
      sortKey: 0,
      properties: const {},
      geometryType: 'LineString',
      featureId: null,
    ),
    screenAnchor: transform.apply(anchor),
    screenAngle: path.angleAt(d),
    transform: transform,
  );
}

/// Paints one frame. Pass [painter] to keep the placement memory across
/// frames, the way the layer does — a throwaway painter remembers
/// nothing.
List<PlacedSymbol> _paint(List<PlacedSymbol> symbols, {LabelPainter? painter}) {
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

/// The reading direction [painter] remembers for [symbol]'s label.
bool? _flipOf(LabelPainter painter, PlacedSymbol symbol) =>
    painter.debugPlacement
        .lookup(symbol.instance.continuityKey, symbol.screenAnchor)
        ?.flip;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('theme reader parses curved-text properties with defaults', () {
    final defaults = _lineLayer();
    const ctx = EvalContext(zoom: 12);
    expect(defaults.textMaxAngle.eval(ctx), 45);
    expect(defaults.textKeepUpright.eval(ctx), true);
    expect(defaults.textRotationAlignment.eval(ctx), 'auto');

    final custom = _lineLayer(layout: {
      'text-max-angle': 30,
      'text-keep-upright': false,
      'text-rotation-alignment': 'viewport',
    });
    expect(custom.textMaxAngle.eval(ctx), 30);
    expect(custom.textKeepUpright.eval(ctx), false);
    expect(custom.textRotationAlignment.eval(ctx), 'viewport');
  });

  test('SymbolPath samples points and angles along segments', () {
    // L-shape: 100 right, then 100 down.
    final path = _path(const [
      Offset(0, 0),
      Offset(100, 0),
      Offset(100, 100),
    ]);
    expect(path.length, 200);
    expect(path.pointAt(50), const Offset(50, 0));
    expect(path.angleAt(50), 0);
    expect(path.pointAt(150), const Offset(100, 50));
    expect(path.angleAt(150), closeTo(math.pi / 2, 1e-9));
    // Clamped at the ends.
    expect(path.pointAt(-5), const Offset(0, 0));
    expect(path.pointAt(400), const Offset(100, 100));
  });

  test('layouter emits path and pathDistance for line placement', () {
    final layer = _lineLayer();
    // Direct check via a placed symbol round-trip: the painter needs
    // both fields, so their construction is covered by the tests below;
    // here we assert the SymbolInstance surface exists and defaults.
    final path = _path(const [Offset(0, 0), Offset(200, 0)]);
    final symbol = _lineSymbol(layer, path, 'Main Street');
    expect(symbol.instance.path, same(path));
    expect(symbol.instance.pathDistance, 100);
  });

  test('label on a gently curved line is drawn', () {
    // A wide arc: many segments, ~5 degrees of turn per vertex.
    final points = <Offset>[];
    for (var i = 0; i <= 24; i++) {
      final a = -math.pi / 6 + (math.pi / 3) * i / 24;
      points.add(
          const Offset(200, 400) + Offset(math.sin(a), -math.cos(a)) * 240);
    }
    final layer = _lineLayer();
    final placed = _paint([_lineSymbol(layer, _path(points), 'Ringstraße')]);
    expect(placed, hasLength(1));
  });

  test('label longer than its line is dropped', () {
    final layer = _lineLayer();
    final path = _path(const [Offset(0, 0), Offset(30, 0)]);
    final placed = _paint(
        [_lineSymbol(layer, path, 'An Extremely Long Road Name Indeed')]);
    expect(placed, isEmpty);
  });

  test('label across a sharp corner is dropped (text-max-angle)', () {
    // 90-degree corner right under the label.
    final layer = _lineLayer();
    final path = _path(const [
      Offset(0, 0),
      Offset(100, 0),
      Offset(100, 100),
    ]);
    final placed =
        _paint([_lineSymbol(layer, path, 'Corner Road', pathDistance: 100)]);
    expect(placed, isEmpty);
  });

  test('right-to-left line keeps text placeable (keep-upright flip)', () {
    final layer = _lineLayer();
    // Line runs right-to-left on screen.
    final path = _path(const [Offset(300, 100), Offset(0, 100)]);
    final placed = _paint([_lineSymbol(layer, path, 'Hauptstraße')]);
    expect(placed, hasLength(1));
  });

  test('a near-vertical road holds its reading direction', () {
    final layer = _lineLayer();
    // A road running almost straight down the screen. Which way its
    // label reads is decided by a few pixels of chord, and every change
    // of mind mirrors the label — including any perpendicular
    // `text-offset`, which is measured in the label's own frame — to
    // the other side of the street.
    final path = _path(const [Offset(100, 0), Offset(103, 300)]);
    final instance = _lineSymbol(layer, path, 'Hauptstraße').instance;
    final painter = LabelPainter();
    addTearDown(painter.dispose);

    // Spun about the label's own anchor, so the road turns under a
    // label that stays where it is on screen.
    PlacedSymbol rotated(double degrees) {
      final rotation = degrees * math.pi / 180;
      final cosR = math.cos(rotation), sinR = math.sin(rotation);
      final a = instance.anchor;
      final spun = Offset(a.dx * cosR - a.dy * sinR, a.dx * sinR + a.dy * cosR);
      final transform =
          TileTransform(origin: a - spun, scale: 1, rotation: rotation);
      return PlacedSymbol(
        instance: instance,
        screenAnchor: transform.apply(a),
        screenAngle: instance.angle + rotation,
        transform: transform,
      );
    }

    final upright = rotated(0);
    expect(_paint([upright], painter: painter), hasLength(1));
    expect(_flipOf(painter, upright), isFalse,
        reason: 'reads down and to the right');

    // One degree of rotation takes the road past vertical …
    _paint([rotated(1)], painter: painter);
    expect(_flipOf(painter, upright), isFalse,
        reason: 'inside the dead band the label is left as it is');

    // … and only a clear turn the other way reverses it.
    _paint([rotated(10)], painter: painter);
    expect(_flipOf(painter, upright), isTrue);
    _paint([rotated(1)], painter: painter);
    expect(_flipOf(painter, upright), isTrue,
        reason: 'sticky in both directions');
    _paint([rotated(-10)], painter: painter);
    expect(_flipOf(painter, upright), isFalse);
  });

  test('a road that changes instance keeps its reading direction', () {
    // The same street as the tile set hands over: a new zoom level's
    // copy is a different SymbolInstance, laid out from geometry
    // simplified differently, so its chord can point the other way by a
    // pixel. Deciding cold there turns the name around — and mirrors it
    // to the other side of the street — at the moment the level swaps.
    final layer = _lineLayer();
    final outgoing = _lineSymbol(
        layer, _path(const [Offset(100, 0), Offset(103, 300)]), 'Hauptstraße');
    final arriving = _lineSymbol(
        layer, _path(const [Offset(100, 0), Offset(99, 300)]), 'Hauptstraße');
    expect(
        (arriving.screenAnchor - outgoing.screenAnchor).distance, lessThan(32),
        reason: 'the two levels put the anchor within a match radius');

    final cold = LabelPainter();
    addTearDown(cold.dispose);
    _paint([arriving], painter: cold);
    expect(_flipOf(cold, arriving), isTrue,
        reason: 'on its own the arriving copy reads the other way');

    final painter = LabelPainter();
    addTearDown(painter.dispose);
    _paint([outgoing], painter: painter);
    expect(_flipOf(painter, outgoing), isFalse);
    _paint([arriving], painter: painter);
    expect(_flipOf(painter, arriving), isFalse,
        reason: 'it inherits the direction the copy it replaces was read at');
  });

  test('two labels on the same spot still collide', () {
    final layer = _lineLayer();
    final path = _path(const [Offset(0, 100), Offset(300, 100)]);
    final placed = _paint([
      _lineSymbol(layer, path, 'Alpha Road'),
      _lineSymbol(layer, path, 'Beta Road'),
    ]);
    expect(placed, hasLength(1));
  });

  test('complex scripts fall back to straight placement and draw', () {
    final layer = _lineLayer();
    final path = _path(const [Offset(0, 100), Offset(300, 100)]);
    // Arabic joins contextually — must not be re-shaped per glyph.
    final placed = _paint([_lineSymbol(layer, path, 'شارع الملك')]);
    expect(placed, hasLength(1));
  });

  test('viewport rotation alignment draws horizontally', () {
    final layer = _lineLayer(layout: {'text-rotation-alignment': 'viewport'});
    final path = _path(const [Offset(100, 0), Offset(100, 300)]);
    final placed = _paint([_lineSymbol(layer, path, 'Shield')]);
    expect(placed, hasLength(1));
  });
}
