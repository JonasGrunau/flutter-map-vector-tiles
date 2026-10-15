import 'dart:typed_data';

import 'package:flutter_map_vector_tiles/src/core/tile_key.dart';
import 'package:flutter_map_vector_tiles/src/pipeline/prepared_tile.dart';
import 'package:flutter_map_vector_tiles/src/render/display_tile_data.dart';
import 'package:flutter_map_vector_tiles/src/render/tile_rasterizer.dart';
import 'package:flutter_map_vector_tiles/src/style/theme.dart';
import 'package:flutter_map_vector_tiles/src/style/theme_reader.dart';
import 'package:flutter_test/flutter_test.dart';

/// One square in the middle half of the tile, its feature carrying
/// `o` for a per-feature `fill-opacity`.
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
                [1024, 1024, 3072, 1024, 3072, 3072, 1024, 3072]),
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

/// The grey level just outside the square's left edge, where only the
/// outline paints. At 4× the 0.6 px outline is 2.4 device pixels wide,
/// centred on x = 256, so pixel 255 is fully covered by it.
Future<int> _outlineGrey(Theme theme) async {
  final image = TileRasterizer.rasterize(
    theme: theme,
    data: _squareTile(),
    styleZoom: 2,
    devicePixelRatio: 4,
  )!;
  final data = (await image.toByteData())!;
  final grey = data.getUint8((512 * image.width + 255) * 4);
  image.dispose();
  return grey;
}

Matcher _near(int grey) => inInclusiveRange(grey - 2, grey + 2);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // A white fill over a white background, so only the black outline
  // shows: its grey level is 255 × (1 − outline alpha).

  test('fill-opacity dims fill-outline-color, as MapLibre does', () async {
    expect(
      await _outlineGrey(_theme({
        'fill-color': '#ffffff',
        'fill-opacity': 0.5,
        'fill-outline-color': '#000000',
      })),
      _near(128),
    );
  });

  test('a per-feature fill-opacity multiplies the outline colour alpha',
      () async {
    // Mapbox Streets' buildings in miniature: 0.5 × 0.5 = 0.25.
    expect(
      await _outlineGrey(_theme({
        'fill-color': '#ffffff',
        'fill-opacity': ['get', 'o'],
        'fill-outline-color': 'rgba(0, 0, 0, 0.5)',
      })),
      _near(191),
    );
  });

  test('a fill-opacity of 0 hides the outline', () async {
    expect(
      await _outlineGrey(_theme({
        'fill-color': '#ffffff',
        'fill-opacity': 0,
        'fill-outline-color': '#000000',
      })),
      255,
    );
  });

  test('the alpha of fill-color leaves the outline alone', () async {
    expect(
      await _outlineGrey(_theme({
        'fill-color': 'rgba(255, 255, 255, 0)',
        'fill-outline-color': '#000000',
      })),
      _near(0),
    );
  });
}
