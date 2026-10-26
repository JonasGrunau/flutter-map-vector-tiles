import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter_map_vector_tiles/src/core/tile_key.dart';
import 'package:flutter_map_vector_tiles/src/pipeline/prepared_tile.dart';
import 'package:flutter_map_vector_tiles/src/render/display_tile_data.dart';
import 'package:flutter_map_vector_tiles/src/render/matched_features.dart';
import 'package:flutter_map_vector_tiles/src/render/symbol_layouter.dart';
import 'package:flutter_map_vector_tiles/src/render/tile_rasterizer.dart';
import 'package:flutter_map_vector_tiles/src/style/expression.dart';
import 'package:flutter_map_vector_tiles/src/style/theme.dart';
import 'package:flutter_map_vector_tiles/src/style/theme_reader.dart';
import 'package:flutter_test/flutter_test.dart';

/// Reads of a feature's `class` property. Only the filters in these
/// tests read it, so this counts filter evaluations without a hook in
/// the renderer.
var _classReads = 0;

class _CountingProperties extends MapView<String, Object?> {
  _CountingProperties(super.map);

  @override
  Object? operator [](Object? key) {
    if (key == 'class') _classReads++;
    return super[key];
  }
}

/// A z14 data tile, displayed through its z16 descendants at overzoom.
const _dataKey = TileKey(14, 8000, 5000);
const _displayA = TileKey(16, 32001, 20002);
const _displayB = TileKey(16, 32002, 20001);

/// Polygons covering the whole data tile, so every display tile cut
/// from it draws them, plus a point and a line for type-reading filters.
List<PreparedFeature> _features() {
  final square = Float32List.fromList([0, 0, 4096, 0, 4096, 4096, 0, 4096]);
  PreparedFeature polygon(int id, Map<String, Object?> properties) =>
      PreparedFeature(
        id: id,
        type: PreparedGeomType.polygon,
        parts: [square],
        properties: _CountingProperties(properties),
      );
  return [
    polygon(1, {'class': 'park'}),
    polygon(2, {'class': 'wood'}),
    polygon(3, {'class': 'park', 'name': 'Englischer Garten'}),
    polygon(4, {}),
    polygon(5, {'class': 'farmland'}),
    PreparedFeature(
      id: 6,
      type: PreparedGeomType.point,
      parts: [
        Float32List.fromList([2048, 2048])
      ],
      properties: _CountingProperties({'class': 'park'}),
    ),
    PreparedFeature(
      id: 7,
      type: PreparedGeomType.line,
      parts: [
        Float32List.fromList([0, 2048, 4096, 2048])
      ],
      properties: _CountingProperties({'class': 'wood'}),
    ),
  ];
}

PreparedTile _tile(List<PreparedFeature> features) => PreparedTile(
      key: _dataKey,
      layers: {
        'landuse': PreparedSourceLayer(extent: 4096, features: features),
      },
      byteSize: 0,
    );

Theme _fillTheme(Object? filter) => const ThemeReader().read({
      'layers': [
        {
          'id': 'landuse',
          'type': 'fill',
          'source': 's',
          'source-layer': 'landuse',
          if (filter != null) 'filter': filter,
          'paint': {'fill-color': '#22aa44'},
        },
      ],
    });

