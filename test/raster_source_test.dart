import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_map_vector_tiles/src/core/tile_key.dart';
import 'package:flutter_map_vector_tiles/src/grid/raster_tile_store.dart';
import 'package:flutter_map_vector_tiles/src/provider/memory_vector_tile_provider.dart';
import 'package:flutter_map_vector_tiles/src/render/display_tile_data.dart';
import 'package:flutter_map_vector_tiles/src/render/tile_rasterizer.dart';
import 'package:flutter_map_vector_tiles/src/style/expression.dart';
import 'package:flutter_map_vector_tiles/src/style/style_reader.dart';
import 'package:flutter_map_vector_tiles/src/style/theme.dart';
import 'package:flutter_map_vector_tiles/src/style/theme_reader.dart';
import 'package:flutter_map_vector_tiles/src/tile_providers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A 4-quadrant test image: red / green / blue / yellow.
ui.Image _quadImage(int size) {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final half = size / 2;
  canvas.drawRect(Rect.fromLTWH(0, 0, half, half),
      Paint()..color = const Color(0xffff0000));
  canvas.drawRect(Rect.fromLTWH(half, 0, half, half),
      Paint()..color = const Color(0xff00ff00));
  canvas.drawRect(Rect.fromLTWH(0, half, half, half),
      Paint()..color = const Color(0xff0000ff));
  canvas.drawRect(Rect.fromLTWH(half, half, half, half),
      Paint()..color = const Color(0xffffff00));
  final picture = recorder.endRecording();
  final image = picture.toImageSync(size, size);
  picture.dispose();
  return image;
}

