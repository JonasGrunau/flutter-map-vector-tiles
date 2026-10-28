import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_map_vector_tiles/src/core/tile_key.dart';
import 'package:flutter_map_vector_tiles/src/pipeline/prepared_tile.dart';
import 'package:flutter_map_vector_tiles/src/render/display_tile_data.dart';
import 'package:flutter_map_vector_tiles/src/render/label_painter.dart';
import 'package:flutter_map_vector_tiles/src/render/symbol_layouter.dart';
import 'package:flutter_map_vector_tiles/src/style/theme.dart';
import 'package:flutter_map_vector_tiles/src/style/theme_reader.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/label_ids.dart';

// Which of two colliding labels of one layer wins, when neither has a
// lower symbol-sort-key: MapLibre places a layer tile by tile and, in
// each tile, feature by feature in source order, so the earlier
// feature keeps its label. Screen position plays no part.

const _extent = 4096;

final _theme = const ThemeReader().read({
  'layers': [
    {
      'id': 'shields',
      'type': 'symbol',
      'source': 's',
      'source-layer': 'poi',
      'layout': {
        'text-field': '{name}',
        'text-size': 10,
        'symbol-sort-key': ['get', 'rank'],
      },
    },
  ],
});

SymbolThemeLayer get _layer => _theme.layers.single as SymbolThemeLayer;

PreparedFeature _point(double x, double y, String name,
        {List<double> more = const []}) =>
    PreparedFeature(
      id: null,
      type: PreparedGeomType.point,
      parts: [
        Float32List.fromList([x, y, ...more])
      ],
      properties: {'name': name},
    );

DisplayTileData _data(
        TileKey displayKey, TileKey dataKey, List<PreparedFeature> features) =>
    DisplayTileData(
      displayKey: displayKey,
      sources: {
        's': PreparedTile(
          key: dataKey,
          layers: {
            'poi': PreparedSourceLayer(extent: _extent, features: features),
          },
          byteSize: 0,
        ),
      },
    );

List<SymbolInstance> _layout(DisplayTileData data) =>
    SymbolLayouter.layout(theme: _theme, data: data, styleZoom: 14);

/// [instance] as a candidate drawn at its tile anchor shifted by
/// [tileOrigin], the screen position of its display tile.
PlacedSymbol _placed(
  SymbolInstance instance,
  int order, {
  Offset tileOrigin = Offset.zero,
  bool retained = false,
}) =>
    PlacedSymbol(
      instance: instance,
      id: labelIdOf(instance.text),
      screenAnchor: tileOrigin + instance.anchor,
      screenAngle: 0,
      retained: retained,
      order: order,
    );

/// A hand-built point label at [anchor], [text] wide enough to collide
/// with another a few pixels away.
SymbolInstance _instance(
  Offset anchor,
  String text, {
  TileKey sourceTile = const TileKey(14, 0, 0),
  int featureIndex = 0,
  int part = 0,
  double pathDistance = 0,
  double sortKey = 0,
}) =>
    SymbolInstance(
      layer: _layer,
      layerIndex: 0,
      anchor: anchor,
      angle: 0,
      alongLine: false,
      pathDistance: pathDistance,
      text: text,
      iconName: null,
      sortKey: sortKey,
      properties: const {},
      geometryType: 'Point',
      featureId: null,
      sourceTile: sourceTile,
      featureIndex: featureIndex,
      part: part,
    );

