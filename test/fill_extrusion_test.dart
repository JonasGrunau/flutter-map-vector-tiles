import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_map_vector_tiles/src/core/tile_key.dart';
import 'package:flutter_map_vector_tiles/src/pipeline/prepared_tile.dart';
import 'package:flutter_map_vector_tiles/src/render/display_tile_data.dart';
import 'package:flutter_map_vector_tiles/src/render/pattern_resolver.dart';
import 'package:flutter_map_vector_tiles/src/render/tile_rasterizer.dart';
import 'package:flutter_map_vector_tiles/src/style/sprite_atlas.dart';
import 'package:flutter_map_vector_tiles/src/style/theme.dart';
import 'package:flutter_map_vector_tiles/src/style/theme_reader.dart';
import 'package:flutter_test/flutter_test.dart';

/// Two buildings overlapping in the middle third of the tile, the way a
/// building part sits on its outline. Clockwise in y-down tile
/// coordinates, as MVT exterior rings are.
DisplayTileData _overlappingTile() {
  PreparedFeature building(int id, double x0, double x1, String kind) =>
      PreparedFeature(
        id: id,
        type: PreparedGeomType.polygon,
        parts: [
          Float32List.fromList([x0, 1024, x1, 1024, x1, 3072, x0, 3072]),
        ],
        properties: {'kind': kind},
      );
  final tile = PreparedTile(
    key: const TileKey(2, 1, 1),
    layers: {
      'building': PreparedSourceLayer(extent: 4096, features: [
        building(1, 0, 2731, 'outline'),
        building(2, 1365, 4096, 'part'),
      ]),
    },
    byteSize: 100,
  );
  return DisplayTileData(
      displayKey: const TileKey(2, 1, 1), sources: {'s': tile});
}

Theme _theme(String type, Map<String, Object?> paint) =>
    const ThemeReader().read({
      'layers': [
        {
          'id': 'bg',
          'type': 'background',
          'paint': {'background-color': '#ffffff'},
        },
        {
          'id': 'b',
          'type': type,
          'source': 's',
          'source-layer': 'building',
          'paint': paint,
        },
      ],
    });

/// The colour, as `[r, g, b]`, at the three columns that matter: the
/// first building alone, the overlap, and the second building alone.
Future<List<List<int>>> _columns(Theme theme,
    {PatternResolver? patterns}) async {
  final image = TileRasterizer.rasterize(
    theme: theme,
    data: _overlappingTile(),
    styleZoom: 2,
    devicePixelRatio: 1,
    patterns: patterns,
  )!;
  final data = (await image.toByteData())!;
  List<int> rgbAt(int x, int y) {
    final i = (y * image.width + x) * 4;
    return [data.getUint8(i), data.getUint8(i + 1), data.getUint8(i + 2)];
  }

  final columns = [
    for (final x in [40, 128, 220]) rgbAt(x, 128)
  ];
  image.dispose();
  return columns;
}

/// A sprite sheet whose one pattern, `red`, is solid red.
SpriteAtlas _redAtlas() {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(const Rect.fromLTWH(0, 0, 8, 8),
      Paint()..color = const Color(0xffff0000));
  final picture = recorder.endRecording();
  final image = picture.toImageSync(8, 8);
  picture.dispose();
  return SpriteAtlas(
    image: image,
    sprites: const {
      'red': Sprite(x: 0, y: 0, width: 8, height: 8, pixelRatio: 1),
    },
    pixelRatio: 1,
  );
}

Matcher _closeTo(List<int> rgb) => pairwiseCompare<int, int>(
    rgb, (a, b) => (a - b).abs() <= 2, 'within 2 of $rgb');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the reader marks fill-extrusion layers and gives them no outline', () {
    final layer = _theme('fill-extrusion', {
      'fill-extrusion-color': '#000000',
      'fill-outline-color': '#ff0000',
    }).layers.last as FillThemeLayer;
    expect(layer.extrusion, isTrue);
    expect(layer.outlineColor, isNull);
    final fill =
        _theme('fill', {'fill-color': '#000000'}).layers.last as FillThemeLayer;
    expect(fill.extrusion, isFalse);
  });

  test('fill-extrusion-opacity applies to the layer, not to each building',
      () async {
    // MapLibre's building-3d over OpenFreeMap: one colour at 0.8 — here
    // black at 0.5 over white, so a double blend would show as 64.
    final [first, overlap, second] = await _columns(_theme('fill-extrusion', {
      'fill-extrusion-color': '#000000',
      'fill-extrusion-opacity': 0.5,
    }));
    expect(first, _closeTo([128, 128, 128]));
    expect(overlap, _closeTo(first), reason: 'the overlap is blended once');
    expect(second, _closeTo(first));
  });

  test('a colour per building is still blended once, the upper one on top',
      () async {
    final [first, overlap, second] = await _columns(_theme('fill-extrusion', {
      'fill-extrusion-color': [
        'match',
        ['get', 'kind'],
        'outline',
        '#ff0000',
        '#0000ff',
      ],
      'fill-extrusion-opacity': 0.5,
    }));
    expect(first, _closeTo([255, 128, 128]));
    expect(second, _closeTo([128, 128, 255]));
    expect(overlap, _closeTo(second),
        reason: 'the part covers its outline before the layer is blended');
  });

  test('the alpha of fill-extrusion-color is ignored, as the spec says',
      () async {
    // Half-transparent black at full opacity draws opaque black: the
    // opacity is the only translucency an extrusion has.
    final [first, overlap, second] = await _columns(_theme('fill-extrusion', {
      'fill-extrusion-color': 'rgba(0, 0, 0, 0.5)',
    }));
    expect(first, _closeTo([0, 0, 0]));
    expect(overlap, _closeTo([0, 0, 0]));
    expect(second, _closeTo([0, 0, 0]));
  });

  test('a colour per building ignores its alpha too', () async {
    final [first, overlap, second] = await _columns(_theme('fill-extrusion', {
      'fill-extrusion-color': [
        'match',
        ['get', 'kind'],
        'outline',
        'rgba(255, 0, 0, 0.5)',
        'rgba(0, 0, 255, 0)',
      ],
      'fill-extrusion-opacity': 0.5,
    }));
    expect(first, _closeTo([255, 128, 128]));
    expect(second, _closeTo([128, 128, 255]),
        reason: 'a fully transparent colour still draws the building');
    expect(overlap, _closeTo(second));
  });

  test('a patterned extrusion is blended once too', () async {
    final atlas = _redAtlas();
    final patterns = PatternResolver(atlas);
    addTearDown(() {
      patterns.dispose();
      atlas.dispose();
    });
    final [first, overlap, second] = await _columns(
        _theme('fill-extrusion', {
          'fill-extrusion-pattern': 'red',
          'fill-extrusion-opacity': 0.5,
        }),
        patterns: patterns);
    expect(first, _closeTo([255, 128, 128]));
    expect(overlap, _closeTo(first), reason: 'the overlap is blended once');
    expect(second, _closeTo(first));
  });

  test('a plain fill still blends each feature (the control)', () async {
    // What the check above would see without per-layer opacity: the
    // overlap blended twice.
    final [first, overlap, _] = await _columns(_theme('fill', {
      'fill-color': '#000000',
      'fill-opacity': 0.5,
    }));
    expect(first, _closeTo([128, 128, 128]));
    expect(overlap, _closeTo([64, 64, 64]));
  });
}
