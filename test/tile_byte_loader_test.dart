import 'dart:typed_data';

import 'package:flutter_map_vector_tiles/src/cache/byte_cache.dart';
import 'package:flutter_map_vector_tiles/src/core/cancellation.dart';
import 'package:flutter_map_vector_tiles/src/core/tile_key.dart';
import 'package:flutter_map_vector_tiles/src/grid/tile_byte_loader.dart';
import 'package:flutter_map_vector_tiles/src/provider/vector_tile_provider.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryByteCache implements ByteCache {
  final entries = <String, Uint8List>{};

  @override
  Future<Uint8List?> get(String key) async => entries[key];

  @override
  Future<Uint8List?> getStale(String key) async => entries[key];

  @override
  Future<void> put(String key, Uint8List bytes) async {
    entries[key] = bytes;
  }
}

class _CountingProvider extends VectorTileProvider {
  final TileResponse response;
  var loads = 0;

  _CountingProvider(this.response);

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
    return response;
  }
}

void main() {
  const key = TileKey(3, 1, 2);

  Future<TileBytesResult> loadOnce(TileByteLoader loader) =>
      loader.load(key, CancellationToken.none, () => false);

  test('not-found answers are persisted as a sentinel and served from disk',
      () async {
    final cache = _MemoryByteCache();
    final provider = _CountingProvider(const TileResponseNotFound());
    final loader = TileByteLoader(provider, Future.value(cache));

    expect(await loadOnce(loader), isA<TileBytesAbsent>());
    expect(provider.loads, 1);
    await pumpEventQueue(); // let the unawaited sentinel write land
    expect(cache.entries.values.single, isEmpty);

    // A fresh loader (new session) answers from the sentinel without
    // touching the provider.
    final second = TileByteLoader(provider, Future.value(cache));
    expect(await loadOnce(second), isA<TileBytesAbsent>());
    expect(provider.loads, 1);
  });

  test('a stale sentinel answers absent when the network fails', () async {
    final cache = _MemoryByteCache();
    cache.entries['counting/3/1/2'] = Uint8List(0);
    final failing = _CountingProvider(TileResponseError(Exception('offline')));
    final loader = TileByteLoader(failing, Future.value(cache));

    // Simulate an expired entry: fresh get misses, stale get hits.
    final expired = _ExpiredCache(cache);
    final expiredLoader = TileByteLoader(failing, Future.value(expired));
    expect(await loadOnce(expiredLoader), isA<TileBytesAbsent>());

    // And a fresh sentinel short-circuits before the provider entirely.
    expect(await loadOnce(loader), isA<TileBytesAbsent>());
  });

  test('data responses still round-trip unchanged', () async {
    final cache = _MemoryByteCache();
    final bytes = Uint8List.fromList([1, 2, 3]);
    final provider = _CountingProvider(TileResponseData(bytes));
    final loader = TileByteLoader(provider, Future.value(cache));

    final result = await loadOnce(loader);
    expect(result, isA<TileBytesLoaded>());
    expect((result as TileBytesLoaded).bytes, bytes);
  });
}

/// Wraps a cache so [get] always misses (as if past the TTL) while
/// [getStale] still serves the entry.
class _ExpiredCache implements ByteCache {
  final ByteCache inner;
  _ExpiredCache(this.inner);

  @override
  Future<Uint8List?> get(String key) async => null;

  @override
  Future<Uint8List?> getStale(String key) => inner.getStale(key);

  @override
  Future<void> put(String key, Uint8List bytes) => inner.put(key, bytes);
}
