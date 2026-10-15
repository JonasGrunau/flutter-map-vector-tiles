import 'dart:typed_data';

import 'package:flutter_map_vector_tiles/src/core/tile_key.dart';
import 'package:flutter_map_vector_tiles/src/pipeline/prepared_tile.dart';
import 'package:flutter_map_vector_tiles/src/render/display_tile_data.dart';
import 'package:flutter_map_vector_tiles/src/render/tile_rasterizer.dart';
import 'package:flutter_map_vector_tiles/src/style/theme.dart';
import 'package:flutter_map_vector_tiles/src/style/theme_reader.dart';
import 'package:flutter_test/flutter_test.dart';

/// One square whose left edge sits at x = 63.5 logical px, which at an
/// odd device pixel ratio is the centre of a pixel column — so a one
/// pixel outline covers exactly that column. Its feature carries `o`
/// for a per-feature `fill-opacity`.
DisplayTileData _squareTile() {
  final tile = PreparedTile(
    key: const TileKey(2, 1, 1),
    layers: {
      'building': PreparedSourceLayer(extent: 4096, features: [
        PreparedFeature(
          id: 1,
          type: PreparedGeomType.polygon,
          parts: [
            Float32List.fromList(
                [1016, 1016, 3072, 1016, 3072, 3072, 1016, 3072]),
          ],
          properties: {'o': 0.5},
        ),
      ]),
    },
    byteSize: 100,
  );
  return DisplayTileData(
      displayKey: const TileKey(2, 1, 1), sources: {'s': tile});
}

Theme _theme(Map<String, Object?> paint) => const ThemeReader().read({
      'layers': [
        {
          'id': 'bg',
          'type': 'background',
          'paint': {'background-color': '#ffffff'},
        },
        {
          'id': 'b',
          'type': 'fill',
          'source': 's',
          'source-layer': 'building',
          'paint': paint,
        },
      ],
    });

/// The grey levels, halfway down the square, of the pixel column the
/// left edge runs through and of its neighbours on either side.
Future<({int outside, int edge, int inside})> _greys(Theme theme,
    {double devicePixelRatio = 3}) async {
  final image = TileRasterizer.rasterize(
    theme: theme,
    data: _squareTile(),
    styleZoom: 2,
    devicePixelRatio: devicePixelRatio,
  )!;
  final data = (await image.toByteData())!;
  final x = (63.5 * devicePixelRatio).floor();
  final y = (128 * devicePixelRatio).floor();
  int greyAt(int x) => data.getUint8((y * image.width + x) * 4);
  final greys =
      (outside: greyAt(x - 1), edge: greyAt(x), inside: greyAt(x + 1));
  image.dispose();
  return greys;
}

/// The grey level of the edge column alone.
Future<int> _edge(Theme theme) async => (await _greys(theme)).edge;

Matcher _near(int grey) => inInclusiveRange(grey - 2, grey + 2);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // A white fill over a white background, so only the black outline
  // shows: its grey level is 255 × (1 − outline alpha).

  test('fill-opacity dims fill-outline-color, as MapLibre does', () async {
    final edge = await _edge(_theme({
      'fill-color': '#ffffff',
      'fill-opacity': 0.5,
      'fill-outline-color': '#000000',
    }));
    expect(edge, _near(128));
  });

  test('a per-feature fill-opacity multiplies the outline colour alpha',
      () async {
    // Mapbox Streets' buildings in miniature: 0.5 × 0.5 = 0.25.
    final edge = await _edge(_theme({
      'fill-color': '#ffffff',
      'fill-opacity': ['get', 'o'],
      'fill-outline-color': 'rgba(0, 0, 0, 0.5)',
    }));
    expect(edge, _near(191));
  });

  test('a fill-opacity reading the feature id is evaluated per feature',
      () async {
    // `["id"]` names no property, so the layer's referenced properties
    // stay empty although the opacity differs from feature to feature.
    final edge = await _edge(_theme({
      'fill-color': '#ffffff',
      'fill-opacity': [
        'case',
        [
          '==',
          ['id'],
          1
        ],
        0.5,
        0,
      ],
      'fill-outline-color': '#000000',
    }));
    expect(edge, _near(128));
  });

  test('a fill-opacity of 0 hides the outline', () async {
    final edge = await _edge(_theme({
      'fill-color': '#ffffff',
      'fill-opacity': 0,
      'fill-outline-color': '#000000',
    }));
    expect(edge, 255);
  });

  test('the alpha of fill-color leaves the outline alone', () async {
    final edge = await _edge(_theme({
      'fill-color': 'rgba(255, 255, 255, 0)',
      'fill-outline-color': '#000000',
    }));
    expect(edge, _near(0));
  });

  for (final ratio in [1.0, 3.0]) {
    test('the outline is one device pixel wide at a pixel ratio of $ratio',
        () async {
      final greys = await _greys(
        _theme({
          'fill-color': '#ffffff',
          'fill-outline-color': '#000000',
        }),
        devicePixelRatio: ratio,
      );
      expect(greys.edge, _near(0));
      expect(greys.outside, _near(255));
      expect(greys.inside, _near(255));
    });
  }

  test('fill-antialias: false turns the outline off, as the spec says',
      () async {
    final edge = await _edge(_theme({
      'fill-color': '#ffffff',
      'fill-outline-color': '#000000',
      'fill-antialias': false,
    }));
    expect(edge, 255);
  });
}
