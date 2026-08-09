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
  final picture = recorder.endRecording();
  final image = picture.toImageSync(16, 16);
  picture.dispose();
  return SpriteAtlas(
    image: image,
    sprites: const {
      'chevron': Sprite(x: 0, y: 0, width: 8, height: 8, pixelRatio: 2),
    },
    pixelRatio: 2,
  );
}

/// A horizontal line across the middle of the tile.
DisplayTileData _lineTile() {
  final tile = PreparedTile(
    key: const TileKey(2, 1, 1),
    layers: {
      'roads': PreparedSourceLayer(extent: 4096, features: [
        PreparedFeature(
          id: 1,
          type: PreparedGeomType.line,
          parts: [
            Float32List.fromList([0, 2048, 4096, 2048]),
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

Theme _theme(String pattern, {Map<String, Object?> extraPaint = const {}}) =>
    const ThemeReader().read({
      'layers': [
        {
          'id': 'r',
          'type': 'line',
          'source': 's',
          'source-layer': 'roads',
          'paint': {
            'line-pattern': pattern,
            'line-width': 8,
            ...extraPaint,
          },
        },
      ],
    });

Future<Color> _pixel(ui.Image image, int x, int y) async {
  final data = (await image.toByteData())!;
  final offset = (y * image.width + x) * 4;
  return Color.fromARGB(
    data.getUint8(offset + 3),
    data.getUint8(offset),
    data.getUint8(offset + 1),
    data.getUint8(offset + 2),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('theme reader parses line-pattern', () {
    final layer = _theme('chevron').layers.single as LineThemeLayer;
    expect(layer.pattern, isNotNull);
    expect(layer.pattern!.eval(const EvalContext(zoom: 10)), 'chevron');
  });

  test('rasterizer stamps the pattern along the line', () async {
    final atlas = _atlas();
    final resolver = PatternResolver(atlas);
    final image = TileRasterizer.rasterize(
      theme: _theme('chevron'),
      data: _lineTile(),
      styleZoom: 2,
      devicePixelRatio: 1,
      patterns: resolver,
    );
    expect(image, isNotNull);
    // Stamps are 8px tall, centred on the line at y=128, and repeat
    // gaplessly along it — the pixel on the line must be sprite-red.
    final onLine = await _pixel(image!, 128, 128);
    expect(onLine, const Color(0xffff0000));
    // Well off the line stays untouched.
    final offLine = await _pixel(image, 128, 20);
    expect(offLine.a, 0);
    image.dispose();
    resolver.dispose();
    atlas.dispose();
  });

  test('line-pattern disables the dash array', () async {
    final atlas = _atlas();
    final resolver = PatternResolver(atlas);
    final image = TileRasterizer.rasterize(
      theme: _theme('chevron', extraPaint: {
        'line-dasharray': [1, 10],
      }),
      data: _lineTile(),
      styleZoom: 2,
      devicePixelRatio: 1,
      patterns: resolver,
    );
    expect(image, isNotNull);
    // With the dash array (1px on, 80px off) most of the line would be
    // empty; the pattern ignores it, so mid-gap pixels are still red.
    expect(await _pixel(image!, 100, 128), const Color(0xffff0000));
    expect(await _pixel(image, 200, 128), const Color(0xffff0000));
    image.dispose();
    resolver.dispose();
    atlas.dispose();
  });

  test('missing pattern sprite falls back to color stroke', () async {
    final atlas = _atlas();
    final resolver = PatternResolver(atlas);
    final image = TileRasterizer.rasterize(
      theme: _theme('does-not-exist', extraPaint: {'line-color': '#00ff00'}),
      data: _lineTile(),
      styleZoom: 2,
      devicePixelRatio: 1,
      patterns: resolver,
    );
    expect(image, isNotNull);
    expect(await _pixel(image!, 128, 128), const Color(0xff00ff00));
    image.dispose();
    resolver.dispose();
    atlas.dispose();
  });

  test('no resolver: pattern layer falls back to color stroke', () {
    final recorder = ui.PictureRecorder();
    final painted = TileRasterizer.paint(
      canvas: Canvas(recorder),
      theme: _theme('chevron'),
      data: _lineTile(),
      styleZoom: 2,
    );
    recorder.endRecording().dispose();
    expect(painted, true);
  });
}
