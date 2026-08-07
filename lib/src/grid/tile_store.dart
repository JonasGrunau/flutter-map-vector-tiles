import 'dart:async';

import '../cache/disk_cache.dart';
import '../cache/lru_cache.dart';
import '../core/cancellation.dart';
import '../core/tile_key.dart';
import '../pipeline/executor/executor.dart';
import '../pipeline/prepared_tile.dart';
import '../pipeline/tile_processor.dart';
import '../provider/vector_tile_provider.dart';

/// Loads, decodes and caches *data* tiles for one style source.
///
/// Data tiles are shared by all display tiles that overzoom them, and by
/// consecutive zoom levels clamped to the source's maximum zoom — the
/// memory cache is keyed by data tile, not display tile, so zooming
/// beyond the source maximum costs no additional fetches or decodes.
class TileStore {
  final VectorTileProvider provider;
  final TilePrepareExecutor executor;

  /// Mutable: the disk cache initializes asynchronously and is attached
  /// to already-running stores once ready, so the map never rebuilds
  /// (and blanks) just because the cache arrived.
  DiskCache? diskCache;

  /// Per source-layer property keep-lists derived from the theme.
  final Map<String, Set<String>?> layerProperties;

  final LruCache<TileKey, PreparedTile> _memory;
  final _inFlight = <TileKey, Future<PreparedTile?>>{};
  final _failedAt = <TileKey, DateTime>{};
  var _disposed = false;

  static const _errorRetryDelay = Duration(seconds: 15);

  TileStore({
    required this.provider,
    required this.executor,
    required this.layerProperties,
    this.diskCache,
    int memoryCacheMaxBytes = 32 * 1024 * 1024,
  }) : _memory = LruCache(
          maxEntries: 256,
          maxCost: memoryCacheMaxBytes,
          costOf: (tile) => tile.byteSize,
        );

  /// Resolves the data tile key serving [displayKey] with [zoomOffset]
  /// applied, clamped to the provider's zoom range. Returns null when
  /// the source cannot serve this zoom at all.
  TileKey? dataKeyFor(TileKey displayKey, int zoomOffset) {
    final dataZoom = (displayKey.z + zoomOffset)
        .clamp(provider.minimumZoom, provider.maximumZoom);
    if (dataZoom > displayKey.z) return null;
    return TileKey.wrapped(
      dataZoom,
      displayKey.x >> (displayKey.z - dataZoom),
      displayKey.y >> (displayKey.z - dataZoom),
    );
  }

  /// Returns the prepared tile if it is already in memory.
  PreparedTile? peek(TileKey dataKey) => _memory.get(dataKey);

  /// Returns [dataKey]'s tile or its nearest in-memory ancestor —
  /// used to render provisional imagery instantly while the real tile
  /// loads (fast zoom-in never shows blank tiles).
  PreparedTile? peekWithAncestors(TileKey dataKey) {
    var key = dataKey;
    for (var i = 0; i <= 5; i++) {
      final tile = _memory.get(key);
      if (tile != null) return tile;
      if (key.z == 0 || key.z <= provider.minimumZoom) return null;
      key = key.parent;
    }
    return null;
  }

  /// Loads and prepares a data tile. Returns null on cancellation or
  /// (transient) failure — failures are throttled, never thrown.
  Future<PreparedTile?> obtain(
    TileKey dataKey, {
    int priority = 0,
    CancellationToken? cancellation,
  }) {
    final cached = _memory.get(dataKey);
    if (cached != null) return Future.value(cached);

    final failed = _failedAt[dataKey];
    if (failed != null &&
        DateTime.now().difference(failed) < _errorRetryDelay) {
      return Future.value(null);
    }

    final pending = _inFlight[dataKey];
    if (pending != null) return pending;

    // NOTE: block body — an arrow body would return the removed value,
    // which is this very future, and whenComplete awaits a returned
    // future: the future would deadlock waiting on itself.
    final future = _load(dataKey, priority, cancellation).whenComplete(() {
      _inFlight.remove(dataKey);
    });
    _inFlight[dataKey] = future;
    return future;
  }

  Future<PreparedTile?> _load(
    TileKey dataKey,
    int priority,
    CancellationToken? cancellation,
  ) async {
    if (_disposed) return null;
    final cacheKey = '${provider.cacheKey}/${dataKey.z}'
        '/${dataKey.x}/${dataKey.y}';

    var bytes = await diskCache?.get(cacheKey);
    if (_disposed || (cancellation?.isCancelled ?? false)) return null;

    if (bytes == null) {
      final response = await provider.load(dataKey, cancellation: cancellation);
      if (_disposed) return null;
      if (response is TileResponseData) {
        bytes = response.bytes;
        unawaited(diskCache?.put(cacheKey, response.bytes));
      } else if (response is TileResponseNotFound) {
        final empty =
            PreparedTile(key: dataKey, layers: const {}, byteSize: 64);
        _memory.put(dataKey, empty);
        return empty;
      } else if (response is TileResponseCancelled) {
        return null;
      } else {
        // Network failure: serve an expired cache entry if one exists —
        // stale map data beats a blank map when offline.
        bytes = await diskCache?.getStale(cacheKey);
        if (bytes == null) {
          _failedAt[dataKey] = DateTime.now();
          return null;
        }
      }
    }

    final prepared = await executor.prepare(
      PrepareInput(
        z: dataKey.z,
        x: dataKey.x,
        y: dataKey.y,
        bytes: bytes,
        layerProperties: layerProperties,
      ),
      priority: priority,
      cancellation: cancellation,
    );
    if (_disposed) return null;
    if (prepared == null) {
      if (!(cancellation?.isCancelled ?? false)) {
        // Decode failure (corrupt tile): throttle retries.
        _failedAt[dataKey] = DateTime.now();
      }
      return null;
    }
    _memory.put(dataKey, prepared);
    _failedAt.remove(dataKey);
    return prepared;
  }

  void dispose() {
    _disposed = true;
    _memory.clear();
    _inFlight.clear();
  }
}
