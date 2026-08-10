import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../cache/byte_cache.dart';
import '../cache/lru_cache.dart';
import '../core/cancellation.dart';
import '../core/single_flight.dart';
import '../core/tile_key.dart';
import '../core/tile_zoom.dart';
import '../tile_providers.dart';
import 'tile_byte_loader.dart';

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
  final TileByteLoader _bytes;

  /// Decoded images, shared process-wide between stores on the same
  /// source. Entries survive [dispose] and live for the process lifetime;
  /// [clearMemoryCaches] drops them.
  static final _memoryCaches = <String, LruCache<TileKey, ui.Image>>{};

  final LruCache<TileKey, ui.Image> _memory;
  final _inFlight = SingleFlight<TileKey, ui.Image?>();
  final _notFound = <TileKey>{};
  var _disposed = false;

  RasterTileStore({
    required this.source,
    Future<ByteCache?>? diskCache,
    int memoryCacheMaxBytes = 32 * 1024 * 1024,
  })  : _bytes = TileByteLoader(source.provider, diskCache ?? Future.value()),
        _memory = _memoryCaches.putIfAbsent(
          source.provider.cacheKey,
          () => LruCache(
            maxEntries: 128,
            maxCost: memoryCacheMaxBytes,
            costOf: (image) => image.width * image.height * 4,
            onEvict: (_, image) => image.dispose(),
          ),
        )..setMaxCost(memoryCacheMaxBytes);

  /// Empties every shared decoded-image cache. For memory-pressure
  /// handling and tests.
  ///
  /// The caches stay registered — see [TileStore.clearMemoryCaches]:
  /// dropping the registry entry would orphan a cache that in-flight
  /// loads keep filling with images no later clear could release.
  static void clearMemoryCaches() {
    for (final cache in _memoryCaches.values) {
      cache.clear();
    }
  }

  /// Applies a new byte budget to the shared cache (latest layer wins).
  set memoryCacheMaxBytes(int bytes) => _memory.setMaxCost(bytes);

  /// Resolves the data tile key serving [displayKey] with [zoomOffset]
  /// applied. 256px sources are fetched one level deeper than 512px ones
  /// for the same visual scale; when that would require *under*zooming
  /// (several data tiles per display tile) the tile is upscaled instead.
  /// Returns null when the source cannot serve this zoom at all.
  TileKey? dataKeyFor(TileKey displayKey, int zoomOffset) => dataKeyForDisplay(
        displayKey,
        zoomOffset + (source.tileSize <= 256 ? 1 : 0),
        minimumZoom: source.provider.minimumZoom,
        maximumZoom: source.provider.maximumZoom,
        capAtDisplayZoom: true,
      );

  /// Returns an owned handle if the tile is already decoded in memory.
  RasterTile? peek(TileKey dataKey) {
    final image = _memory.get(dataKey);
    return image == null ? null : RasterTile(dataKey, image.clone());
  }

  /// Returns [dataKey]'s tile or its nearest in-memory ancestor — used
  /// for provisional imagery while the real tile loads.
  RasterTile? peekWithAncestors(TileKey dataKey) =>
      findWithAncestors(dataKey, source.provider.minimumZoom, peek);

  /// Loads and decodes a data tile. Returns null on cancellation,
  /// absence, or (throttled) transient failure — never throws.
  Future<RasterTile?> obtain(
    TileKey dataKey, {
    CancellationToken? cancellation,
  }) async {
    final cached = peek(dataKey);
    if (cached != null) return cached;
    if (_notFound.contains(dataKey)) return null;
    if (_bytes.throttled(dataKey)) return null;

    // Coalesced: the shared load polls a token joined over every waiter,
    // so one disposed display tile can never cancel a load that other
    // live tiles still await.
    final loaded = await _inFlight.run(
      dataKey,
      (token) async {
        final master = await _load(dataKey, token);
        if (master == null) return null;
        // The shared cache owns [master], and a concurrent completion
        // can evict — and dispose — it before the waiters below resume.
        // Hand the flight its own clone instead: waiters clone from it
        // during the completion microtask cascade, strictly before the
        // event-loop task scheduled here releases it.
        final handout = master.clone();
        unawaited(Future<void>(handout.dispose));
        return handout;
      },
      cancellation: cancellation,
    );
    return loaded == null ? null : RasterTile(dataKey, loaded.clone());
  }

  /// Whether the source has said this tile does not exist — a permanent
  /// answer that retrying cannot change.
  bool knownAbsent(TileKey dataKey) => _notFound.contains(dataKey);

  Future<ui.Image?> _load(
    TileKey dataKey,
    CancellationToken cancellation,
  ) async {
    if (_disposed) return null;
    final Uint8List bytes;
    switch (await _bytes.load(dataKey, cancellation, () => _disposed)) {
      case TileBytesUnavailable():
        return null;
      case TileBytesAbsent():
        _notFound.add(dataKey);
        return null;
      case TileBytesLoaded(bytes: final loaded):
        bytes = loaded;
    }

    ui.Image image;
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      codec.dispose();
      image = frame.image;
    } catch (_) {
      // Corrupt image: throttle retries.
      _bytes.noteFailure(dataKey);
      return null;
    }
    // Cached even if disposed meanwhile — the shared cache outlives the
    // store, like the vector tile cache.
    _memory.put(dataKey, image);
    _bytes.noteSuccess(dataKey);
    return image;
  }

  /// Stops this store. Decoded images stay in the shared memory cache so
  /// the next map over this source paints immediately.
  void dispose() {
    _disposed = true;
    _inFlight.clear();
    _bytes.dispose();
  }
}
