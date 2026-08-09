import '../logger.dart';
import 'byte_cache.dart';
import 'cache_resolver_stub.dart' if (dart.library.io) 'cache_resolver_io.dart'
    as impl;

/// Resolves the persistent byte caches for the current platform.
///
/// On platforms with a filesystem this is the shared disk cache; on web
/// there is no persistent cache and both resolvers return null — callers
/// already tolerate a null cache and degrade to the in-memory cache plus
/// the browser's own HTTP cache.
///
/// Mirrors the conditional-import pattern of
/// `pipeline/executor/executor.dart`.
Future<ByteCache?> obtainTileCache({
  Future<String> Function()? cachePath,
  required Duration ttl,
  required int maxSizeBytes,
  required Logger logger,
}) =>
    impl.obtainTileCache(
      cachePath: cachePath,
      ttl: ttl,
      maxSizeBytes: maxSizeBytes,
      logger: logger,
    );

/// The style bundle cache (style.json, TileJSON, sprites), or null on web
/// or when the directory cannot be set up.
Future<ByteCache?> openStyleCache({
  Future<String> Function()? cachePath,
  required Duration refreshAfter,
  required Logger logger,
}) =>
    impl.openStyleCache(
      cachePath: cachePath,
      refreshAfter: refreshAfter,
      logger: logger,
    );
