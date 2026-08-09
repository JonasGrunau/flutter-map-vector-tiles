import '../logger.dart';
import 'byte_cache.dart';

/// Web has no persistent tile cache in this release: tiles fall back to
/// the in-memory cache plus the browser's own HTTP cache. [cachePath],
/// [ttl] and [maxSizeBytes] are ignored.
Future<ByteCache?> obtainTileCache({
  Future<String> Function()? cachePath,
  required Duration ttl,
  required int maxSizeBytes,
  required Logger logger,
}) =>
    Future.value();

/// Web has no persistent style cache either; the browser HTTP cache
/// applies to style resources instead.
Future<ByteCache?> openStyleCache({
  Future<String> Function()? cachePath,
  required Duration refreshAfter,
  required Logger logger,
}) =>
    Future.value();
