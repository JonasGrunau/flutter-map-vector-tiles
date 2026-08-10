import 'dart:async';
import 'dart:typed_data';

import '../cache/byte_cache.dart';
import '../core/cancellation.dart';
import '../core/tile_key.dart';
import '../provider/vector_tile_provider.dart';

/// Outcome of a raw tile byte load.
sealed class TileBytesResult {
  const TileBytesResult();
}

class TileBytesLoaded extends TileBytesResult {
  final Uint8List bytes;
  const TileBytesLoaded(this.bytes);
}

/// The source has said this tile does not exist — a permanent answer.
class TileBytesAbsent extends TileBytesResult {
  const TileBytesAbsent();
}

/// Cancelled, store disposed, or transient failure (now throttled).
class TileBytesUnavailable extends TileBytesResult {
  const TileBytesUnavailable();
}

/// Loads raw tile bytes for one provider through the shared disk cache,
/// with offline fallback and failure throttling.
///
/// Both tile stores used to carry a near-verbatim copy of this logic
/// (and the copies had drifted); they now consume this loader and add
/// only their decode and memory-cache step.
class TileByteLoader {
  final VectorTileProvider provider;

  /// Resolved lazily, and awaited on the load path rather than read as a
  /// plain field: the cache initializes asynchronously (its directory
  /// comes from a platform channel) while the first tiles are already
  /// being requested. Reading it too early yields null, which would send
  /// the opening screenful of every map to the network despite it
  /// sitting on disk. Resolves to null when disk caching is off.
  final Future<ByteCache?> diskCache;

  final _failedAt = <TileKey, DateTime>{};

  /// How long a failed key is throttled before another attempt may hit
  /// the network. The layer schedules its load retries just past this.
  /// Mutable for tests only.
  static var errorRetryDelay = const Duration(seconds: 15);

  TileByteLoader(this.provider, this.diskCache);

  String cacheKeyOf(TileKey key) =>
      '${provider.cacheKey}/${key.z}/${key.x}/${key.y}';

  /// Whether [key] failed recently enough that another attempt would be
  /// wasted.
  bool throttled(TileKey key) {
    final failed = _failedAt[key];
    return failed != null &&
        DateTime.now().difference(failed) < errorRetryDelay;
  }

  /// Records a failure of a later pipeline stage (e.g. a corrupt tile
  /// that failed decoding), throttling retries like a network failure.
  void noteFailure(TileKey key) => _failedAt[key] = DateTime.now();

  void noteSuccess(TileKey key) => _failedAt.remove(key);

  void dispose() => _failedAt.clear();

  /// Loads [key]'s bytes: fresh disk cache entry, then the provider,
  /// then a stale disk entry as offline fallback. [disposed] is polled
  /// across awaits so a disposed store stops work early.
  Future<TileBytesResult> load(
    TileKey key,
    CancellationToken cancellation,
    bool Function() disposed,
  ) async {
    final cacheKey = cacheKeyOf(key);
    final cache = await diskCache;
    if (disposed() || cancellation.isCancelled) {
      return const TileBytesUnavailable();
    }

    var bytes = await cache?.get(cacheKey);
    if (disposed() || cancellation.isCancelled) {
      return const TileBytesUnavailable();
    }
    if (bytes != null) return TileBytesLoaded(bytes);

    final response = await provider.load(key, cancellation: cancellation);
    if (disposed()) return const TileBytesUnavailable();
    switch (response) {
      case TileResponseData():
        unawaited(cache?.put(cacheKey, response.bytes));
        return TileBytesLoaded(response.bytes);
      case TileResponseNotFound():
        return const TileBytesAbsent();
      case TileResponseCancelled():
        return const TileBytesUnavailable();
      case TileResponseError():
        // Network failure: serve an expired cache entry if one exists —
        // stale map data beats a blank map when offline.
        bytes = await cache?.getStale(cacheKey);
        if (bytes != null) return TileBytesLoaded(bytes);
        _failedAt[key] = DateTime.now();
        return const TileBytesUnavailable();
    }
  }
}
