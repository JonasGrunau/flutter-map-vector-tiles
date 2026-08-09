@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_map_vector_tiles/src/cache/disk_cache.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('fmvt_test');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('round-trips bytes', () async {
    final cache = DiskCache(directory: dir);
    await cache.initialize();
    final bytes = Uint8List.fromList([1, 2, 3, 4]);
    await cache.put('tile/1/2/3', bytes);
    expect(await cache.get('tile/1/2/3'), bytes);
    expect(await cache.get('tile/9/9/9'), null);
  });

  test('expires entries past ttl', () async {
    final cache =
        DiskCache(directory: dir, ttl: const Duration(milliseconds: 1));
    await cache.initialize();
    await cache.put('k', Uint8List.fromList([1]));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(await cache.get('k'), null);
  });

  test('expired entries stay readable via getStale', () async {
    final cache =
        DiskCache(directory: dir, ttl: const Duration(milliseconds: 1));
    await cache.initialize();
    await cache.put('k', Uint8List.fromList([7]));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(await cache.get('k'), null);
    expect((await cache.getStale('k'))!.first, 7);
    // A repeated fresh get must not have deleted the file.
    expect((await cache.getStale('k'))!.first, 7);
    expect(await cache.getStale('missing'), null);
  });

  test('sweep keeps expired entries while under the size cap', () async {
    final cache = DiskCache(
      directory: dir,
      ttl: const Duration(milliseconds: 1),
      maxSizeBytes: 1024,
    );
    await cache.initialize();
    await cache.put('k', Uint8List.fromList([1, 2, 3]));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    // Force enough writes to trigger an opportunistic sweep.
    for (var i = 0; i < 10; i++) {
      await cache.put('other$i', Uint8List.fromList(List.filled(20, i)));
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect((await cache.getStale('k'))!.first, 1);
  });

  test('size sweep evicts oldest entries first', () async {
    final cache = DiskCache(directory: dir, maxSizeBytes: 300);
    await cache.initialize();
    await cache.put('old', Uint8List.fromList(List.filled(200, 1)));
    // Ensure a strictly older mtime for the first entry.
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    await cache.put('new', Uint8List.fromList(List.filled(200, 2)));
    // Writes exceeded the cap; sweep runs opportunistically.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(await cache.getStale('old'), null);
    expect((await cache.getStale('new'))!.first, 2);
  });

  test('different keys use different files', () async {
    final cache = DiskCache(directory: dir);
    await cache.initialize();
    await cache.put('a', Uint8List.fromList([1]));
    await cache.put('b', Uint8List.fromList([2]));
    expect((await cache.get('a'))!.first, 1);
    expect((await cache.get('b'))!.first, 2);
  });

  test('survives unwritable directory without throwing', () async {
    final cache =
        DiskCache(directory: Directory('${dir.path}/definitely/missing/deep'));
    // No initialize → directory absent.
    await cache.put('k', Uint8List.fromList([1]));
    expect(await cache.get('k'), null);
  });

  group('registry', () {
    setUp(DiskCacheRegistry.reset);
    tearDown(DiskCacheRegistry.reset);

    test('hands the same instance to every caller for a directory', () async {
      // Concurrent, because that is how two map layers built in the same
      // frame reach it.
      final caches = await Future.wait([
        DiskCacheRegistry.obtain(folder: () async => dir),
        DiskCacheRegistry.obtain(folder: () async => dir),
      ]);
      expect(caches.first, isNotNull);
      expect(identical(caches.first, caches.last), true);

      // And once more after both resolved, off the in-flight path.
      expect(
        identical(await DiskCacheRegistry.obtain(folder: () async => dir),
            caches.first),
        true,
      );
    });

    test('keeps separate instances per directory', () async {
      final nested = Directory('${dir.path}${Platform.pathSeparator}style');
      final tiles = await DiskCacheRegistry.obtain(folder: () async => dir);
      final styles = await DiskCacheRegistry.obtain(folder: () async => nested);
      expect(identical(tiles, styles), false);
      expect(await nested.exists(), true);
    });

    test('resolves null when the folder cannot be resolved', () async {
      final cache = await DiskCacheRegistry.obtain(
        folder: () async => throw const FileSystemException('no path'),
      );
      expect(cache, null);
    });
  });
}
