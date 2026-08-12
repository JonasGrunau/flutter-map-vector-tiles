import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_map_vector_tiles/src/cache/byte_cache.dart';
import 'package:flutter_map_vector_tiles/src/core/cancellation.dart';
import 'package:flutter_map_vector_tiles/src/core/tile_key.dart';
import 'package:flutter_map_vector_tiles/src/grid/tile_byte_loader.dart';
import 'package:flutter_map_vector_tiles/src/provider/vector_tile_provider.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryByteCache implements ByteCache {
  final entries = <String, Uint8List>{};
  var puts = 0;

  @override
  Future<Uint8List?> get(String key) async => entries[key];

  @override
  Future<Uint8List?> getStale(String key) async => entries[key];

  @override
  Future<void> put(String key, Uint8List bytes) async {
    puts++;
    entries[key] = bytes;
  }
}

class _CountingProvider extends VectorTileProvider {
  TileResponse response;
  var loads = 0;

  /// When set, responses are held back until it completes.
  Future<void>? gate;

  @override
  final bool cacheBytesToDisk;

  _CountingProvider(this.response, {this.cacheBytesToDisk = true});

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
    if (gate != null) await gate;
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

  test('an expired sentinel answers absent, stale, without the provider',
      () async {
    final cache = _MemoryByteCache();
    cache.entries['counting/3/1/2'] = Uint8List(0);
    final failing = _CountingProvider(TileResponseError(Exception('offline')));

    // Simulate an expired entry: fresh get misses, stale get hits. The
    // sentinel is served ahead of the network (stale-while-revalidate).
    final expired = _ExpiredCache(cache);
    final expiredLoader = TileByteLoader(failing, Future.value(expired));
    final result = await loadOnce(expiredLoader);
    expect(result, isA<TileBytesAbsent>());
    expect((result as TileBytesAbsent).stale, isTrue);
    expect(failing.loads, 0);

    // And a fresh sentinel short-circuits identically, not stale.
    final loader = TileByteLoader(failing, Future.value(cache));
    final fresh = await loadOnce(loader);
    expect((fresh as TileBytesAbsent).stale, isFalse);
  });

  test('an expired data entry is served stale without the provider', () async {
    final cache = _MemoryByteCache();
    final staleBytes = Uint8List.fromList([9, 9]);
    cache.entries['counting/3/1/2'] = staleBytes;
    final provider =
        _CountingProvider(TileResponseData(Uint8List.fromList([1])));
    final loader = TileByteLoader(provider, Future.value(_ExpiredCache(cache)));

    final result = await loadOnce(loader);
    expect(result, isA<TileBytesLoaded>());
    expect((result as TileBytesLoaded).stale, isTrue);
    expect(result.bytes, staleBytes);
    expect(provider.loads, 0);
  });

  test('data responses still round-trip unchanged', () async {
    final cache = _MemoryByteCache();
    final bytes = Uint8List.fromList([1, 2, 3]);
    final provider = _CountingProvider(TileResponseData(bytes));
    final loader = TileByteLoader(provider, Future.value(cache));

    final result = await loadOnce(loader);
    expect(result, isA<TileBytesLoaded>());
    expect((result as TileBytesLoaded).bytes, bytes);
    expect(result.stale, isFalse);
  });

  group('providers that opt out of disk caching', () {
    test('data responses are not mirrored onto disk', () async {
      final cache = _MemoryByteCache();
      final bytes = Uint8List.fromList([1, 2, 3]);
      final provider =
          _CountingProvider(TileResponseData(bytes), cacheBytesToDisk: false);
      final loader = TileByteLoader(provider, Future.value(cache));

      final result = await loadOnce(loader);
      expect((result as TileBytesLoaded).bytes, bytes);
      expect(result.stale, isFalse);
      await pumpEventQueue(); // a write would land here
      expect(cache.puts, 0);
      expect(cache.entries, isEmpty);
    });

    test('absence leaves no sentinel behind', () async {
      final cache = _MemoryByteCache();
      final provider = _CountingProvider(const TileResponseNotFound(),
          cacheBytesToDisk: false);
      final loader = TileByteLoader(provider, Future.value(cache));

      expect(await loadOnce(loader), isA<TileBytesAbsent>());
      await pumpEventQueue();
      expect(cache.puts, 0);
      expect(cache.entries, isEmpty);

      // And the provider is asked every time, since nothing was recorded.
      expect(await loadOnce(loader), isA<TileBytesAbsent>());
      expect(provider.loads, 2);
    });

    test('an existing disk entry does not shadow the provider', () async {
      // Written by an earlier release, before the source became local.
      final cache = _MemoryByteCache();
      cache.entries['counting/3/1/2'] = Uint8List.fromList([9, 9]);
      final fresh = Uint8List.fromList([1]);
      final provider =
          _CountingProvider(TileResponseData(fresh), cacheBytesToDisk: false);
      final loader = TileByteLoader(provider, Future.value(cache));

      final result = await loadOnce(loader);
      expect((result as TileBytesLoaded).bytes, fresh);
      expect(provider.loads, 1);
    });

    test('nothing is ever stale, so revalidation never engages', () async {
      final cache = _MemoryByteCache();
      cache.entries['counting/3/1/2'] = Uint8List.fromList([9, 9]);
      final provider = _CountingProvider(
          TileResponseData(Uint8List.fromList([1])),
          cacheBytesToDisk: false);
      final loader =
          TileByteLoader(provider, Future.value(_ExpiredCache(cache)));

      final result = await loadOnce(loader);
      expect((result as TileBytesLoaded).stale, isFalse);
      expect(await loader.expiredBytes(key), isNull);
    });
  });

