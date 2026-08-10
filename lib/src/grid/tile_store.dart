import 'dart:async';

import '../cache/byte_cache.dart';
import '../cache/lru_cache.dart';
import '../core/cancellation.dart';
import '../core/single_flight.dart';
import '../core/tile_key.dart';
import '../core/tile_zoom.dart';
import '../pipeline/executor/executor.dart';
import '../pipeline/prepared_tile.dart';
import '../pipeline/tile_processor.dart';
import '../provider/vector_tile_provider.dart';
import 'tile_byte_loader.dart';

/// Loads, decodes and caches *data* tiles for one style source.
///
/// Data tiles are shared by all display tiles that overzoom them, and by
/// consecutive zoom levels clamped to the source's maximum zoom — the
/// memory cache is keyed by data tile, not display tile, so zooming
/// beyond the source maximum costs no additional fetches or decodes.
class TileStore {
  final VectorTileProvider provider;
  final TilePrepareExecutor executor;
  final TileByteLoader _bytes;

  /// Per source-layer property keep-lists derived from the theme.
  final Map<String, Set<String>?> layerProperties;

  /// Decoded tiles, shared process-wide between every store built on the
  /// same source *and* the same property keep-lists.
  ///
  /// Holding this outside the instance is what makes a reopened map paint at
  /// once: the layer — and with it this store — is rebuilt every time the
  /// screen is mounted, and re-decoding tiles that were already in memory a
  /// moment ago is the bulk of that delay. Entries therefore survive
  /// [dispose] and live for the process lifetime, bounded by the byte budget
  /// of the most recently constructed store over the source.
  /// [clearMemoryCaches] drops them.
  static final _memoryCaches = <String, LruCache<TileKey, PreparedTile>>{};

  final LruCache<TileKey, PreparedTile> _memory;
  final _inFlight = SingleFlight<TileKey, PreparedTile?>();
  var _disposed = false;

  TileStore({
    required this.provider,
    required this.executor,
    required this.layerProperties,
    Future<ByteCache?>? diskCache,
    int memoryCacheMaxBytes = 32 * 1024 * 1024,
  })  : _bytes = TileByteLoader(provider, diskCache ?? Future.value()),
        _memory = _memoryCaches.putIfAbsent(
          _memorySignature(provider, layerProperties),
          () => LruCache(
            maxEntries: 256,
            maxCost: memoryCacheMaxBytes,
            costOf: (tile) => tile.byteSize,
          ),
        )..setMaxCost(memoryCacheMaxBytes);

  /// Identifies a shared memory cache.
  ///
  /// The source alone is not enough: prepared tiles are trimmed to the
  /// properties the theme reads, so two themes over the same source produce
  /// different content for the same key. The details and monitoring styles of
  /// one map provider are exactly that case.
  static String _memorySignature(
    VectorTileProvider provider,
    Map<String, Set<String>?> layerProperties,
  ) {
    final buffer = StringBuffer(provider.cacheKey);
    for (final sourceLayer in layerProperties.keys.toList()..sort()) {
      final properties = layerProperties[sourceLayer];
      buffer.write('|$sourceLayer:');
      buffer.write(
          properties == null ? '*' : (properties.toList()..sort()).join(','));
    }
    return buffer.toString();
  }

  /// Empties every shared decoded-tile cache, so the next map open re-reads
  /// from disk. For memory-pressure handling and tests.
  ///
  /// The caches stay registered: live stores hold references to them,
  /// and dropping the registry entry would orphan a cache that
  /// in-flight loads keep filling — unreachable by any later clear.
  static void clearMemoryCaches() {
    for (final cache in _memoryCaches.values) {
      cache.clear();
    }
  }

  /// Applies a new byte budget to the shared cache (latest layer wins).
  set memoryCacheMaxBytes(int bytes) => _memory.setMaxCost(bytes);

  /// Resolves the data tile key serving [displayKey] with [zoomOffset]
  /// applied, clamped to the provider's zoom range. Returns null when
  /// the source cannot serve this zoom at all.
  TileKey? dataKeyFor(TileKey displayKey, int zoomOffset) => dataKeyForDisplay(
        displayKey,
        zoomOffset,
        minimumZoom: provider.minimumZoom,
        maximumZoom: provider.maximumZoom,
      );

  /// Returns the prepared tile if it is already in memory.
  PreparedTile? peek(TileKey dataKey) => _memory.get(dataKey);

  /// Returns [dataKey]'s tile or its nearest in-memory ancestor —
  /// used to render provisional imagery instantly while the real tile
  /// loads (fast zoom-in never shows blank tiles).
  PreparedTile? peekWithAncestors(TileKey dataKey) =>
      findWithAncestors(dataKey, provider.minimumZoom, _memory.get);

  /// Loads and prepares a data tile. Returns null on cancellation or
  /// (transient) failure — failures are throttled, never thrown.
  Future<PreparedTile?> obtain(
    TileKey dataKey, {
    int priority = 0,
    CancellationToken? cancellation,
  }) {
    final cached = _memory.get(dataKey);
    if (cached != null) return Future.value(cached);
    if (_bytes.throttled(dataKey)) return Future.value(null);

    // Coalesced: the shared load polls a token joined over every waiter,
    // so one disposed display tile can never cancel a load that other
    // live tiles still await.
    return _inFlight.run(
      dataKey,
      (token) => _load(dataKey, priority, token),
      cancellation: cancellation,
    );
  }

  Future<PreparedTile?> _load(
    TileKey dataKey,
    int priority,
    CancellationToken cancellation,
  ) async {
    if (_disposed) return null;
    switch (await _bytes.load(dataKey, cancellation, () => _disposed)) {
      case TileBytesUnavailable():
        return null;
      case TileBytesAbsent():
        final empty =
            PreparedTile(key: dataKey, layers: const {}, byteSize: 64);
        _memory.put(dataKey, empty);
        return empty;
      case TileBytesLoaded(:final bytes):
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
          if (!cancellation.isCancelled) {
            // Decode failure (corrupt tile): throttle retries.
            _bytes.noteFailure(dataKey);
          }
          return null;
        }
        _memory.put(dataKey, prepared);
        _bytes.noteSuccess(dataKey);
        return prepared;
    }
  }

  /// Stops this store. The decoded tiles stay in the shared memory cache on
  /// purpose — they are what lets the next map over this source paint
  /// immediately. Use [clearMemoryCaches] to release them.
  void dispose() {
    _disposed = true;
    _inFlight.clear();
    _bytes.dispose();
  }
}
