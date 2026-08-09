import 'dart:async';
import 'dart:ui' as ui;

import '../cache/disk_cache.dart';
import '../cache/lru_cache.dart';
import '../core/cancellation.dart';
import '../core/tile_key.dart';
import '../provider/vector_tile_provider.dart';
import '../tile_providers.dart';

/// A decoded raster tile. The image handle is owned by whoever holds the
/// [RasterTile] — call [dispose] when done; the underlying pixels stay
/// alive while the store (or any other holder) still references them.
class RasterTile {
  final TileKey key;
  final ui.Image image;

  RasterTile(this.key, this.image);

  /// An independently-owned handle to the same pixels.
  RasterTile retain() => RasterTile(key, image.clone());

  void dispose() => image.dispose();
}

/// Loads, decodes and caches raster image tiles for one raster source of
/// a vector style.
///
/// Mirrors `TileStore` for vector data: bytes come from the provider via
/// the shared disk cache, are decoded to a [ui.Image], and decoded images
/// are cached process-wide so a reopened map paints immediately. Handed
/// out tiles are ref-counted clones ([ui.Image.clone]), so an LRU
/// eviction can never dispose pixels a queued rasterization still needs.
class RasterTileStore {
  final RasterTileSource source;
  final Future<DiskCache?> diskCache;

  /// Decoded images, shared process-wide between stores on the same
  /// source. Entries survive [dispose] and live for the process lifetime;
  /// [clearMemoryCaches] drops them.
  static final _memoryCaches = <String, LruCache<TileKey, ui.Image>>{};

  final LruCache<TileKey, ui.Image> _memory;
  final _inFlight = <TileKey, Future<ui.Image?>>{};
  final _failedAt = <TileKey, DateTime>{};
  final _notFound = <TileKey>{};
  var _disposed = false;

  static const _errorRetryDelay = Duration(seconds: 15);

  RasterTileStore({
    required this.source,
    Future<DiskCache?>? diskCache,
    int memoryCacheMaxBytes = 32 * 1024 * 1024,
  })  : diskCache = diskCache ?? Future.value(),
        _memory = _memoryCaches.putIfAbsent(
          source.provider.cacheKey,
          () => LruCache(
            maxEntries: 128,
            maxCost: memoryCacheMaxBytes,
            costOf: (image) => image.width * image.height * 4,
            onEvict: (_, image) => image.dispose(),
          ),
        );

  /// Empties every shared decoded-image cache. For memory-pressure
  /// handling and tests.
  static void clearMemoryCaches() {
    for (final cache in _memoryCaches.values) {
      cache.clear();
    }
    _memoryCaches.clear();
  }

  /// Resolves the data tile key serving [displayKey] with [zoomOffset]
  /// applied. 256px sources are fetched one level deeper than 512px ones
  /// for the same visual scale; when that would require *under*zooming
  /// (several data tiles per display tile) the tile is upscaled instead.
  /// Returns null when the source cannot serve this zoom at all.
  TileKey? dataKeyFor(TileKey displayKey, int zoomOffset) {
    final provider = source.provider;
    var dataZoom = displayKey.z + zoomOffset + (source.tileSize <= 256 ? 1 : 0);
    if (dataZoom > displayKey.z) dataZoom = displayKey.z;
    dataZoom = dataZoom.clamp(provider.minimumZoom, provider.maximumZoom);
    if (dataZoom > displayKey.z) return null;
    return TileKey.wrapped(
      dataZoom,
      displayKey.x >> (displayKey.z - dataZoom),
      displayKey.y >> (displayKey.z - dataZoom),
    );
  }

  /// Returns an owned handle if the tile is already decoded in memory.
  RasterTile? peek(TileKey dataKey) {
    final image = _memory.get(dataKey);
    return image == null ? null : RasterTile(dataKey, image.clone());
  }

  /// Returns [dataKey]'s tile or its nearest in-memory ancestor — used
  /// for provisional imagery while the real tile loads.
  RasterTile? peekWithAncestors(TileKey dataKey) {
    var key = dataKey;
    for (var i = 0; i <= 5; i++) {
      final tile = peek(key);
      if (tile != null) return tile;
      if (key.z == 0 || key.z <= source.provider.minimumZoom) return null;
      key = key.parent;
    }
    return null;
  }

  /// Loads and decodes a data tile. Returns null on cancellation,
  /// absence, or (throttled) transient failure — never throws.
  Future<RasterTile?> obtain(
    TileKey dataKey, {
    CancellationToken? cancellation,
  }) async {
    final cached = peek(dataKey);
    if (cached != null) return cached;
    if (_notFound.contains(dataKey)) return null;

    final failed = _failedAt[dataKey];
    if (failed != null &&
        DateTime.now().difference(failed) < _errorRetryDelay) {
      return null;
    }

    var pending = _inFlight[dataKey];
    if (pending == null) {
      // NOTE: block body — an arrow body would return the removed value,
      // which is this very future, and whenComplete awaits a returned
      // future: the future would deadlock waiting on itself.
      pending = _load(dataKey, cancellation).whenComplete(() {
        _inFlight.remove(dataKey);
      });
      _inFlight[dataKey] = pending;
    }
    if (await pending == null) return null;
    // The master lives in the shared cache; every caller gets a clone.
    // Re-read it (synchronously — no suspension before the clone) so a
    // concurrent eviction can never hand out a disposed image.
    final master = _memory.get(dataKey);
    return master == null ? null : RasterTile(dataKey, master.clone());
  }

  Future<ui.Image?> _load(
    TileKey dataKey,
    CancellationToken? cancellation,
  ) async {
    if (_disposed) return null;
    final provider = source.provider;
    final cacheKey = '${provider.cacheKey}/${dataKey.z}'
        '/${dataKey.x}/${dataKey.y}';

    final cache = await diskCache;
    if (_disposed || (cancellation?.isCancelled ?? false)) return null;

    var bytes = await cache?.get(cacheKey);
    if (_disposed || (cancellation?.isCancelled ?? false)) return null;

    if (bytes == null) {
      final response = await provider.load(dataKey, cancellation: cancellation);
      if (_disposed) return null;
      if (response is TileResponseData) {
        bytes = response.bytes;
        unawaited(cache?.put(cacheKey, response.bytes));
      } else if (response is TileResponseNotFound) {
        _notFound.add(dataKey);
        return null;
      } else if (response is TileResponseCancelled) {
        return null;
      } else {
        // Network failure: serve an expired cache entry if one exists —
        // stale imagery beats a hole in the map when offline.
        bytes = await cache?.getStale(cacheKey);
        if (bytes == null) {
          _failedAt[dataKey] = DateTime.now();
          return null;
        }
      }
    }

    ui.Image image;
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      codec.dispose();
      image = frame.image;
    } catch (_) {
      // Corrupt image: throttle retries.
      _failedAt[dataKey] = DateTime.now();
      return null;
    }
    // Cached even if disposed meanwhile — the shared cache outlives the
    // store, like the vector tile cache.
    _memory.put(dataKey, image);
    _failedAt.remove(dataKey);
    return image;
  }

  /// Stops this store. Decoded images stay in the shared memory cache so
  /// the next map over this source paints immediately.
  void dispose() {
    _disposed = true;
    _inFlight.clear();
    _failedAt.clear();
  }
}
