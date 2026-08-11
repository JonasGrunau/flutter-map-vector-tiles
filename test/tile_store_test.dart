import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_map_vector_tiles/src/cache/byte_cache.dart';
import 'package:flutter_map_vector_tiles/src/core/cancellation.dart';
import 'package:flutter_map_vector_tiles/src/core/tile_key.dart';
import 'package:flutter_map_vector_tiles/src/grid/tile_store.dart';
import 'package:flutter_map_vector_tiles/src/pipeline/executor/executor.dart';
import 'package:flutter_map_vector_tiles/src/pipeline/prepared_tile.dart';
import 'package:flutter_map_vector_tiles/src/provider/memory_vector_tile_provider.dart';
import 'package:flutter_map_vector_tiles/src/provider/vector_tile_provider.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/mvt_builder.dart';

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

Uint8List _riverTileBytes() => MvtTileBuilder()
    .layer('water')
    .feature(type: 3, geometry: [
      cmd(1, 1), zig(0), zig(0), //
      cmd(2, 3), zig(100), zig(0), zig(0), zig(100), zig(-100), zig(0),
      cmd(7, 1),
    ], properties: {
      'class': 'river'
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

  test('memory providers with different data do not share caches', () async {
    // Regression: the default cacheKey was the constant 'memory', so two
    // providers bundling different regions shared the process-wide
    // decoded-tile cache — whichever decoded a key first won, rendering
    // one region's geometry inside the other.
    TileStore storeFor(Uint8List bytes) => TileStore(
          provider: MemoryVectorTileProvider(
            tiles: {const TileKey(2, 1, 1): bytes},
          ),
          executor: executor,
          layerProperties: {
            'water': {'class'},
          },
        );
    final lake = storeFor(_tileBytes());
    final river = storeFor(_riverTileBytes());
    final a = await lake.obtain(const TileKey(2, 1, 1));
    final b = await river.obtain(const TileKey(2, 1, 1));
    expect(a!.layers['water']!.features.single.properties['class'], 'lake');
    expect(b!.layers['water']!.features.single.properties['class'], 'river');
    lake.dispose();
    river.dispose();
  });

  test('clearMemoryCaches reaches tiles decoded after a previous clear',
      () async {
    // Regression: clearing used to also drop the LruCache objects from
    // the static registry while live stores kept filling them — those
    // orphaned entries were unreachable by any later clear.
    final s = store();
    await s.obtain(const TileKey(2, 1, 1));
    TileStore.clearMemoryCaches();
    expect(s.peek(const TileKey(2, 1, 1)), isNull);

    final again = await s.obtain(const TileKey(2, 1, 1));
    expect(again, isNotNull);
    expect(s.peek(const TileKey(2, 1, 1)), isNotNull);

    TileStore.clearMemoryCaches();
    expect(s.peek(const TileKey(2, 1, 1)), isNull,
        reason: 'the refilled cache must still be reachable by clear');
    s.dispose();
  });

  test('memory providers with identical data share the decoded cache', () {
    // The derived key is deterministic, so equal data still shares.
    final tiles = {const TileKey(2, 1, 1): _tileBytes()};
    expect(
      MemoryVectorTileProvider(tiles: tiles).cacheKey,
      MemoryVectorTileProvider(tiles: Map.of(tiles)).cacheKey,
    );
  });

  test('a cancelled waiter does not poison the load for live waiters',
      () async {
    // Regression: coalesced loads used to poll only the FIRST caller's
    // token, so one disposed display tile cancelled the shared load and
    // every live waiter finalized permanently without the tile.
    final gate = Completer<void>();
    final s = TileStore(
      provider: _GatedProvider(gate.future, {
        const TileKey(2, 1, 1): _tileBytes(),
      }),
      executor: executor,
      layerProperties: {
        'water': {'class'},
      },
    );
    final tokenA = CancellationToken();
    final a = s.obtain(const TileKey(2, 1, 1), cancellation: tokenA);
    final b = s.obtain(const TileKey(2, 1, 1)); // coalesces onto a's load
    tokenA.cancel(); // first waiter abandons mid-flight
    gate.complete();
    final tile = await b;
    expect(tile, isNotNull);
    expect(tile!.layers.keys, ['water']);
    // The shared future completed with data for everyone still listening.
    expect(identical(await a, tile), true);
    s.dispose();
  });

  group('stale-while-revalidate', () {
    const dataKey = TileKey(2, 1, 1);

    TileStore swrStore(VectorTileProvider provider, ByteCache cache) =>
        TileStore(
          provider: provider,
          executor: executor,
          layerProperties: {
            'water': {'class'},
          },
          diskCache: Future.value(cache),
        );

    String classOf(PreparedTile? tile) =>
        tile!.layers['water']!.features.single.properties['class']! as String;

    test('an expired entry paints instantly and refreshes to changed data',
        () async {
      final provider = _FixedProvider(TileResponseData(_tileBytes())); // lake
      final cache = _ExpiredByteCache();
      cache.entries['fixed/2/1/1'] = _riverTileBytes();
      final s = swrStore(provider, cache);
      final refreshed = Completer<TileKey>();
      s.onRefreshed = refreshed.complete;

      // The expired entry is served without waiting on the provider…
      final stale = await s.obtain(dataKey);
      expect(classOf(stale), 'river');

      // …and the background revalidation swaps in the fresh content.
      expect(await refreshed.future, dataKey);
      expect(classOf(s.peek(dataKey)), 'lake');
      expect(provider.loads, 1);
      s.dispose();
    });

    test('identical bytes refresh silently', () async {
      final provider = _FixedProvider(TileResponseData(_tileBytes()));
      final cache = _ExpiredByteCache();
      cache.entries['fixed/2/1/1'] = _tileBytes();
      final s = swrStore(provider, cache);
      var notified = false;
      s.onRefreshed = (_) => notified = true;

      expect(await s.obtain(dataKey), isNotNull);
      await pumpEventQueue();
      expect(provider.loads, 1, reason: 'the revalidation did run');
      expect(notified, isFalse, reason: 'but nothing changed');
      expect(cache.puts, 1, reason: 'and the disk entry\'s TTL restarted');
      s.dispose();
    });

    test('a failed revalidation keeps the stale tile servable', () async {
      final provider = _FixedProvider(TileResponseError(Exception('offline')));
      final cache = _ExpiredByteCache();
      cache.entries['fixed/2/1/1'] = _riverTileBytes();
      final s = swrStore(provider, cache);
      var notified = false;
      s.onRefreshed = (_) => notified = true;

      expect(await s.obtain(dataKey), isNotNull);
      await pumpEventQueue();
      expect(notified, isFalse);

      // Not throttled: even once the memory cache drops the tile, the
      // stale disk entry keeps serving.
      TileStore.clearMemoryCaches();
      final again = await s.obtain(dataKey);
      expect(classOf(again), 'river');
      s.dispose();
    });

    test('a corrupt expired entry is refetched instead of poisoning the tile',
        () async {
      final provider = _FixedProvider(TileResponseData(_tileBytes())); // lake
      final cache = _ExpiredByteCache();
      // A torn write: the entry is past its TTL *and* undecodable.
      cache.entries['fixed/2/1/1'] = Uint8List.fromList([0xff, 0xff, 0xff]);
      final s = swrStore(provider, cache);
      final refreshed = Completer<TileKey>();
      s.onRefreshed = refreshed.complete;

      // There is nothing to display, but the revalidation must still
      // run: it is the only thing that rewrites the disk entry, so
      // without it every retry re-reads the same bytes and fails
      // identically for as long as the entry survives.
      expect(await s.obtain(dataKey), isNull);
      expect(await refreshed.future, dataKey);
      expect(classOf(s.peek(dataKey)), 'lake');
      s.dispose();
    });

    test('revalidateIfStale refreshes a tile no longer held in memory',
        () async {
      final provider = _FixedProvider(TileResponseData(_tileBytes())); // lake
      final cache = _ExpiredByteCache();
      cache.entries['fixed/2/1/1'] = _riverTileBytes();
      final s = swrStore(provider, cache);
      final refreshed = Completer<TileKey>();
      s.onRefreshed = refreshed.complete;

      // Stands in for a display tile served from the finished-result
      // cache: it never reaches obtain, so this is the only freshness
      // check its data tile gets.
      s.revalidateIfStale(dataKey);
      expect(await refreshed.future, dataKey);
      expect(classOf(s.peek(dataKey)), 'lake');
      s.dispose();
    });

    test('revalidateIfStale skips a tile already in memory', () async {
      final provider = _FixedProvider(TileResponseData(_tileBytes()));
      final cache = _ExpiredByteCache();
      cache.entries['fixed/2/1/1'] = _riverTileBytes();
      final s = swrStore(provider, cache);
      expect(await s.obtain(dataKey), isNotNull);
      await pumpEventQueue();
      final loads = provider.loads;

      s.revalidateIfStale(dataKey);
      await pumpEventQueue();
      expect(provider.loads, loads,
          reason: 'a tile loaded in this process was checked as it loaded');
      s.dispose();
    });

    test('a tile deleted at the source refreshes to empty', () async {
      final provider = _FixedProvider(const TileResponseNotFound());
      final cache = _ExpiredByteCache();
      cache.entries['fixed/2/1/1'] = _riverTileBytes();
      final s = swrStore(provider, cache);
      final refreshed = Completer<TileKey>();
      s.onRefreshed = refreshed.complete;

      final stale = await s.obtain(dataKey);
      expect(stale!.layers, isNotEmpty);
      expect(await refreshed.future, dataKey);
      expect(s.peek(dataKey)!.layers, isEmpty);
      await pumpEventQueue();
      expect(cache.entries['fixed/2/1/1'], isEmpty,
          reason: 'the absence sentinel replaces the stale data');
      s.dispose();
    });

    test('an expired absence sentinel revalidates into data', () async {
      final provider = _FixedProvider(TileResponseData(_tileBytes()));
      final cache = _ExpiredByteCache();
      cache.entries['fixed/2/1/1'] = Uint8List(0);
      final s = swrStore(provider, cache);
      final refreshed = Completer<TileKey>();
      s.onRefreshed = refreshed.complete;

      final stale = await s.obtain(dataKey);
      expect(stale!.layers, isEmpty); // the sentinel is served first
      expect(await refreshed.future, dataKey);
      expect(s.peek(dataKey)!.layers.keys, ['water']);
      s.dispose();
    });
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
}

/// Serves one fixed response with a stable cache key, counting loads.
class _FixedProvider extends VectorTileProvider {
  final TileResponse response;
  var loads = 0;

  _FixedProvider(this.response);

  @override
  int get maximumZoom => 14;

  @override
  int get minimumZoom => 0;

  @override
  String get cacheKey => 'fixed';

  @override
  Future<TileResponse> load(TileKey tile,
      {CancellationToken? cancellation}) async {
    loads++;
    return response;
  }
}

/// A byte cache whose every entry is past the TTL: fresh [get] always
/// misses, [getStale] serves — the stale-while-revalidate entry state.
class _ExpiredByteCache implements ByteCache {
  final entries = <String, Uint8List>{};
  var puts = 0;

  @override
  Future<Uint8List?> get(String key) async => null;

  @override
  Future<Uint8List?> getStale(String key) async => entries[key];

  @override
  Future<void> put(String key, Uint8List bytes) async {
    puts++;
    entries[key] = bytes;
  }
}

/// Serves tiles only after [gate] completes, so tests can cancel waiters
/// while the load is still in flight.
class _GatedProvider extends VectorTileProvider {
  final Future<void> gate;
  final Map<TileKey, Uint8List> tiles;

  _GatedProvider(this.gate, this.tiles);

  @override
  int get maximumZoom => 14;

  @override
  int get minimumZoom => 0;

  @override
  String get cacheKey => 'gated';

  @override
  Future<TileResponse> load(TileKey tile,
      {CancellationToken? cancellation}) async {
    await gate;
    if (cancellation?.isCancelled ?? false) {
      return const TileResponseCancelled();
    }
    final bytes = tiles[tile];
    return bytes == null
        ? const TileResponseNotFound()
        : TileResponseData(bytes);
  }
}
