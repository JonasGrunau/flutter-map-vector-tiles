import 'dart:typed_data';

import 'package:flutter_map_vector_tiles/src/core/tile_key.dart';
import 'package:flutter_map_vector_tiles/src/pipeline/prepared_tile.dart';
import 'package:flutter_map_vector_tiles/src/render/display_tile_data.dart';
import 'package:flutter_map_vector_tiles/src/render/symbol_layouter.dart';
import 'package:flutter_map_vector_tiles/src/render/tile_rasterizer.dart';
import 'package:flutter_map_vector_tiles/src/style/theme.dart';
import 'package:flutter_map_vector_tiles/src/style/theme_reader.dart';
import 'package:flutter_test/flutter_test.dart';

const _extent = 4096;

Theme _theme({Map<String, Object?> layout = const {}}) =>
    const ThemeReader().read({
      'layers': [
        {
          'id': 'poi',
          'type': 'symbol',
          'source': 's',
          'source-layer': 'poi',
          'layout': {'text-field': '{name}', 'text-size': 14, ...layout},
        },
      ],
    });

/// A point feature at [x],[y] in tile-extent units.
PreparedFeature _point(double x, double y, String name) => PreparedFeature(
      id: null,
      type: PreparedGeomType.point,
      parts: [
        Float32List.fromList([x, y])
      ],
      properties: {'name': name},
    );

DisplayTileData _data({
  required TileKey displayKey,
  required TileKey dataKey,
  required List<PreparedFeature> features,
}) =>
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

List<SymbolInstance> _layout(
  Theme theme,
  DisplayTileData data, {
  double styleZoom = 14,
}) =>
    SymbolLayouter.layout(theme: theme, data: data, styleZoom: styleZoom);

