import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_map_vector_tiles/src/cache/disk_cache.dart';
import 'package:flutter_map_vector_tiles/src/core/cancellation.dart';
import 'package:flutter_map_vector_tiles/src/core/tile_key.dart';
import 'package:flutter_map_vector_tiles/src/grid/tile_store.dart';
import 'package:flutter_map_vector_tiles/src/pipeline/executor/executor.dart';
import 'package:flutter_map_vector_tiles/src/provider/memory_vector_tile_provider.dart';
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
    .layer('unused_layer')
    .feature(type: 1, geometry: [cmd(1, 1), zig(5), zig(5)])
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

  TileStore store({int maxZoom = 14}) => TileStore(
        provider: MemoryVectorTileProvider(
          tiles: {const TileKey(2, 1, 1): _tileBytes()},
          maximumZoom: maxZoom,
        ),
        executor: executor,
        layerProperties: {
          'water': {'class'},
        },
      );

  test('loads, decodes and trims a tile', () async {
    final s = store();
    final tile = await s.obtain(const TileKey(2, 1, 1));
    expect(tile, isNotNull);
    expect(tile!.layers.keys, ['water']); // unused layer dropped
    final feature = tile.layers['water']!.features.single;
    expect(feature.properties, {'class': 'lake'}); // name trimmed
    s.dispose();
  });

  test('missing tiles resolve as empty, not error', () async {
    final s = store();
    final tile = await s.obtain(const TileKey(2, 0, 0));
    expect(tile, isNotNull);
    expect(tile!.layers, isEmpty);
    s.dispose();
  });

  test('memory cache returns identical instance', () async {
    final s = store();
    final a = await s.obtain(const TileKey(2, 1, 1));
    final b = await s.obtain(const TileKey(2, 1, 1));
    expect(identical(a, b), true);
    expect(s.peek(const TileKey(2, 1, 1)), isNotNull);
    s.dispose();
  });

  test('cancellation resolves null silently', () async {
    final s = store();
    final token = CancellationToken()..cancel();
    final tile = await s.obtain(const TileKey(2, 1, 1), cancellation: token);
    expect(tile, null);
    s.dispose();
  });

  test('dataKeyFor clamps to provider maximum zoom', () {
    final s = store(maxZoom: 2);
    expect(s.dataKeyFor(const TileKey(5, 25, 25), 0), const TileKey(2, 3, 3));
    expect(s.dataKeyFor(const TileKey(2, 1, 1), 0), const TileKey(2, 1, 1));
    s.dispose();
  });

  test('dataKeyFor applies zoom offset and wraps x', () {
    final s = store();
    expect(s.dataKeyFor(const TileKey(5, 8, 8), -1), const TileKey(4, 4, 4));
    expect(s.dataKeyFor(const TileKey(2, -1, 1), 0), const TileKey(2, 3, 1));
    s.dispose();
  });

  test('peekWithAncestors finds a loaded parent', () async {
    final s = store();
    await s.obtain(const TileKey(2, 1, 1));
    final found = s.peekWithAncestors(const TileKey(4, 5, 5));
    expect(found, isNotNull);
    expect(found!.key, const TileKey(2, 1, 1));
    s.dispose();
  });

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

  test('decoded tiles are reused by the next store over the same source',
      () async {
    final first = store();
    final tile = await first.obtain(const TileKey(2, 1, 1));
    first.dispose();

    // Synchronously present, so a reopened map paints without decoding.
    final second = store();
    expect(identical(second.peek(const TileKey(2, 1, 1)), tile), true);
    second.dispose();
  });

  test('stores trimming different properties do not share tiles', () async {
    final trimmed = store();
    await trimmed.obtain(const TileKey(2, 1, 1));
    trimmed.dispose();

    final wider = TileStore(
      provider: MemoryVectorTileProvider(
        tiles: {const TileKey(2, 1, 1): _tileBytes()},
      ),
      executor: executor,
      layerProperties: {
        'water': {'class', 'name'},
      },
    );
    expect(wider.peek(const TileKey(2, 1, 1)), isNull);
    final tile = await wider.obtain(const TileKey(2, 1, 1));
    expect(
      tile!.layers['water']!.features.single.properties,
      {'class': 'lake', 'name': 'Ammersee'},
    );
    wider.dispose();
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
