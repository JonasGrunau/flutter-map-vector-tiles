import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_map_vector_tiles/flutter_map_vector_tiles.dart';
import 'package:flutter_map_vector_tiles/src/pipeline/prepared_tile.dart';
import 'package:flutter_map_vector_tiles/src/render/display_tile_data.dart';
import 'package:flutter_map_vector_tiles/src/render/feature_query.dart';
import 'package:flutter_map_vector_tiles/src/render/hit_test.dart';
import 'package:flutter_map_vector_tiles/src/render/symbol_layouter.dart';
import 'package:flutter_test/flutter_test.dart';

const _extent = 4096;

/// Tile-extent units per logical pixel when display tile == data tile.
const _px = _extent / 256;

PreparedFeature _feature(
  PreparedGeomType type,
  List<List<double>> parts, {
  Map<String, Object?> properties = const {},
  Object? id,
}) {
  var minX = double.infinity, minY = double.infinity;
  var maxX = double.negativeInfinity, maxY = double.negativeInfinity;
  for (final part in parts) {
    for (var i = 0; i < part.length; i += 2) {
      minX = math.min(minX, part[i]);
      maxX = math.max(maxX, part[i]);
      minY = math.min(minY, part[i + 1]);
      maxY = math.max(maxY, part[i + 1]);
    }
  }
  return PreparedFeature(
    id: id,
    type: type,
    parts: [for (final part in parts) Float32List.fromList(part)],
    properties: properties,
    minX: minX,
    minY: minY,
    maxX: maxX,
    maxY: maxY,
  );
}

/// A square ring, clockwise on screen (y down) — an MVT exterior.
List<double> _square(double x0, double y0, double x1, double y1) =>
    [x0, y0, x1, y0, x1, y1, x0, y1];

/// The same square counter-clockwise — an MVT hole.
List<double> _hole(double x0, double y0, double x1, double y1) =>
    [x0, y0, x0, y1, x1, y1, x1, y0];

PreparedTile _tile(TileKey key, Map<String, List<PreparedFeature>> layers) =>
    PreparedTile(
      key: key,
      layers: {
        for (final entry in layers.entries)
          entry.key:
              PreparedSourceLayer(extent: _extent, features: entry.value),
      },
      byteSize: 0,
    );

Theme _theme(List<Map<String, Object?>> layers) =>
    const ThemeReader().read({'layers': layers});

List<String> _hits(
  Theme theme,
  PreparedTile tile,
  HitArea area, {
  TileKey? display,
  double styleZoom = 14,
  Set<String>? layerIds,
}) =>
    [
      for (final hit in FeatureQuery.hitTile(
        theme: theme,
        data: DisplayTileData(
            displayKey: display ?? tile.key, sources: {'s': tile}),
        styleZoom: styleZoom,
        area: area,
        layerIds: layerIds,
      ))
        '${hit.layer.id}:${hit.feature.id}',
    ];

HitArea _at(double x, double y) => HitArea([Offset(x, y)]);

HitArea _rect(Rect r) =>
    HitArea([r.topLeft, r.topRight, r.bottomRight, r.bottomLeft]);