void main() {
  group('tile-seam deduplication', () {
    // Each display tile lays out only the symbols anchored inside it.
    // Without this, a feature duplicated into the neighbouring tile's
    // geometry buffer would be drawn twice — once per tile — and the
    // screen-space collision pass cannot remove it, because the two
    // copies sit at the same place and the first one placed wins.
    const key = TileKey(14, 100, 100);

    test('anchors inside the tile are laid out', () {
      final instances = _layout(
        _theme(),
        _data(
          displayKey: key,
          dataKey: key,
          features: [_point(_extent / 2, _extent / 2, 'Centre')],
        ),
      );
      expect(instances, hasLength(1));
      expect(instances.single.anchor.dx,
          closeTo(TileRasterizer.logicalTileSize / 2, 0.01));
    });

    test('anchors beyond the tile edge are dropped', () {
      // Tiles carry a geometry buffer, so features from the neighbour
      // appear at coordinates outside 0..extent.
      final instances = _layout(
        _theme(),
        _data(
          displayKey: key,
          dataKey: key,
          features: [
            _point(-_extent * 0.1, _extent / 2, 'Left neighbour'),
            _point(_extent * 1.1, _extent / 2, 'Right neighbour'),
            _point(_extent / 2, -_extent * 0.1, 'Above'),
            _point(_extent / 2, _extent * 1.1, 'Below'),
          ],
        ),
      );
      expect(instances, isEmpty);
    });

    test('a feature on a shared edge is never lost', () {
      // The accepted band is [-0.5, 256.5): half a logical pixel wider
      // than the tile on each side. A feature landing exactly on the
      // boundary is therefore claimed by *both* neighbours rather than
      // risking neither claiming it — `extent` need not be a power of
      // two, so the edge coordinate is not always exactly representable
      // and a strict `[0, 256)` test could drop the label on both sides.
      //
      // Losing a label outright is worse than drawing it twice at the
      // same spot, which the screen-space collision pass suppresses for
      // any layer that does not set `*-allow-overlap`.
      final theme = _theme();
      final fromLeft = _layout(
        theme,
        _data(
          displayKey: const TileKey(14, 100, 100),
          dataKey: const TileKey(14, 100, 100),
          // Right edge of the left tile.
          features: [_point(_extent.toDouble(), _extent / 2, 'Shared')],
        ),
      );
      final fromRight = _layout(
        theme,
        _data(
          displayKey: const TileKey(14, 101, 100),
          dataKey: const TileKey(14, 101, 100),
          // Same world position, expressed in the right tile: x = 0.
          features: [_point(0, _extent / 2, 'Shared')],
        ),
      );
      expect(fromLeft.length + fromRight.length, greaterThanOrEqualTo(1),
          reason: 'a boundary feature must never vanish from both tiles');
      // Both land on the shared edge, so collision removes the copy.
      expect(fromLeft.single.anchor.dx,
          closeTo(TileRasterizer.logicalTileSize, 0.01));
      expect(fromRight.single.anchor.dx, closeTo(0, 0.01));
    });

    test('features a full pixel past the edge are still dropped', () {
      // The tolerance band is narrow: it must not become a licence to
      // lay out the neighbour's interior features.
      const key = TileKey(14, 100, 100);
      const oneLogicalPixel = _extent / TileRasterizer.logicalTileSize;
      final instances = _layout(
        _theme(),
        _data(
          displayKey: key,
          dataKey: key,
          features: [
            _point(-oneLogicalPixel, _extent / 2, 'Just outside left'),
            _point(
                _extent + oneLogicalPixel, _extent / 2, 'Just outside right'),
          ],
        ),
      );
      expect(instances, isEmpty);
    });
  });

  group('overzoom positioning', () {
    // Sources stop at a maximum zoom (OpenMapTiles caps at 15), so at
    // high zoom several display tiles share one data tile and each must
    // render its own quarter of it.
    test('each child tile maps its own quadrant of the parent', () {
      const parent = TileKey(14, 100, 100);
      // A point at the exact centre of the parent tile falls on the
      // shared corner of its four children, so give each child a point
      // at the centre of that child's own quadrant instead.
      const size = TileRasterizer.logicalTileSize;
      for (final (childX, childY, quadX, quadY) in [
        (200, 200, 0.25, 0.25),
        (201, 200, 0.75, 0.25),
        (200, 201, 0.25, 0.75),
        (201, 201, 0.75, 0.75),
      ]) {
        final instances = _layout(
          _theme(),
          _data(
            displayKey: TileKey(15, childX, childY),
            dataKey: parent,
            features: [_point(_extent * quadX, _extent * quadY, 'P')],
          ),
        );
        expect(instances, hasLength(1),
            reason: 'child ($childX,$childY) should claim its own quadrant');
        // Within its child tile the point sits at the centre.
        expect(instances.single.anchor.dx, closeTo(size / 2, 0.01));
        expect(instances.single.anchor.dy, closeTo(size / 2, 0.01));
      }
    });

    test('a point in one quadrant is not claimed by its siblings', () {
      const parent = TileKey(14, 100, 100);
      // Top-left quadrant of the parent.
      final feature = _point(_extent * 0.25, _extent * 0.25, 'P');
      var claimed = 0;
      for (final (childX, childY) in [
        (200, 200),
        (201, 200),
        (200, 201),
        (201, 201),
      ]) {
        claimed += _layout(
          _theme(),
          _data(
            displayKey: TileKey(15, childX, childY),
            dataKey: parent,
            features: [feature],
          ),
        ).length;
      }
      expect(claimed, 1, reason: 'exactly one child renders the point');
    });
  });

  group('zoom range', () {
    test('layers outside their zoom range contribute nothing', () {
      final theme = const ThemeReader().read({
        'layers': [
          {
            'id': 'poi',
            'type': 'symbol',
            'source': 's',
            'source-layer': 'poi',
            'minzoom': 12,
            'maxzoom': 16,
            'layout': {'text-field': '{name}', 'text-size': 14},
          },
        ],
      });
      DisplayTileData data() => _data(
            displayKey: const TileKey(14, 100, 100),
            dataKey: const TileKey(14, 100, 100),
            features: [_point(_extent / 2, _extent / 2, 'Centre')],
          );

      expect(_layout(theme, data(), styleZoom: 14), hasLength(1));
      expect(_layout(theme, data(), styleZoom: 10), isEmpty);
      expect(_layout(theme, data(), styleZoom: 17), isEmpty);
    });
  });

  group('symbol content', () {
    test('features with neither text nor icon are skipped', () {
      final instances = _layout(
        _theme(),
        _data(
          displayKey: const TileKey(14, 100, 100),
          dataKey: const TileKey(14, 100, 100),
          features: [
            PreparedFeature(
              id: null,
              type: PreparedGeomType.point,
              parts: [
                Float32List.fromList([_extent / 2, _extent / 2])
              ],
              properties: const {}, // no name -> text-field resolves empty
            ),
          ],
        ),
      );
      expect(instances, isEmpty);
    });

    test('text-transform is applied', () {
      final instances = _layout(
        _theme(layout: {'text-transform': 'uppercase'}),
        _data(
          displayKey: const TileKey(14, 100, 100),
          dataKey: const TileKey(14, 100, 100),
          features: [_point(_extent / 2, _extent / 2, 'Kirchheim')],
        ),
      );
      expect(instances.single.text, 'KIRCHHEIM');
    });
  });
}
