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
/// layer disposal and are only released by eviction, [removeWhere]
/// invalidation, [releaseSignature] or [clearAll].
///
/// Cost is dominated by GPU texture bytes: a tile is
/// `(256·dpr)² · 4` bytes ≈ 1 MiB at dpr 2, 2.25 MiB at dpr 3.
class TileResultCache {
  /// Keyed by render signature; the latest requested byte budget wins,
  /// mirroring the decoded-tile stores.
  ///
  /// Insertion order is the recency order [_trim] evicts by: every
  /// [forSignature] re-inserts its entry, so the current signature is
  /// always last.
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

  factory TileResultCache.forSignature(String signature, int maxBytes) {
    final cache = _registry.remove(signature) ?? TileResultCache._(maxBytes);
    cache._cache.setMaxCost(maxBytes);
    _registry[signature] = cache; // most recently used last
    _trim(maxBytes);
    return cache;
  }

  /// Bounds how many signatures stay retained, releasing the least
  /// recently used once their combined footprint exceeds [maxBytes].
  ///
  /// A signature is deliberately kept after its layer is gone, so that
  /// reopening the map paints instantly. Without a bound, every style,
  /// sprite sheet and device-pixel-ratio an app ever used would pin a
  /// full budget of GPU textures for the process lifetime.
  ///
  /// The two most recent are always kept, even over budget: two layers
  /// on screen over different styles take turns asking for their own
  /// cache, and a strict budget would have each release the other's on
  /// every tile load.
  static void _trim(int maxBytes) {
    var total = 0;
    for (final cache in _registry.values) {
      total += cache.totalCost;
    }
    for (final signature in _registry.keys.toList()) {
      if (total <= maxBytes || _registry.length <= 2) return;
      final cache = _registry.remove(signature)!;
      total -= cache.totalCost;
      cache.clear();
    }
  }

  /// Empties every cache. The registry keeps its (empty) entries — see
  /// `TileStore.clearMemoryCaches` for why dropping them would orphan
  /// caches that live layers still write into.
  static void clearAll() {
    for (final cache in _registry.values) {
      cache._cache.clear();
    }
  }

  /// Releases the textures held for [signature], if it has a cache.
  ///
  /// For layers turning the cache off at runtime: unlike [clearAll] this
  /// touches nothing else, and unlike [forSignature] it never creates an
  /// entry — asking about an unused signature must not mint a cache.
  static void releaseSignature(String signature) =>
      _registry[signature]?.clear();

  int get length => _cache.length;
  int get totalCost => _cache.totalCost;

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
    _cache.put(
      key,
      TileResult(image: image, symbols: symbols, renderedWith: renderedWith),
    );
  }

  /// Invalidates entries matching [test] (e.g. every display tile a
  /// refreshed data tile serves).
  void removeWhere(bool Function(TileKey key) test) =>
      _cache.removeWhere((key, _) => test(key));
}