  group('refresh', () {
    final previous = Uint8List.fromList([9, 9]);

    Future<TileBytesResult?> refreshOnce(TileByteLoader loader) =>
        loader.refresh(key, previous, CancellationToken.none, () => false);

    test('delivers changed bytes and rewrites the disk entry', () async {
      final cache = _MemoryByteCache();
      final fresh = Uint8List.fromList([1, 2]);
      final provider = _CountingProvider(TileResponseData(fresh));
      final loader = TileByteLoader(provider, Future.value(cache));

      final result = await refreshOnce(loader);
      expect(result, isA<TileBytesLoaded>());
      expect((result as TileBytesLoaded).bytes, fresh);
      await pumpEventQueue();
      expect(cache.entries['counting/3/1/2'], fresh);
    });

    test('resolves null for identical bytes but still renews the entry',
        () async {
      final cache = _MemoryByteCache();
      final provider =
          _CountingProvider(TileResponseData(Uint8List.fromList([9, 9])));
      final loader = TileByteLoader(provider, Future.value(cache));

      expect(await refreshOnce(loader), isNull);
      await pumpEventQueue();
      expect(cache.puts, 1, reason: 'the rewrite restarts the TTL');
    });

    test('turns a tile deleted at the source into absent plus a sentinel',
        () async {
      final cache = _MemoryByteCache();
      final provider = _CountingProvider(const TileResponseNotFound());
      final loader = TileByteLoader(provider, Future.value(cache));

      expect(await refreshOnce(loader), isA<TileBytesAbsent>());
      await pumpEventQueue();
      expect(cache.entries['counting/3/1/2'], isEmpty);

      // An absence confirming a stale sentinel is not a change.
      expect(
        await loader.refresh(
            key, Uint8List(0), CancellationToken.none, () => false),
        isNull,
      );
    });

    test('failure is reported as unavailable, not as an unchanged tile',
        () async {
      final cache = _MemoryByteCache();
      final provider =
          _CountingProvider(TileResponseError(Exception('offline')));
      final loader = TileByteLoader(provider, Future.value(cache));

      expect(await refreshOnce(loader), isA<TileBytesUnavailable>(),
          reason: 'an unreachable source leaves the content unconfirmed, '
              'which callers must be able to tell from "nothing changed"');
      expect(loader.throttled(key), isFalse,
          reason: 'the stale entry must stay servable by the next load');
    });

    test('a failed refresh throttles further refreshes of the same key',
        () async {
      final cache = _MemoryByteCache();
      final provider =
          _CountingProvider(TileResponseError(Exception('offline')));
      final loader = TileByteLoader(provider, Future.value(cache));

      expect(await refreshOnce(loader), isA<TileBytesUnavailable>());
      // Browsing an expired area offline re-serves its stale entries on
      // every memory-cache miss; without this each one would start
      // another request.
      expect(await refreshOnce(loader), isNull);
      expect(provider.loads, 1);
    });

    test('concurrent refreshes coalesce to a single request', () async {
      final cache = _MemoryByteCache();
      final gate = Completer<void>();
      final provider =
          _CountingProvider(TileResponseData(Uint8List.fromList([1])))
            ..gate = gate.future;
      final loader = TileByteLoader(provider, Future.value(cache));

      final first = refreshOnce(loader);
      final second = refreshOnce(loader);
      gate.complete();
      expect(await second, isNull);
      expect(await first, isA<TileBytesLoaded>());
      expect(provider.loads, 1);
    });
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
