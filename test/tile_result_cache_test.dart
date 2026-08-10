import 'dart:ui' as ui;

import 'package:flutter/material.dart' hide Theme;
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_vector_tiles/flutter_map_vector_tiles.dart';
import 'package:flutter_map_vector_tiles/src/grid/tile_result_cache.dart';
import 'package:flutter_map_vector_tiles/src/render/symbol_layouter.dart'
    hide SymbolInstance;
import 'package:flutter_map_vector_tiles/src/render/tile_rasterizer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'fixtures/lifecycle_harness.dart';

ui.Image _image(int size) {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    ui.Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
    ui.Paint()..color = const ui.Color(0xff00ff00),
  );
  final picture = recorder.endRecording();
  final image = picture.toImageSync(size, size);
  picture.dispose();
  return image;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TileResultCache', () {
    test('a handed-out clone survives eviction of the master', () {
      final cache = TileResultCache.forSignature('t-clone', 10 * 1024 * 1024);
      addTearDown(cache.clear);
      cache.put(const TileKey(1, 0, 0),
          image: _image(4), symbols: const [], renderedWith: const {'s'});

      final entry = cache.get(const TileKey(1, 0, 0))!;
      final clone = entry.image!.clone();
      cache.clear(); // disposes the master
      expect(clone.debugDisposed, isFalse);
      expect(clone.width, 4);
      clone.dispose();
    });

    test('byte accounting evicts oldest entries past the budget', () {
      // 8x8 RGBA = 256 bytes + 64 overhead per entry; budget fits two.
      final cache = TileResultCache.forSignature('t-bytes', 700);
      addTearDown(cache.clear);
      for (var x = 0; x < 3; x++) {
        cache.put(TileKey(2, x, 0),
            image: _image(8), symbols: const [], renderedWith: const {});
      }
      expect(cache.length, 2);
      expect(cache.get(const TileKey(2, 0, 0)), isNull, reason: 'evicted');
      expect(cache.get(const TileKey(2, 2, 0)), isNotNull);
    });

    test('a zero budget stores nothing and disposes the offered image', () {
      final cache = TileResultCache.forSignature('t-off', 0);
      final image = _image(4);
      cache.put(const TileKey(1, 1, 1),
          image: image, symbols: const [], renderedWith: const {});
      expect(cache.length, 0);
      expect(image.debugDisposed, isTrue);
    });

    test('removeWhere invalidates matching keys only', () {
      final cache = TileResultCache.forSignature('t-rm', 10 * 1024 * 1024);
      addTearDown(cache.clear);
      for (var x = 0; x < 3; x++) {
        cache.put(TileKey(3, x, 0),
            image: _image(4), symbols: const [], renderedWith: const {});
      }
      cache.removeWhere((key) => key.x == 1);
      expect(cache.get(const TileKey(3, 1, 0)), isNull);
      expect(cache.get(const TileKey(3, 0, 0)), isNotNull);
      expect(cache.get(const TileKey(3, 2, 0)), isNotNull);
    });

    test('forSignature shares one cache per signature, latest budget wins', () {
      final a = TileResultCache.forSignature('t-shared', 1024);
      final b = TileResultCache.forSignature('t-shared', 2048);
      expect(identical(a, b), isTrue);
      expect(
          identical(a, TileResultCache.forSignature('t-other', 1024)), isFalse);
    });
  });

  group('zoom round-trip', () {
    Theme labelledTheme() => const ThemeReader().read({
          'name': 'result-cache-test',
          'layers': [
            {
              'id': 'bg',
              'type': 'background',
              'paint': {'background-color': '#0000ff'},
            },
            {
              'id': 'land',
              'type': 'fill',
              'source': 's',
              'source-layer': 'land',
              'paint': {'fill-color': '#ff0000'},
            },
            {
              // Exercises the symbol phase without painting glyphs over
              // the sampled centre pixel.
              'id': 'poi',
              'type': 'symbol',
              'source': 's',
              'source-layer': 'land',
              'layout': {'text-field': 'X'},
              'paint': {'text-opacity': 0},
            },
          ],
        });

    testWidgets('returning to a zoom level re-renders nothing', (tester) async {
      final controller = MapController();
      final provider = EverywhereProvider(fullTile());
      await tester.pumpWidget(MaterialApp(
        home: RepaintBoundary(
          key: boundaryKey,
          child: FlutterMap(
            mapController: controller,
            options: const MapOptions(
              initialCenter: LatLng(48.1725, 11.7375),
              initialZoom: 14,
            ),
            children: [
              VectorTileLayer(
                theme: labelledTheme(),
                tileProviders: TileProviders({'s': provider}),
                tileOffset: TileOffset.none,
                tileFadeDuration: Duration.zero,
                labelFadeDuration: Duration.zero,
                concurrency: 1,
                diskCacheMaximumSizeInBytes: 0,
              ),
            ],
          ),
        ),
      ));
      // `settle` returns at first paint; keep pumping so the buffer
      // ring finishes too — only *finished* tiles enter the cache.
      await settle(tester);
      await sampleDuring(tester, frames: 40);
      expect(await centrePixel(tester), land);

      controller.move(const LatLng(48.1725, 11.7375), 13);
      await settle(tester);
      await sampleDuring(tester, frames: 40);
      expect(await centrePixel(tester), land);

      final rasterized = TileRasterizer.debugRasterizeCount;
      final laidOut = SymbolLayouter.debugLayoutCount;

      controller.move(const LatLng(48.1725, 11.7375), 14);
      await settle(tester);
      expect(await centrePixel(tester), land);
      expect(TileRasterizer.debugRasterizeCount, rasterized,
          reason: 'the level-14 tiles must come from the result cache');
      expect(SymbolLayouter.debugLayoutCount, laidOut,
          reason: 'symbol extraction must come from the result cache too');
    });
  });
}
