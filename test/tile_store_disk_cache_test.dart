@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_map_vector_tiles/src/cache/disk_cache.dart';
import 'package:flutter_map_vector_tiles/src/core/cancellation.dart';
import 'package:flutter_map_vector_tiles/src/core/tile_key.dart';
import 'package:flutter_map_vector_tiles/src/grid/tile_store.dart';
import 'package:flutter_map_vector_tiles/src/pipeline/executor/executor.dart';
import 'package:flutter_map_vector_tiles/src/provider/vector_tile_provider.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/mvt_builder.dart';

/// Simulates being offline: every load fails.
class _FailingProvider extends VectorTileProvider {
  @override
  int get maximumZoom => 14;
  @override
  int get minimumZoom => 0;
  @override
  String get cacheKey => 'failing';

  @override
  Future<TileResponse> load(TileKey tile,
          {CancellationToken? cancellation}) async =>
      TileResponseError(Exception('offline'));
}

/// Serves tiles and records how often it was asked to.
class _CountingProvider extends VectorTileProvider {
  var loads = 0;

  @override
  int get maximumZoom => 14;
  @override
  int get minimumZoom => 0;
  @override
  String get cacheKey => 'counting';

  @override
  Future<TileResponse> load(TileKey tile,
      {CancellationToken? cancellation}) async {
    loads++;
    return TileResponseData(_tileBytes());
  }
}

Uint8List _tileBytes() => MvtTileBuilder()
    .layer('water')
    .feature(type: 3, geometry: [
      cmd(1, 1), zig(0), zig(0), //
      cmd(2, 3), zig(100), zig(0), zig(0), zig(100), zig(-100), zig(0),
      cmd(7, 1),
    ], properties: {
      'class': 'lake',
      'name': 'Ammersee'
    })
    .done()
    .build();

void main() {
  late TilePrepareExecutor executor;

  setUp(() {
    executor = TilePrepareExecutor(concurrency: 1);
    // Decoded tiles are shared process-wide and deliberately outlive
    // dispose(), so without this each test would start on the previous
    // test's cache.
    TileStore.clearMemoryCaches();
  });
  tearDown(() => executor.dispose());

  test('network failure serves an expired disk cache entry', () async {
    final dir = await Directory.systemTemp.createTemp('fmvt_stale');
    try {
      final cache =
          DiskCache(directory: dir, ttl: const Duration(milliseconds: 1));
      await cache.initialize();
      await cache.put('failing/2/1/1', _tileBytes());
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final s = TileStore(
        provider: _FailingProvider(),
        executor: executor,
        layerProperties: {
          'water': {'class'},
        },
        diskCache: Future.value(cache),
      );
      final tile = await s.obtain(const TileKey(2, 1, 1));
      expect(tile, isNotNull);
      expect(tile!.layers.keys, ['water']);
      s.dispose();
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('a disk cache that resolves late is awaited, not raced past', () async {
    final dir = await Directory.systemTemp.createTemp('fmvt_race');
    try {
      final cache = DiskCache(directory: dir);
      await cache.initialize();
      await cache.put('counting/2/1/1', _tileBytes());

      final provider = _CountingProvider();
      final s = TileStore(
        provider: provider,
        executor: executor,
        layerProperties: {
          'water': {'class'},
        },
        // Resolves several event-loop turns late, exactly like the real
        // cache waiting on a platform channel while the first frame is
        // already asking for tiles.
        diskCache:
            Future.delayed(const Duration(milliseconds: 20), () => cache),
      );

      final tile = await s.obtain(const TileKey(2, 1, 1));
      expect(tile, isNotNull);
      expect(provider.loads, 0, reason: 'the tile was already on disk');
      s.dispose();
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('network failure without any cache entry resolves null', () async {
    final dir = await Directory.systemTemp.createTemp('fmvt_stale');
    try {
      final cache = DiskCache(directory: dir);
      await cache.initialize();
      final s = TileStore(
        provider: _FailingProvider(),
        executor: executor,
        layerProperties: {
          'water': {'class'},
        },
        diskCache: Future.value(cache),
      );
      expect(await s.obtain(const TileKey(2, 1, 1)), null);
      s.dispose();
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