Theme _rasterTheme({Map<String, Object?> paint = const {}}) =>
    const ThemeReader().read({
      'layers': [
        {'id': 'sat', 'type': 'raster', 'source': 'r', 'paint': paint},
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

  test('theme reader compiles raster layers', () {
    final theme = _rasterTheme(paint: {'raster-opacity': 0.5});
    final layer = theme.layers.single as RasterThemeLayer;
    expect(layer.source, 'r');
    expect(layer.opacity.eval(const EvalContext(zoom: 10)), 0.5);
  });

  test('hillshade/heatmap/sky layers are still skipped', () {
    final theme = const ThemeReader().read({
      'layers': [
        {'id': 'h', 'type': 'hillshade', 'source': 'dem'},
        {'id': 'x', 'type': 'sky'},
      ],
    });
    expect(theme.layers, isEmpty);
  });

  test('rasterizer draws the raster tile', () async {
    final data = DisplayTileData(
      displayKey: const TileKey(2, 1, 1),
      sources: const {},
      rasters: {'r': RasterTile(const TileKey(2, 1, 1), _quadImage(64))},
    );
    final image = TileRasterizer.rasterize(
      theme: _rasterTheme(),
      data: data,
      styleZoom: 2,
      devicePixelRatio: 1,
    );
    expect(image, isNotNull);
    expect(await _pixel(image!, 64, 64), const Color(0xffff0000));
    expect(await _pixel(image, 192, 64), const Color(0xff00ff00));
    expect(await _pixel(image, 64, 192), const Color(0xff0000ff));
    expect(await _pixel(image, 192, 192), const Color(0xffffff00));
    image.dispose();
    data.rasters['r']!.dispose();
  });

  test('overzoomed display tile draws the correct sub-region', () async {
    // Display tile (3,3,2) is the top-right child of data tile (2,1,1):
    // only the green quadrant of the image should appear.
    final data = DisplayTileData(
      displayKey: const TileKey(3, 3, 2),
      sources: const {},
      rasters: {'r': RasterTile(const TileKey(2, 1, 1), _quadImage(64))},
    );
    final image = TileRasterizer.rasterize(
      theme: _rasterTheme(),
      data: data,
      styleZoom: 3,
      devicePixelRatio: 1,
    );
    expect(image, isNotNull);
    expect(await _pixel(image!, 128, 128), const Color(0xff00ff00));
    expect(await _pixel(image, 20, 235), const Color(0xff00ff00));
    image.dispose();
    data.rasters['r']!.dispose();
  });

  test('raster-opacity 0 paints nothing', () {
    final data = DisplayTileData(
      displayKey: const TileKey(2, 1, 1),
      sources: const {},
      rasters: {'r': RasterTile(const TileKey(2, 1, 1), _quadImage(64))},
    );
    final image = TileRasterizer.rasterize(
      theme: _rasterTheme(paint: {'raster-opacity': 0}),
      data: data,
      styleZoom: 2,
      devicePixelRatio: 1,
    );
    expect(image, isNull);
    data.rasters['r']!.dispose();
  });

  test('raster-saturation -1 renders grayscale', () async {
    final data = DisplayTileData(
      displayKey: const TileKey(2, 1, 1),
      sources: const {},
      rasters: {'r': RasterTile(const TileKey(2, 1, 1), _quadImage(64))},
    );
    final image = TileRasterizer.rasterize(
      theme: _rasterTheme(paint: {'raster-saturation': -1}),
      data: data,
      styleZoom: 2,
      devicePixelRatio: 1,
    );
    expect(image, isNotNull);
    final c = await _pixel(image!, 64, 64);
    expect(c.r, closeTo(c.g, 2 / 255));
    expect(c.g, closeTo(c.b, 2 / 255));
    expect(c.r, lessThan(0.5)); // pure red collapses to its average, ~85

    image.dispose();
    data.rasters['r']!.dispose();
  });

  group('RasterTileStore', () {
    RasterTileSource source({int tileSize = 512, int min = 0, int max = 20}) =>
        RasterTileSource(
          provider: MemoryVectorTileProvider(
              tiles: {}, minimumZoom: min, maximumZoom: max),
          tileSize: tileSize,
        );

    test('dataKeyFor honors tileSize and zoom offset', () {
      const display = TileKey(10, 300, 300);
      // 512px source with the MapLibre offset: one level up.
      expect(RasterTileStore(source: source()).dataKeyFor(display, -1),
          const TileKey(9, 150, 150));
      // 256px source with the MapLibre offset: same level.
      expect(
          RasterTileStore(source: source(tileSize: 256))
              .dataKeyFor(display, -1),
          const TileKey(10, 300, 300));
      // 256px source without offset would need underzoom: upscale instead.
      expect(
          RasterTileStore(source: source(tileSize: 256)).dataKeyFor(display, 0),
          const TileKey(10, 300, 300));
      // Beyond source maxzoom: overzoom the deepest level.
      expect(RasterTileStore(source: source(max: 5)).dataKeyFor(display, -1),
          const TileKey(5, 9, 9));
      // Below source minzoom: unusable.
      expect(RasterTileStore(source: source(min: 14)).dataKeyFor(display, -1),
          isNull);
    });

    test('obtain decodes bytes and hands out independent clones', () async {
      final png =
          await _quadImage(8).toByteData(format: ui.ImageByteFormat.png);
      const key = TileKey(3, 1, 2);
      final store = RasterTileStore(
        source: RasterTileSource(
          provider: MemoryVectorTileProvider(
            tiles: {key: png!.buffer.asUint8List()},
            cacheKey: 'raster-clone-test',
          ),
        ),
      );
      final first = await store.obtain(key);
      expect(first, isNotNull);
      expect(first!.image.width, 8);
      first.dispose();
      // Disposing one handle must not kill the cached master.
      final second = store.peek(key);
      expect(second, isNotNull);
      expect(second!.image.width, 8);
      second.dispose();
      // Missing tiles resolve to null and are remembered.
      expect(await store.obtain(const TileKey(3, 0, 0)), isNull);
      store.dispose();
      RasterTileStore.clearMemoryCaches();
    });

    test('style reader resolves raster sources through TileJSON', () async {
      final client = MockClient((request) async {
        final url = request.url.toString();
        if (url.contains('style.json')) {
          return http.Response(
              jsonEncode({
                'version': 8,
                'name': 'hybrid',
                'sources': {
                  'openmaptiles': {
                    'type': 'vector',
                    'tiles': ['https://tiles.example.com/{z}/{x}/{y}.pbf'],
                    'maxzoom': 14,
                  },
                  'satellite': {
                    'type': 'raster',
                    'url': 'https://tiles.example.com/satellite/tiles.json',
                    'tileSize': 256,
                  },
                },
                'layers': [
                  {'id': 'sat', 'type': 'raster', 'source': 'satellite'},
                ],
              }),
              200);
        }
        if (url.contains('tiles.json')) {
          return http.Response(
              jsonEncode({
                'tiles': ['https://tiles.example.com/sat/{z}/{x}/{y}.jpg'],
                'minzoom': 0,
                'maxzoom': 20,
              }),
              200);
        }
        return http.Response('not found', 404);
      });
      final style = await StyleReader(
        uri: 'https://styles.example.com/hybrid/style.json',
        httpClient: client,
        cache: false,
      ).read();
      final satellite = style.rasterSources['satellite'];
      expect(satellite, isNotNull);
      expect(satellite!.tileSize, 256);
      expect(satellite.provider.maximumZoom, 20);
      expect(satellite.provider.cacheKey,
          'https://tiles.example.com/sat/{z}/{x}/{y}.jpg');
      // The vector source is still there, and a style whose only usable
      // source is raster no longer throws.
      expect(style.providers['openmaptiles'], isNotNull);
      style.dispose();
    });

    test('peekWithAncestors serves a parent for provisional rendering',
        () async {
      final png =
          await _quadImage(8).toByteData(format: ui.ImageByteFormat.png);
      const parent = TileKey(3, 1, 2);
      final store = RasterTileStore(
        source: RasterTileSource(
          provider: MemoryVectorTileProvider(
            tiles: {parent: png!.buffer.asUint8List()},
            cacheKey: 'raster-ancestor-test',
          ),
        ),
      );
      (await store.obtain(parent))!.dispose();
      final tile = store.peekWithAncestors(const TileKey(5, 6, 9));
      expect(tile, isNotNull);
      expect(tile!.key, parent);
      tile.dispose();
      store.dispose();
      RasterTileStore.clearMemoryCaches();
    });
  });
}