void main() {
  const key = TileKey(14, 8700, 5600);

  group('HitArea', () {
    test('a polygon with a hole is hit in its ring, not in the hole', () {
      final area = HitArea([const Offset(1500, 2000)]);
      final rings = [
        Float32List.fromList(_square(1000, 1000, 3000, 3000)),
        Float32List.fromList(_hole(1400, 1400, 2600, 2600)),
      ];
      expect(area.hitsPolygon(rings), isFalse);
      expect(HitArea([const Offset(1200, 2000)]).hitsPolygon(rings), isTrue);
      expect(HitArea([const Offset(3200, 2000)]).hitsPolygon(rings), isFalse);
      // A rectangle wholly in the hole touches no edge and misses; one
      // in the ring, also clear of every edge, hits; one spanning the
      // hole's edge hits.
      expect(
          _rect(const Rect.fromLTRB(1800, 1800, 2200, 2200)).hitsPolygon(rings),
          isFalse);
      expect(
          _rect(const Rect.fromLTRB(1100, 1800, 1300, 2200)).hitsPolygon(rings),
          isTrue);
      expect(
          _rect(const Rect.fromLTRB(1300, 1800, 1500, 2200)).hitsPolygon(rings),
          isTrue);
    });

    test('a rectangle hits a polygon it only crosses an edge of', () {
      final rings = [Float32List.fromList(_square(1000, 1000, 3000, 3000))];
      // A thin bar across the left edge: no vertex of either inside the
      // other.
      expect(
          _rect(const Rect.fromLTRB(900, 1500, 1100, 1510)).hitsPolygon(rings),
          isTrue);
      expect(
          _rect(const Rect.fromLTRB(100, 1500, 900, 1510)).hitsPolygon(rings),
          isFalse);
      // A rectangle inside a polygon, and one containing it.
      expect(
          _rect(const Rect.fromLTRB(1500, 1500, 1600, 1600)).hitsPolygon(rings),
          isTrue);
      expect(_rect(const Rect.fromLTRB(0, 0, 4000, 4000)).hitsPolygon(rings),
          isTrue);
    });

    test('a line is hit within half its width', () {
      final runs = [
        Float32List.fromList([0, 100, 400, 100])
      ];
      expect(_at(200, 103).hitsLine(runs, 3), isTrue);
      expect(_at(200, 103.5).hitsLine(runs, 3), isFalse);
      // Past an end: the distance to the end point.
      expect(_at(402, 100).hitsLine(runs, 3), isTrue);
      expect(_at(404, 100).hitsLine(runs, 3), isFalse);
      // A rectangle beside the line, within reach of its edge.
      expect(_rect(const Rect.fromLTRB(150, 104, 160, 110)).hitsLine(runs, 5),
          isTrue);
      expect(_rect(const Rect.fromLTRB(150, 106, 160, 110)).hitsLine(runs, 5),
          isFalse);
      // A ring stroked as a line is closed.
      final ring = [Float32List.fromList(_square(0, 0, 100, 100))];
      expect(_at(0, 50).hitsLine(ring, 1), isFalse);
      expect(_at(0, 50).hitsLine(ring, 1, close: true), isTrue);
    });

    test('a circle is hit within its reach', () {
      expect(_at(10, 0).hitsCircle(Offset.zero, 10), isTrue);
      expect(_at(10.1, 0).hitsCircle(Offset.zero, 10), isFalse);
      expect(
          _rect(const Rect.fromLTRB(-50, -50, 50, 50))
              .hitsCircle(Offset.zero, 1),
          isTrue);
    });

    test('convex shapes: a rotated box against points and rectangles', () {
      final box = rotatedBox(const Offset(100, 100), 100, 10, math.pi / 4);
      expect(_at(100, 100).hitsConvex(box), isTrue);
      expect(_at(130, 130).hitsConvex(box), isTrue);
      // Inside the box's bounding rectangle, outside the box.
      expect(_at(130, 70).hitsConvex(box), isFalse);
      expect(_rect(const Rect.fromLTRB(125, 60, 140, 75)).hitsConvex(box),
          isFalse);
      expect(_rect(const Rect.fromLTRB(125, 125, 140, 140)).hitsConvex(box),
          isTrue);
    });

    test('a rectangle with no area is a point, not the whole plane', () {
      final rings = [
        Float32List.fromList(_square(1000, 1000, 3000, 3000)),
        Float32List.fromList(_hole(1400, 1400, 2600, 2600)),
      ];
      HitArea empty(double x, double y) => _rect(Rect.fromLTWH(x, y, 0, 0));
      expect(empty(2000, 2000).hitsPolygon(rings), isFalse);
      expect(empty(1200, 2000).hitsPolygon(rings), isTrue);
      final far = [
        Float32List.fromList([0, 0, 4000, 4000])
      ];
      expect(empty(1000, 3000).hitsLine(far, 5), isFalse);
      expect(empty(2000, 2002).hitsLine(far, 5), isTrue);
      // Zero height, clipped across a tile edge: still a segment.
      final strip = _rect(const Rect.fromLTRB(200, 100, 300, 100))
          .clipTo(const Rect.fromLTWH(0, 0, 256, 256));
      expect(strip, isNotNull);
      expect(
          strip!.hitsLine([
            Float32List.fromList([230, 0, 230, 200])
          ], 1),
          isTrue);
    });

    test('clipping to a tile keeps what lies inside it', () {
      const tile = Rect.fromLTWH(0, 0, 256, 256);
      expect(_at(10, 10).clipTo(tile), isNotNull);
      expect(_at(256, 10).clipTo(tile), isNotNull);
      expect(_at(-1, 10).clipTo(tile), isNull);
      final clipped =
          _rect(const Rect.fromLTRB(-100, 100, 100, 300)).clipTo(tile)!;
      expect(clipped.bounds, const Rect.fromLTRB(0, 100, 100, 256));
      expect(_rect(const Rect.fromLTRB(300, 0, 400, 10)).clipTo(tile), isNull);
    });

    test('LabelHit packs its quads and tests each', () {
      final layer = _theme([
        {
          'id': 'label',
          'type': 'symbol',
          'source': 's',
          'source-layer': 'poi',
          'layout': {'text-field': 'x'},
        },
      ]).layers.single as SymbolThemeLayer;
      final hit = LabelHit(
        SymbolInstance(
          layer: layer,
          layerIndex: 0,
          anchor: Offset.zero,
          angle: 0,
          alongLine: false,
          text: 'x',
          iconName: null,
          sortKey: 0,
          properties: const {},
          geometryType: 'Point',
          featureId: null,
        ),
        [
          rotatedRect(const Rect.fromLTWH(0, 0, 10, 10), Offset.zero, 0),
          rotatedBox(const Offset(50, 50), 10, 10, math.pi / 4),
        ],
      );
      expect(hit.quads.length, 16);
      expect(hit.hits(_at(5, 5)), isTrue);
      expect(hit.hits(_at(50, 56)), isTrue);
      expect(hit.hits(_at(30, 30)), isFalse);
    });
  });

  group('FeatureQuery.hitTile', () {
    test('decides hits as the rasterizer draws', () {
      final theme = _theme([
        {
          'id': 'bg',
          'type': 'background',
          'paint': {'background-color': '#fff'},
        },
        {
          'id': 'land',
          'type': 'fill',
          'source': 's',
          'source-layer': 'land',
          // Transparent still answers.
          'paint': {'fill-opacity': 0},
        },
        {
          'id': 'road',
          'type': 'line',
          'source': 's',
          'source-layer': 'road',
          'paint': {
            // 10 px at the tile's zoom, 14.
            'line-width': [
              'interpolate',
              ['linear'],
              ['zoom'],
              10,
              2,
              14,
              10,
            ],
          },
        },
        {
          'id': 'casing',
          'type': 'line',
          'source': 's',
          'source-layer': 'road',
          // Two 2 px casings around a 4 px gap: 8 px across.
          'paint': {'line-width': 2, 'line-gap-width': 4},
        },
        {
          'id': 'poi',
          'type': 'circle',
          'source': 's',
          'source-layer': 'poi',
          'paint': {'circle-radius': 5, 'circle-stroke-width': 2},
        },
        {
          'id': 'label',
          'type': 'symbol',
          'source': 's',
          'source-layer': 'poi',
          'layout': {'text-field': 'x'},
        },
      ]);
      final tile = _tile(key, {
        'land': [
          _feature(
              PreparedGeomType.polygon,
              [
                _square(16 * _px, 16 * _px, 240 * _px, 240 * _px),
                _hole(100 * _px, 100 * _px, 156 * _px, 156 * _px),
              ],
              id: 1),
        ],
        'road': [
          _feature(
              PreparedGeomType.line,
              [
                [0, 64 * _px, 256 * _px, 64 * _px]
              ],
              id: 2),
        ],
        'poi': [
          _feature(
              PreparedGeomType.point,
              [
                [200 * _px, 200 * _px]
              ],
              id: 3),
        ],
      });
      // In the land, off the road.
      expect(_hits(theme, tile, _at(30, 30)), ['land:1']);
      // In the hole.
      expect(_hits(theme, tile, _at(128, 128)), isEmpty);
      // 5 px off the road centre: the 10 px road, not the 8 px casing.
      expect(_hits(theme, tile, _at(30, 69)), ['land:1', 'road:2']);
      expect(
          _hits(theme, tile, _at(30, 67.9)), ['land:1', 'road:2', 'casing:2']);
      // Circle: radius plus stroke.
      expect(_hits(theme, tile, _at(207, 200)), ['land:1', 'poi:3']);
      expect(_hits(theme, tile, _at(207.5, 200)), ['land:1']);
      // Restricted to some layers.
      expect(_hits(theme, tile, _at(30, 66), layerIds: {'road', 'label'}),
          ['road:2']);
      // Draw order, bottom first; the caller reverses it.
      expect(_hits(theme, tile, _rect(const Rect.fromLTRB(0, 0, 256, 256))),
          ['land:1', 'road:2', 'casing:2', 'poi:3']);
    });

    test('respects filters and zoom ranges', () {
      final theme = _theme([
        {
          'id': 'a',
          'type': 'fill',
          'source': 's',
          'source-layer': 'land',
          'filter': ['==', 'kind', 'a'],
        },
        {
          'id': 'zoomed',
          'type': 'fill',
          'source': 's',
          'source-layer': 'land',
          'minzoom': 15,
        },
        {
          'id': 'by-zoom',
          'type': 'fill',
          'source': 's',
          'source-layer': 'land',
          'filter': [
            '>=',
            ['zoom'],
            14,
          ],
        },
      ]);
      final tile = _tile(key, {
        'land': [
          _feature(PreparedGeomType.polygon, [_square(0, 0, 2048, 4096)],
              properties: {'kind': 'a'}, id: 1),
          _feature(PreparedGeomType.polygon, [_square(2048, 0, 4096, 4096)],
              properties: {'kind': 'b'}, id: 2),
        ],
      });
      expect(_hits(theme, tile, _at(64, 64)), ['a:1', 'by-zoom:1']);
      expect(_hits(theme, tile, _at(192, 64)), ['by-zoom:2']);
      expect(_hits(theme, tile, _at(192, 64), styleZoom: 13), isEmpty);
      expect(_hits(theme, tile, _at(192, 64), styleZoom: 15),
          ['zoomed:2', 'by-zoom:2']);
    });

    test('overzoom answers for the window the display tile shows', () {
      final theme = _theme([
        {
          'id': 'land',
          'type': 'fill',
          'source': 's',
          'source-layer': 'land',
        },
        {
          'id': 'road',
          'type': 'line',
          'source': 's',
          'source-layer': 'road',
          'paint': {'line-width': 4},
        },
      ]);
      // A building in the data tile's bottom-right quadrant, a road
      // along its top-left one.
      final tile = _tile(key, {
        'land': [
          _feature(PreparedGeomType.polygon, [_square(2500, 2500, 3500, 3500)],
              id: 1),
        ],
        'road': [
          _feature(
              PreparedGeomType.line,
              [
                [0, 1024, 2048, 1024]
              ],
              id: 2),
        ],
      });
      final topLeft = TileKey(15, key.x * 2, key.y * 2);
      final bottomRight = TileKey(15, key.x * 2 + 1, key.y * 2 + 1);
      // The same display pixel lands on different data.
      expect(_hits(theme, tile, _at(128, 64), display: topLeft, styleZoom: 15),
          isEmpty);
      expect(
          _hits(theme, tile, _at(128, 64), display: bottomRight, styleZoom: 15),
          ['land:1']);
      expect(
          _hits(theme, tile, _at(128, 128),
              display: bottomRight, styleZoom: 15),
          ['land:1']);
      // The road is 4 display pixels wide: data y 1024 is display y 128.
      expect(
          _hits(theme, tile, _at(50, 129.9), display: topLeft, styleZoom: 15),
          ['road:2']);
      expect(
          _hits(theme, tile, _at(50, 130.1), display: topLeft, styleZoom: 15),
          isEmpty);
    });

    test('a descendant answers only for its own sub-square', () {
      final theme = _theme([
        {
          'id': 'land',
          'type': 'fill',
          'source': 's',
          'source-layer': 'land',
        },
      ]);
      // A z15 tile standing in for the top-left quarter of a z14 display
      // tile, with buffer geometry spilling past its edge.
      final child = _tile(TileKey(15, key.x * 2, key.y * 2), {
        'land': [
          _feature(PreparedGeomType.polygon, [_square(0, 0, 4600, 4600)],
              id: 1),
        ],
      });
      List<String> hitsAt(double x, double y) => [
            for (final hit in FeatureQuery.hitTile(
              theme: theme,
              data: DisplayTileData(
                displayKey: key,
                sources: const {},
                descendantSources: {
                  's': [child]
                },
              ),
              styleZoom: 14,
              area: _at(x, y),
            ))
              '${hit.layer.id}:${hit.feature.id}',
          ];
      expect(hitsAt(64, 64), ['land:1']);
      expect(hitsAt(135, 64), isEmpty);
    });

    test('drawsAny finds only the display tiles a feature reaches', () {
      // At z15 a quadrant spans 2048 units and the 64 px cull buffer
      // 512 more: the top-left one reaches x, y = 2560.
      final tile = _tile(key, {
        'land': [
          _feature(PreparedGeomType.polygon, [_square(2600, 2600, 3500, 3500)],
              id: 7),
          _feature(PreparedGeomType.polygon, [_square(0, 0, 100, 100)],
              id: 'x'),
        ],
      });
      bool draws(int dx, int dy, Iterable<Object> ids) => FeatureQuery.drawsAny(
          TileKey(15, key.x * 2 + dx, key.y * 2 + dy), tile, 'land', ids);
      expect(draws(1, 1, [7]), isTrue);
      expect(draws(0, 0, [7]), isFalse);
      expect(draws(1, 0, [7]), isFalse);
      expect(draws(0, 1, [7]), isFalse);
      expect(draws(0, 0, ['x']), isTrue);
      expect(draws(0, 0, [8]), isFalse);
      expect(FeatureQuery.drawsAny(key, tile, 'missing', [7]), isFalse);
    });
  });
}
