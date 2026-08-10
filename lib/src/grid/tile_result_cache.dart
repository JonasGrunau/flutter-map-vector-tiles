import 'dart:ui' as ui;

import '../cache/lru_cache.dart';
import '../core/tile_key.dart';
import '../render/symbol_layouter.dart';

/// A finished display tile: the rasterized geometry image plus the
/// symbol candidates extracted at the same style zoom.
///
/// The [image] handle is the cache's master — consumers take their own
/// `clone()` and never dispose the master; the cache disposes it on
/// eviction. The [symbols] list is shared by reference: one display key
/// implies one style zoom, and the per-instance memo fields are
/// idempotent, so concurrent holders are safe.
class TileResult {
  final ui.Image? image;
  final List<SymbolInstance> symbols;

  /// The source ids baked into the raster — restored onto the display
  /// tile so refresh logic can tell recovered sources apart.
  final Set<String> renderedWith;

  TileResult({
    required this.image,
    required this.symbols,
    required this.renderedWith,
  });
}

/// LRU of finished display tiles keyed by display [TileKey], one cache
/// per render signature (theme id, zoom offset, dpr, labels, sprites).
///
/// This is what makes revisiting a zoom level cheap: without it a
/// crossing re-rasterizes and re-extracts symbols for every tile, with
/// it the whole level swaps back in from GPU-resident images. Caches
/// are shared process-wide (like the decoded-tile stores) so a
/// reopened map over the same style paints instantly; entries survive
/// layer disposal and are only released by eviction, [removeKey]/
/// [removeWhere] invalidation, or [clearAll].
///
/// Cost is dominated by GPU texture bytes: a tile is
/// `(256·dpr)² · 4` bytes ≈ 1 MiB at dpr 2, 2.25 MiB at dpr 3.
class TileResultCache {
  /// Keyed by render signature; the latest requested byte budget wins,
  /// mirroring the decoded-tile stores.
  static final _registry = <String, TileResultCache>{};

  final LruCache<TileKey, TileResult> _cache;

  TileResultCache._(int maxBytes)
      : _cache = LruCache(
          maxEntries: 256,
          maxCost: maxBytes,
          costOf: (result) {
            final image = result.image;
            return (image == null ? 0 : image.width * image.height * 4) + 64;
          },
          onEvict: (_, result) => result.image?.dispose(),
        );

  factory TileResultCache.forSignature(String signature, int maxBytes) =>
      _registry.putIfAbsent(signature, () => TileResultCache._(maxBytes))
        .._cache.setMaxCost(maxBytes);

  /// Empties every cache. The registry keeps its (empty) entries — see
  /// `TileStore.clearMemoryCaches` for why dropping them would orphan
  /// caches that live layers still write into.
  static void clearAll() {
    for (final cache in _registry.values) {
      cache._cache.clear();
    }
  }

  int get length => _cache.length;
  int get totalCost => _cache.totalCost;

  void setMaxCost(int maxBytes) => _cache.setMaxCost(maxBytes);

  /// Drops every entry, disposing the master images.
  void clear() => _cache.clear();

  /// The cached result, promoted to most recently used. The caller
  /// clones [TileResult.image] before handing it to an owner.
  TileResult? get(TileKey key) => _cache.get(key);

  /// Stores a finished tile. Takes ownership of [image] — pass a clone
  /// dedicated to the cache, never the display tile's own handle.
  void put(
    TileKey key, {
    required ui.Image? image,
    required List<SymbolInstance> symbols,
    required Set<String> renderedWith,
  }) {
    if (_cache.maxCost == 0) {
      // Disabled: never hold a master.
      image?.dispose();
      return;
    }
    _cache.put(
      key,
      TileResult(image: image, symbols: symbols, renderedWith: renderedWith),
    );
  }

  void removeKey(TileKey key) {
    final removed = _cache.remove(key);
    removed?.image?.dispose();
  }

  /// Invalidates entries matching [test] (e.g. every display tile a
  /// refreshed data tile serves).
  void removeWhere(bool Function(TileKey key) test) =>
      _cache.removeWhere((key, _) => test(key));
}
