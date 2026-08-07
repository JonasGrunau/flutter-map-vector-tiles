import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_map_vector_tiles/src/core/tile_key.dart';
import 'package:flutter_map_vector_tiles/src/pipeline/prepared_tile.dart';
import 'package:flutter_map_vector_tiles/src/render/display_tile_data.dart';
import 'package:flutter_map_vector_tiles/src/render/pattern_resolver.dart';
import 'package:flutter_map_vector_tiles/src/render/tile_rasterizer.dart';
import 'package:flutter_map_vector_tiles/src/style/expression.dart';
import 'package:flutter_map_vector_tiles/src/style/sprite_atlas.dart';
import 'package:flutter_map_vector_tiles/src/style/theme.dart';
import 'package:flutter_map_vector_tiles/src/style/theme_reader.dart';
import 'package:flutter_test/flutter_test.dart';

SpriteAtlas _atlas() {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(const Rect.fromLTWH(0, 0, 8, 8),
      Paint()..color = const Color(0xffff0000));
  canvas.drawRect(const Rect.fromLTWH(8, 8, 8, 8),
      Paint()..color = const Color(0xff00ff00));
  final picture = recorder.endRecording();
  final image = picture.toImageSync(16, 16);
  picture.dispose();
  return SpriteAtlas(
    image: image,
    sprites: const {
      'hatch': Sprite(x: 0, y: 0, width: 8, height: 8, pixelRatio: 2),
      'degenerate': Sprite(x: 0, y: 0, width: 0, height: 8, pixelRatio: 2),
    },
    pixelRatio: 2,
  );
}

DisplayTileData _polygonTile() {
  final tile = PreparedTile(
    key: const TileKey(2, 1, 1),
    layers: {
      'water': PreparedSourceLayer(extent: 4096, features: [
        PreparedFeature(
          id: 1,
          type: PreparedGeomType.polygon,
          parts: [
            Float32List.fromList([0, 0, 4096, 0, 4096, 4096, 0, 4096]),
          ],
          properties: const {},
        ),
      ]),
    },
    byteSize: 100,
  );
  return DisplayTileData(
      displayKey: const TileKey(2, 1, 1), sources: {'s': tile});
}

Theme _theme(String pattern) => const ThemeReader().read({
      'layers': [
        {
          'id': 'w',
          'type': 'fill',
          'source': 's',
          'source-layer': 'water',
          'paint': {'fill-pattern': pattern},
        },
      ],
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('theme reader parses fill-pattern', () {
    final layer = _theme('hatch').layers.single as FillThemeLayer;
    expect(layer.pattern, isNotNull);
    expect(layer.pattern!.eval(const EvalContext(zoom: 10)), 'hatch');
  });

  test('resolver crops, caches and tolerates unknown names', () {
    final atlas = _atlas();
    final resolver = PatternResolver(atlas);
    final image = resolver.imageFor('hatch');
    expect(image, isNotNull);
    expect(image!.width, 8);
    expect(image.height, 8);
    expect(identical(resolver.imageFor('hatch'), image), true);
    expect(resolver.imageFor('nope'), null);
    expect(resolver.imageFor('nope'), null); // cached miss
    expect(resolver.imageFor('degenerate'), null); // zero-size sprite
    resolver.dispose();
    expect(resolver.imageFor('hatch'), null); // safe after dispose
    atlas.dispose();
  });

  test('rasterizer paints pattern fills', () {
    final atlas = _atlas();
    final resolver = PatternResolver(atlas);
    final image = TileRasterizer.rasterize(
      theme: _theme('hatch'),
      data: _polygonTile(),
      styleZoom: 2,
      devicePixelRatio: 1,
      patterns: resolver,
    );
    expect(image, isNotNull);
    image!.dispose();
    resolver.dispose();
    atlas.dispose();
  });

  test('missing pattern sprite falls back to color fill', () {
    final atlas = _atlas();
    final resolver = PatternResolver(atlas);
    final recorder = ui.PictureRecorder();
    final painted = TileRasterizer.paint(
      canvas: Canvas(recorder),
      theme: _theme('does-not-exist'),
      data: _polygonTile(),
      styleZoom: 2,
      patterns: resolver,
    );
    recorder.endRecording().dispose();
    expect(painted, true); // fill-color default painted instead
    resolver.dispose();
    atlas.dispose();
  });

  test('no resolver: pattern layer falls back to color fill', () {
    final recorder = ui.PictureRecorder();
    final painted = TileRasterizer.paint(
      canvas: Canvas(recorder),
      theme: _theme('hatch'),
      data: _polygonTile(),
      styleZoom: 2,
    );
    recorder.endRecording().dispose();
    expect(painted, true);
  });
}
