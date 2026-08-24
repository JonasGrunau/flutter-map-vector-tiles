import 'package:flutter/material.dart' hide Theme;
import 'package:flutter_map_vector_tiles/flutter_map_vector_tiles.dart';
import 'package:flutter_test/flutter_test.dart';

/// Bytes one finished display tile costs at [dpr] — the same
/// `(256·dpr)²·4` the cache accounts with.
double _tileBytes(double dpr) => (256 * dpr) * (256 * dpr) * 4;

void main() {
  group('automatic raster cache sizing', () {
    test('holds more than two screenfuls at dpr 3 on a large phone', () {
      // The case the fixed 64 MiB default got wrong: one level alone is
      // ~80 MiB here, so the old budget could not hold the level a zoom
      // round trip was returning to.
      const viewport = Size(430, 932);
      final bytes = VectorTileLayer.autoRasterCacheBytesFor(viewport, 3);
      // 5 x 7 tiles including the buffer ring.
      final perLevel = 5 * 7 * _tileBytes(3);
      expect(perLevel, greaterThan(64 * 1024 * 1024),
          reason: 'one level really does exceed the old fixed default');
      expect(bytes / perLevel, greaterThan(2),
          reason: 'a round trip must not evict the level it returns to');
      expect(bytes, greaterThan(64 * 1024 * 1024));
    });

    test('scales with the device pixel ratio', () {
      const viewport = Size(430, 932);
      final at2 = VectorTileLayer.autoRasterCacheBytesFor(viewport, 2);
      final at3 = VectorTileLayer.autoRasterCacheBytesFor(viewport, 3);
      expect(at3, greaterThan(at2),
          reason: 'a dpr-3 tile costs 2.25x a dpr-2 one');
    });

    test('scales with the viewport at a fixed dpr', () {
      final phone =
          VectorTileLayer.autoRasterCacheBytesFor(const Size(390, 844), 2);
      final tablet =
          VectorTileLayer.autoRasterCacheBytesFor(const Size(1024, 1366), 2);
      expect(tablet, greaterThan(phone),
          reason: 'a tablet screenful is more tiles than a phone one');
    });

    test('clamps into a sane range at both extremes', () {
      // A map in a small card must still cache enough to survive a
      // crossing…
      final tiny =
          VectorTileLayer.autoRasterCacheBytesFor(const Size(120, 120), 1);
      expect(tiny, 64 * 1024 * 1024);
      // …and a large desktop window must not pin unbounded GPU memory.
      final huge =
          VectorTileLayer.autoRasterCacheBytesFor(const Size(3840, 2160), 3);
      expect(huge, 256 * 1024 * 1024);
    });

    test('is monotonic in viewport size', () {
      var previous = 0;
      for (final h in [400.0, 800.0, 1200.0, 1600.0]) {
        final bytes = VectorTileLayer.autoRasterCacheBytesFor(Size(400, h), 3);
        expect(bytes, greaterThanOrEqualTo(previous));
        previous = bytes;
      }
    });
  });

  group('the sentinel', () {
    test('is negative, so zero still means disabled', () {
      expect(VectorTileLayer.autoRasterCacheBytes, lessThan(0));
    });

    testWidgets('is the default', (tester) async {
      const layer = VectorTileLayer(
        theme: Theme(id: 't', layers: []),
        tileProviders: TileProviders({}),
      );
      expect(layer.rasterCacheMaxBytes, VectorTileLayer.autoRasterCacheBytes);
    });

    testWidgets('an explicit budget still wins', (tester) async {
      const layer = VectorTileLayer(
        theme: Theme(id: 't', layers: []),
        tileProviders: TileProviders({}),
        rasterCacheMaxBytes: 12345,
      );
      expect(layer.rasterCacheMaxBytes, 12345);
    });
  });
}
