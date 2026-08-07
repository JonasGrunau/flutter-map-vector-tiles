import 'package:flutter_map_vector_tiles/src/cache/lru_cache.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('evicts least recently used beyond maxEntries', () {
    final evicted = <String>[];
    final cache = LruCache<String, int>(
      maxEntries: 2,
      onEvict: (k, _) => evicted.add(k),
    );
    cache.put('a', 1);
    cache.put('b', 2);
    cache.get('a'); // promote a
    cache.put('c', 3);
    expect(cache.get('b'), null);
    expect(cache.get('a'), 1);
    expect(cache.get('c'), 3);
    expect(evicted, ['b']);
  });

  test('enforces cost budget', () {
    final cache = LruCache<String, List<int>>(
      maxEntries: 100,
      maxCost: 10,
      costOf: (v) => v.length,
    );
    cache.put('a', List.filled(4, 0));
    cache.put('b', List.filled(4, 0));
    cache.put('c', List.filled(4, 0)); // 12 > 10 → evict a
    expect(cache.containsKey('a'), false);
    expect(cache.totalCost, 8);
  });

  test('replacing a key updates cost and disposes old value', () {
    final evicted = <int>[];
    final cache = LruCache<String, int>(
      maxEntries: 5,
      costOf: (v) => v,
      onEvict: (_, v) => evicted.add(v),
    );
    cache.put('a', 5);
    cache.put('a', 7);
    expect(cache.totalCost, 7);
    expect(evicted, [5]);
  });

  test('clear disposes everything', () {
    final evicted = <String>[];
    final cache = LruCache<String, int>(
      maxEntries: 5,
      onEvict: (k, _) => evicted.add(k),
    );
    cache.put('a', 1);
    cache.put('b', 2);
    cache.clear();
    expect(cache.length, 0);
    expect(evicted, unorderedEquals(['a', 'b']));
  });
}