/// The texts [symbols] draw, after one placing pass.
List<String> _drawn(List<PlacedSymbol> symbols) {
  final painter = LabelPainter();
  final recorder = ui.PictureRecorder();
  final drawn = painter.paint(
    canvas: Canvas(recorder),
    screenSize: const Size(600, 300),
    styleZoom: 14,
    symbols: symbols,
    placementGeneration: 0,
  );
  recorder.endRecording().dispose();
  painter.dispose();
  return [for (final symbol in drawn) symbol.instance.text];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the layouter records where a symbol comes from', () {
    test('its data tile and its feature index in source order', () {
      const dataKey = TileKey(14, 8718, 5685);
      final instances = _layout(_data(dataKey, dataKey, [
        _point(1000, 1000, 'first'),
        _point(3000, 3000, 'second'),
      ]));
      expect([for (final i in instances) (i.text, i.featureIndex)],
          [('first', 0), ('second', 1)]);
      for (final instance in instances) {
        expect(instance.sourceTile, dataKey);
      }
    });

    test('each point of a multipoint is a part', () {
      const key = TileKey(14, 0, 0);
      final instances = _layout(_data(key, key, [
        _point(1000, 1000, 'gate', more: [2000, 2000, 3000, 3000]),
      ]));
      expect([for (final i in instances) i.part], [0, 1, 2]);
    });

    test('display tiles cut from one data tile number its features alike', () {
      // Two z15 display tiles of one z14 data tile, each laying out the
      // feature on its own side of their seam.
      const dataKey = TileKey(14, 10, 10);
      final features = [
        _point(1000, 1000, 'west'),
        _point(3000, 1000, 'east'),
      ];
      final west = _layout(_data(const TileKey(15, 20, 20), dataKey, features));
      final east = _layout(_data(const TileKey(15, 21, 20), dataKey, features));
      expect(west.single.text, 'west');
      expect(west.single.featureIndex, 0);
      expect(east.single.text, 'east');
      expect(east.single.featureIndex, 1);
    });
  });

  group('colliding labels of one layer', () {
    test('place in feature order, not screen order', () {
      // The Marienplatz stairs: two staircase shields a few pixels
      // apart, the later feature (MP30) higher on screen. MapLibre keeps
      // MP31.
      const key = TileKey(14, 8718, 5685);
      final instances = _layout(_data(key, key, [
        _point(2048, 2100, 'MP31'),
        _point(2048, 2060, 'MP30'),
      ]));
      expect(instances.last.anchor.dy, lessThan(instances.first.anchor.dy));
      // Listed in reverse as well, so insertion order cannot decide it.
      expect(
        _drawn([_placed(instances.last, 0), _placed(instances.first, 1)]),
        ['MP31'],
      );
    });

    test('place in one order across display tiles of one data tile', () {
      // The features sit either side of the two display tiles' seam,
      // close enough on screen to collide; the later one is higher.
      const dataKey = TileKey(14, 10, 10);
      final features = [
        _point(2040, 1000, 'MP31'),
        _point(2056, 990, 'MP30'),
      ];
      final west = _layout(_data(const TileKey(15, 20, 20), dataKey, features));
      final east = _layout(_data(const TileKey(15, 21, 20), dataKey, features));
      expect(
        _drawn([
          _placed(east.single, 0, tileOrigin: const Offset(256, 0)),
          _placed(west.single, 1),
        ]),
        ['MP31'],
      );
    });

    test('place deeper data tiles first, then by x, then by y', () {
      List<String> winner(TileKey a, TileKey b) => _drawn([
            // [b] is listed first and sits higher: only the tile order
            // can make [a] win.
            _placed(_instance(const Offset(100, 105), 'A', sourceTile: a), 1),
            _placed(_instance(const Offset(100, 100), 'B', sourceTile: b), 0),
          ]);
      expect(winner(const TileKey(15, 9, 9), const TileKey(14, 0, 0)), ['A']);
      expect(winner(const TileKey(14, 3, 9), const TileKey(14, 4, 0)), ['A']);
      expect(winner(const TileKey(14, 4, 3), const TileKey(14, 4, 4)), ['A']);
    });

    test('place one feature part by part, and along a part from its start', () {
      List<String> winner(SymbolInstance a, SymbolInstance b) =>
          _drawn([_placed(b, 0), _placed(a, 1)]);
      expect(
        winner(
          _instance(const Offset(100, 105), 'A', part: 0, pathDistance: 90),
          _instance(const Offset(100, 100), 'B', part: 1, pathDistance: 10),
        ),
        ['A'],
      );
      expect(
        winner(
          _instance(const Offset(100, 105), 'A', pathDistance: 10),
          _instance(const Offset(100, 100), 'B', pathDistance: 90),
        ),
        ['A'],
      );
    });

    test('place a lower symbol-sort-key first, whatever the feature order', () {
      expect(
        _drawn([
          _placed(_instance(const Offset(100, 100), 'B', featureIndex: 0), 0),
          _placed(
              _instance(const Offset(100, 105), 'A',
                  featureIndex: 9, sortKey: -1),
              1),
        ]),
        ['A'],
      );
    });

    test('place the current level ahead of a retained one', () {
      // The retained candidate comes from a deeper tile and an earlier
      // feature, and sits higher: it still loses.
      expect(
        _drawn([
          _placed(
              _instance(const Offset(100, 100), 'B',
                  sourceTile: const TileKey(15, 0, 0)),
              0,
              retained: true),
          _placed(
              _instance(const Offset(100, 105), 'A',
                  sourceTile: const TileKey(14, 0, 0), featureIndex: 5),
              1),
        ]),
        ['A'],
      );
    });
  });
}
