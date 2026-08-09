@TestOn('browser')
library;

import 'package:flutter_map_vector_tiles/src/cache/cache_resolver.dart';
import 'package:flutter_map_vector_tiles/src/logger.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pins the web degradation contract: no persistent cache exists on web,
/// even when a cache path override is supplied — callers get null and
/// fall back to the in-memory cache plus the browser HTTP cache.
void main() {
  test('obtainTileCache resolves null on web', () async {
    final cache = await obtainTileCache(
      cachePath: () async => '/ignored',
      ttl: const Duration(days: 14),
      maxSizeBytes: 1024 * 1024,
      logger: const Logger.noop(),
    );
    expect(cache, isNull);
  });

  test('openStyleCache resolves null on web', () async {
    final cache = await openStyleCache(
      cachePath: () async => '/ignored',
      refreshAfter: const Duration(hours: 12),
      logger: const Logger.noop(),
    );
    expect(cache, isNull);
  });
}