/// Rasterizes [displayKey] and reports whether anything was drawn.
bool _draws(Theme theme, PreparedTile tile, TileKey displayKey,
    {double styleZoom = 16}) {
  final image = TileRasterizer.rasterize(
    theme: theme,
    data: DisplayTileData(displayKey: displayKey, sources: {'s': tile}),
    styleZoom: styleZoom,
    devicePixelRatio: 1,
  );
  image?.dispose();
  return image != null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => _classReads = 0);

  test('cached matches equal a full scan, in source order', () {
    final sourceLayer = _tile(_features()).layers['landuse']!;
    for (final filter in [
      [
        '==',
        ['get', 'class'],
        'park'
      ],
      ['in', 'class', 'park', 'wood'],
      [
        '!',
        ['has', 'class']
      ],
      [
        '==',
        ['geometry-type'],
        'Polygon'
      ],
      [
        'all',
        ['==', r'$type', 'Polygon'],
        ['!=', 'class', 'park']
      ],
      [
        '>=',
        ['id'],
        3
      ],
      null,
    ]) {
      final layer = _fillTheme(filter).layers.single;
      expect(layer.filterReadsZoom, isFalse, reason: '$filter');
      final matched = MatchedFeatures.of(layer, sourceLayer, tile: _dataKey);
      for (final zoom in [0.0, 10.0, 14.5, 22.0]) {
        expect(
          matched,
          [
            for (final feature in sourceLayer.features)
              if (layer.matches(EvalContext(
                zoom: zoom,
                properties: feature.properties,
                geometryType: feature.geometryType,
                featureId: feature.id,
              )))
                feature,
          ],
          reason: '$filter at zoom $zoom',
        );
      }
      expect(
          MatchedFeatures.of(layer, sourceLayer, tile: _dataKey), same(matched),
          reason: 'resolved once, then served from the cache');
    }
  });

  test('an unfiltered layer shares the source list instead of copying it', () {
    final sourceLayer = _tile(_features()).layers['landuse']!;
    final layer = _fillTheme(null).layers.single;
    expect(MatchedFeatures.of(layer, sourceLayer, tile: _dataKey),
        same(sourceLayer.features));
  });

  test('a zoom-reading filter is not cached and still flips across zooms', () {
    final tile = _tile(_features());
    final theme = _fillTheme([
      'all',
      [
        '==',
        ['get', 'class'],
        'park'
      ],
      [
        '<',
        ['zoom'],
        15
      ],
    ]);
    final layer = theme.layers.single;
    expect(layer.filterReadsZoom, isTrue);
    expect(MatchedFeatures.of(layer, tile.layers['landuse']!, tile: tile.key),
        isNull);

    expect(_draws(theme, tile, _displayA, styleZoom: 14), isTrue);
    expect(_draws(theme, tile, _displayA, styleZoom: 16), isFalse,
        reason: 'the same prepared tile, past the zoom the filter cuts at');
    expect(_draws(theme, tile, _displayA, styleZoom: 14), isTrue);
  });

  test('a second display tile of the same data tile re-evaluates no filter',
      () {
    final features = _features();
    final tile = _tile(features);
    final theme = _fillTheme([
      '==',
      ['get', 'class'],
      'park'
    ]);

    expect(_draws(theme, tile, _displayA), isTrue);
    expect(_classReads, features.length,
        reason: 'one evaluation per feature, for the whole data tile');
    expect(_draws(theme, tile, _displayB), isTrue);
    expect(_draws(theme, tile, _displayA, styleZoom: 16.5), isTrue);
    expect(_classReads, features.length,
        reason: 'later display tiles reuse the matches');

    // A fresh prepared tile (an evicted and re-prepared data tile, say)
    // starts over; nothing outlives the tile it was resolved for.
    expect(_draws(theme, _tile(features), _displayB), isTrue);
    expect(_classReads, 2 * features.length);
  });

  test('a zoom-reading filter is still evaluated per display tile', () {
    final features = _features();
    final tile = _tile(features);
    final theme = _fillTheme([
      'all',
      [
        '==',
        ['get', 'class'],
        'park'
      ],
      [
        '<',
        ['zoom'],
        20
      ],
    ]);
    final polygons =
        features.where((f) => f.type == PreparedGeomType.polygon).length;

    expect(_draws(theme, tile, _displayA), isTrue);
    expect(_draws(theme, tile, _displayB), isTrue);
    expect(_classReads, 2 * polygons);
  });

  test('the symbol layouter resolves zoom-free filters once per data tile', () {
    PreparedFeature city(double x, double y, String cls, String name) =>
        PreparedFeature(
          id: null,
          type: PreparedGeomType.point,
          parts: [
            Float32List.fromList([x, y])
          ],
          properties: _CountingProperties({'class': cls, 'name': name}),
        );
    final features = [
      city(1000, 1000, 'city', 'München'),
      city(1100, 1100, 'village', 'Aschheim'),
      city(3000, 1000, 'city', 'Augsburg'),
      city(1000, 3000, 'town', 'Freising'),
      city(3000, 3000, 'city', 'Ingolstadt'),
    ];
    final tile = PreparedTile(
      key: _dataKey,
      layers: {'place': PreparedSourceLayer(extent: 4096, features: features)},
      byteSize: 0,
    );
    final theme = const ThemeReader().read({
      'layers': [
        {
          'id': 'city',
          'type': 'symbol',
          'source': 's',
          'source-layer': 'place',
          'filter': [
            '==',
            ['get', 'class'],
            'city'
          ],
          'layout': {'text-field': '{name}'},
        },
      ],
    });
    List<String> texts(TileKey displayKey) => [
          for (final instance in SymbolLayouter.layout(
            theme: theme,
            data: DisplayTileData(displayKey: displayKey, sources: {'s': tile}),
            styleZoom: displayKey.z.toDouble(),
          ))
            instance.text,
        ];

    expect(texts(_dataKey), ['München', 'Augsburg', 'Ingolstadt']);
    expect(_classReads, features.length);
    // The north-west quarter holds München only.
    expect(texts(const TileKey(15, 16000, 10000)), ['München']);
    expect(_classReads, features.length,
        reason: 'a second display tile reuses the matches');

    // Forced through the per-display-tile path, the result is the same.
    theme.layers.single.filterReadsZoom = true;
    expect(texts(_dataKey), ['München', 'Augsburg', 'Ingolstadt']);
    expect(_classReads, 2 * features.length);
  });
}
