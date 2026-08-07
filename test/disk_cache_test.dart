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

  test('different keys use different files', () async {
    final cache = DiskCache(directory: dir);
    await cache.initialize();
    await cache.put('a', Uint8List.fromList([1]));
    await cache.put('b', Uint8List.fromList([2]));
    expect((await cache.get('a'))!.first, 1);
    expect((await cache.get('b'))!.first, 2);
  });

  test('survives unwritable directory without throwing', () async {
    final cache = DiskCache(
        directory: Directory('${dir.path}/definitely/missing/deep'));
    // No initialize → directory absent.
    await cache.put('k', Uint8List.fromList([1]));
    expect(await cache.get('k'), null);
  });
}
