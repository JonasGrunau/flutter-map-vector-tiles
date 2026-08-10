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

  /// True when [bytes] came from an expired disk entry served ahead of
  /// revalidation (stale-while-revalidate) — the caller should display
  /// them and call [TileByteLoader.refresh] in the background.
  final bool stale;
  const TileBytesLoaded(this.bytes, {this.stale = false});
}

/// The source has said this tile does not exist. Permanent for the
/// session unless [stale], in which case the absence is due for a
/// background re-check like any other expired entry.
class TileBytesAbsent extends TileBytesResult {
  /// See [TileBytesLoaded.stale].
  final bool stale;
  const TileBytesAbsent({this.stale = false});
}

/// Cancelled, store disposed, or transient failure (now throttled).
class TileBytesUnavailable extends TileBytesResult {
  const TileBytesUnavailable();
}

/// Loads raw tile bytes for one provider through the shared disk cache,
/// with stale-while-revalidate for expired entries and failure
/// throttling.
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
  final _refreshing = <TileKey>{};

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

  void dispose() {
    _failedAt.clear();
    _refreshing.clear();
  }

  /// Loads [key]'s bytes: fresh disk cache entry, then an expired one
  /// (served stale, to be [refresh]ed by the caller), then the provider.
  /// [disposed] is polled across awaits so a disposed store stops work
  /// early.
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

    // A zero-byte entry is the "known absent" sentinel written below:
    // empty tiles (oceans, sparse zooms) would otherwise be re-requested
    // every session, since providers answer them with NotFound and only
    // data responses used to reach the disk. Providers never produce
    // empty TileResponseData (they map empty bodies to NotFound), so the
    // sentinel is unambiguous. The TTL still applies — absence is
    // re-checked at the same cadence as data.
    var bytes = await cache?.get(cacheKey);
    if (disposed() || cancellation.isCancelled) {
      return const TileBytesUnavailable();
    }
    if (bytes != null) {
      return bytes.isEmpty ? const TileBytesAbsent() : TileBytesLoaded(bytes);
    }

    // Expired entry: stale-while-revalidate. Serve it immediately so the
    // map paints without waiting on the network — the caller starts a
    // background [refresh], and until that lands (or when it fails, e.g.
    // offline) the expired imagery simply stays.
    bytes = await cache?.getStale(cacheKey);
    if (disposed() || cancellation.isCancelled) {
      return const TileBytesUnavailable();
    }
    if (bytes != null) {
      return bytes.isEmpty
          ? const TileBytesAbsent(stale: true)
          : TileBytesLoaded(bytes, stale: true);
    }

    final response = await provider.load(key, cancellation: cancellation);
    if (disposed()) return const TileBytesUnavailable();
    switch (response) {
      case TileResponseData():
        unawaited(cache?.put(cacheKey, response.bytes));
        return TileBytesLoaded(response.bytes);
      case TileResponseNotFound():
        unawaited(cache?.put(cacheKey, Uint8List(0)));
        return const TileBytesAbsent();
      case TileResponseCancelled():
        return const TileBytesUnavailable();
      case TileResponseError():
        // Network failure. Expired entries were already served above,
        // but another loader sharing this disk cache (two styles over
        // one source) may have written the key while this request was
        // in flight — better that entry than a blank tile.
        bytes = await cache?.getStale(cacheKey);
        if (bytes != null) {
          return bytes.isEmpty
              ? const TileBytesAbsent()
              : TileBytesLoaded(bytes);
        }
        _failedAt[key] = DateTime.now();
        return const TileBytesUnavailable();
    }
  }

  /// Revalidates an expired entry that [load] served stale: fetches
  /// [key] from the provider and rewrites the disk entry, restarting
  /// its TTL.
  ///
  /// Returns the replacement content when it differs from [previous] —
  /// [TileBytesLoaded] for new data, [TileBytesAbsent] when the source
  /// now answers not-found — and null when nothing changed: the bytes
  /// were identical (the disk entry is fresh again either way), the
  /// fetch failed, or it was cancelled. A failure is *not* throttled:
  /// the stale entry stays the best answer, and a later [load] must not
  /// be blocked from serving it.
  ///
  /// At most one refresh per key runs at a time; concurrent calls
  /// resolve to null.
  Future<TileBytesResult?> refresh(
    TileKey key,
    Uint8List previous,
    CancellationToken cancellation,
    bool Function() disposed,
  ) async {
    if (!_refreshing.add(key)) return null;
    try {
      final response = await provider.load(key, cancellation: cancellation);
      if (disposed()) return null;
      final cache = await diskCache;
      if (disposed()) return null;
      switch (response) {
        case TileResponseData():
          unawaited(cache?.put(cacheKeyOf(key), response.bytes));
          _failedAt.remove(key);
          return _sameBytes(response.bytes, previous)
              ? null
              : TileBytesLoaded(response.bytes);
        case TileResponseNotFound():
          unawaited(cache?.put(cacheKeyOf(key), Uint8List(0)));
          _failedAt.remove(key);
          return previous.isEmpty ? null : const TileBytesAbsent();
        case TileResponseCancelled():
        case TileResponseError():
          return null;
      }
    } finally {
      _refreshing.remove(key);
    }
  }

  static bool _sameBytes(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
