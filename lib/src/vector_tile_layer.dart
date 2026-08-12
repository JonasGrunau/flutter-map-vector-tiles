import 'dart:async';
import 'dart:developer' as developer;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide Theme;
import 'package:flutter/scheduler.dart';
import 'package:flutter_map/flutter_map.dart';

import 'cache/byte_cache.dart';
import 'cache/cache_resolver.dart';
import 'core/cancellation.dart';
import 'core/tile_key.dart';
import 'grid/grid_layout.dart';
import 'grid/raster_tile_store.dart';
import 'grid/render_job_queue.dart';
import 'grid/tile_byte_loader.dart';
import 'grid/tile_result_cache.dart';
import 'grid/tile_retention.dart';
import 'grid/tile_store.dart';
import 'logger.dart';
import 'pipeline/executor/executor.dart';
import 'pipeline/prepared_tile.dart';
import 'render/display_tile_data.dart';
import 'render/fade.dart';
import 'render/label_continuity.dart';
import 'render/label_painter.dart';
import 'render/pattern_resolver.dart';
import 'render/symbol_layouter.dart';
import 'render/tile_rasterizer.dart';
import 'style/sprite_atlas.dart';
import 'style/theme.dart';
import 'tile_offset.dart';
import 'tile_providers.dart';

/// A vector tile layer for `flutter_map`, drawing a MapLibre-style
/// [Theme] from MVT tile sources.
///
/// ```dart
/// FlutterMap(
///   options: MapOptions(...),
///   children: [
///     VectorTileLayer(
///       theme: style.theme,
///       tileProviders: style.providers,
///       rasterSources: style.rasterSources,
///       sprites: style.sprites,
///     ),
///   ],
/// )
/// ```
class VectorTileLayer extends StatefulWidget {
  /// The compiled style to render.
  final Theme theme;

  /// Tile sources keyed by style source id. The layer does not take
  /// ownership: dispose them (or the [Style] that created them) after
  /// the map is disposed.
  final TileProviders tileProviders;

  /// Raster sources referenced by the style's `raster` layers, keyed by
  /// style source id (satellite/hybrid imagery, pre-rendered
  /// hillshading). Populated by `StyleReader` for styles that declare
  /// them; the layer does not take ownership.
  final Map<String, RasterTileSource> rasterSources;

  /// Sprite atlas for icon rendering (optional).
  final SpriteAtlas? sprites;

  /// See [TileOffset]. Defaults to [TileOffset.maplibre], which renders
  /// MapLibre-authored styles (MapTiler etc.) exactly as designed.
  final TileOffset tileOffset;

  /// Number of background isolates decoding tiles.
  final int concurrency;

  /// Maximum size of the tile byte cache on disk. Zero disables disk
  /// caching. Has no effect on web (no disk cache).
  final int diskCacheMaximumSizeInBytes;

  /// Freshness window for disk-cached tiles: tiles younger than this are
  /// served without touching the network. Older tiles are still served
  /// instantly but revalidated in the background
  /// (stale-while-revalidate): when the refetch delivers changed data
  /// the tile cross-fades to it, and when the network is unavailable the
  /// old imagery simply stays. Mind your tile provider's terms. Has no
  /// effect on web (no disk cache).
  final Duration diskCacheTtl;

  /// Resolves the disk cache directory path; defaults to a subdirectory
  /// of the application support directory, which — unlike the temporary
  /// directory — the OS does not purge, so recently viewed areas stay
  /// available offline.
  ///
  /// Ignored on web, which has no persistent tile cache: tiles fall back
  /// to the in-memory cache and the browser's own HTTP cache.
  final Future<String> Function()? cachePath;

  /// Memory budget for decoded tile data, per source. The caches are
  /// shared process-wide, so when several layers (or successive mounts)
  /// use the same source, the most recently applied value wins.
  final int memoryCacheMaxBytes;

  /// Duration of the fade-in of newly rasterized tiles.
  final Duration tileFadeDuration;

  /// Duration of the fade-in of newly appearing labels/icons, masking
  /// the pop when a zoom level first shows symbol layers. Zero disables
  /// the fade (labels appear instantly, as before 2.3.0).
  final Duration labelFadeDuration;

  /// Byte budget for finished display tiles (rasterized geometry plus
  /// extracted symbols), kept so that zooming back to a recently shown
  /// level swaps its imagery in instead of re-rendering it. Shared
  /// process-wide per style, like [memoryCacheMaxBytes]. Zero disables.
  ///
  /// These are GPU texture bytes: one tile costs `(256·dpr)²·4` bytes —
  /// ~1 MiB at devicePixelRatio 2, ~2.25 MiB at 3 — and one phone
  /// viewport is ~25-35 tiles per zoom level. The default 64 MiB holds
  /// roughly two levels at dpr 2 and one at dpr 3; raise it on dpr-3
  /// devices if zoom round-trips should stay entirely warm.
  final int rasterCacheMaxBytes;

  /// Whether to draw text/icon symbol layers.
  final bool showLabels;

  final Logger logger;

  const VectorTileLayer({
    super.key,
    required this.theme,
    required this.tileProviders,
    this.rasterSources = const {},
    this.sprites,
    this.tileOffset = TileOffset.maplibre,
    this.concurrency = 3,
    this.diskCacheMaximumSizeInBytes = 50 * 1024 * 1024,
    this.diskCacheTtl = const Duration(days: 14),
    this.cachePath,
    this.memoryCacheMaxBytes = 24 * 1024 * 1024,
    this.tileFadeDuration = const Duration(milliseconds: 150),
    this.labelFadeDuration = const Duration(milliseconds: 150),
    this.rasterCacheMaxBytes = 64 * 1024 * 1024,
    this.showLabels = true,
    this.logger = const Logger.noop(),
  });

  /// Releases the decoded tiles held in memory between map opens.
  ///
  /// Decoded tiles outlive the layer that loaded them so that reopening a map
  /// paints immediately instead of decoding everything again. They are capped
  /// by [memoryCacheMaxBytes] per source and style, but nothing else frees
  /// them — call this from a memory-pressure handler if that budget is too
  /// generous for your app. Visible maps keep their rasterized imagery; only
  /// tiles panned to afterwards are re-read from disk.
  static void clearMemoryCache() {
    TileStore.clearMemoryCaches();
    RasterTileStore.clearMemoryCaches();
    TileResultCache.clearAll();
  }

  @override
  State<VectorTileLayer> createState() => _VectorTileLayerState();
}

class _VectorTileLayerState extends State<VectorTileLayer>
    with TickerProviderStateMixin {
  late TilePrepareExecutor _executor;
  late final Future<ByteCache?> _diskCache;
  final _stores = <String, TileStore>{};
  final _rasterStores = <String, RasterTileStore>{};
  final _tiles = <TileKey, _DisplayTile>{};

  /// Tiles of other zoom levels kept until the current level is ready.
  final _retained = <TileKey, _DisplayTile>{};

  /// Per-tile render jobs (rasterize, then symbol extraction), drained
  /// a few per frame by the render pump.
  late final _renderQueue =
      RenderJobQueue<_DisplayTile, _RenderJob>(onDrop: (job) => job.dispose());

  final _repaint = _RepaintNotifier();
  final _labelPainter = LabelPainter();
  PatternResolver? _patterns;
  late final Ticker _fadeTicker;
  late final Ticker _renderTicker;
  var _fading = false;
  int? _currentZoom;
  var _generation = 0;

  /// The grid of the previous build — see `_updateGrid`'s early-out.
  GridLayout? _lastLayout;

  /// Retained tiles whose labels must keep painting, memoized because
  /// its inputs (grid membership, tile load/symbol states) change on
  /// discrete events, not per frame — the label pass would otherwise
  /// re-derive it every frame of a zoom transition. Null = recompute.
  Set<TileKey>? _retainedSymbolKeys;

  /// Labels the outgoing zoom level was showing that the arriving one
  /// has no counterpart for, kept just long enough to fade out — see
  /// [_handOverRetainedLabels]. Holds only Dart objects: the tiles they
  /// came from are disposed on the usual schedule, so no tile texture is
  /// pinned by a fade.
  final _fadingLabels = <_FadingLabels>[];

  /// Bounded retries for tiles that finalized with a source missing
  /// after a transient failure. Fired just past the stores' failure
  /// throttle, so each attempt can actually reach the network again.
  static const _maxLoadRetries = 4;
  Duration get _loadRetryDelay =>
      TileByteLoader.errorRetryDelay + const Duration(seconds: 1);

  @override
  void initState() {
    super.initState();
    _executor = TilePrepareExecutor(concurrency: widget.concurrency);
    _fadeTicker = createTicker(_onFadeTick);
    _renderTicker = createTicker(_pumpRenderQueue);
    _diskCache = _obtainDiskCache();
    _buildStores();
  }

  /// The stores hold this future and await it before reaching for the
  /// network, so tiles requested on the first frame — before the cache has
  /// finished initializing — still come off disk.
  Future<ByteCache?> _obtainDiskCache() {
    if (widget.diskCacheMaximumSizeInBytes <= 0) return Future.value();
    return obtainTileCache(
      cachePath: widget.cachePath,
      ttl: widget.diskCacheTtl,
      maxSizeBytes: widget.diskCacheMaximumSizeInBytes,
      logger: widget.logger,
    );
  }

  void _buildStores() {
    for (final store in _stores.values) {
      store.dispose();
    }
    _stores.clear();
    for (final store in _rasterStores.values) {
      store.dispose();
    }
    _rasterStores.clear();

    // Per source: source-layer -> union of referenced property names.
    final propsBySource = <String, Map<String, Set<String>?>>{};
    for (final layer in widget.theme.layers) {
      final source = layer.source;
      final sourceLayer = layer.sourceLayer;
      if (source == null || sourceLayer == null) continue;
      final bySourceLayer = propsBySource[source] ??= {};
      if (bySourceLayer.containsKey(sourceLayer)) {
        final existing = bySourceLayer[sourceLayer];
        final incoming = layer.referencedProperties;
        bySourceLayer[sourceLayer] = (existing == null || incoming == null)
            ? null
            : {...existing, ...incoming};
      } else {
        bySourceLayer[sourceLayer] = layer.referencedProperties?.toSet();
      }
    }

    widget.tileProviders.providers.forEach((sourceId, provider) {
      final layerProperties = propsBySource[sourceId];
      if (layerProperties == null) return; // source unused by theme
      final store = TileStore(
        provider: provider,
        executor: _executor,
        layerProperties: layerProperties,
        diskCache: _diskCache,
        memoryCacheMaxBytes: widget.memoryCacheMaxBytes,
        logger: widget.logger,
      );
      store.onRefreshed = (dataKey) => _reloadRefreshed(
          (displayKey) =>
              store.dataKeyFor(displayKey, widget.tileOffset.zoomOffset),
          dataKey);
      _stores[sourceId] = store;
    });

    final rasterSourceIds = <String>{
      for (final layer in widget.theme.layers)
        if (layer is RasterThemeLayer && layer.source != null) layer.source!,
    };
    widget.rasterSources.forEach((sourceId, source) {
      if (!rasterSourceIds.contains(sourceId)) return; // unused by theme
      final store = RasterTileStore(
        source: source,
        diskCache: _diskCache,
        memoryCacheMaxBytes: widget.memoryCacheMaxBytes,
        logger: widget.logger,
      );
      store.onRefreshed = (dataKey) => _reloadRefreshed(
          (displayKey) =>
              store.dataKeyFor(displayKey, widget.tileOffset.zoomOffset),
          dataKey);
      _rasterStores[sourceId] = store;
    });

    _generation++;
    _clearTiles();
  }

  void _clearTiles() {
    _renderQueue.clear();
    for (final tile in _tiles.values) {
      tile.dispose();
    }
    _tiles.clear();
    for (final tile in _retained.values) {
      tile.dispose();
    }
    _retained.clear();
    _retainedSymbolKeys = null;
    _fadingLabels.clear();
    _currentZoom = null;
    // Without this the next _updateGrid would see an unchanged grid and
    // skip recreating the tiles it just cleared.
    _lastLayout = null;
  }

  @override
  void didUpdateWidget(covariant VectorTileLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    var refresh = false;
    if (oldWidget.sprites != widget.sprites) {
      // Fill/line patterns are baked into the rasters, so live tiles
      // must be re-rasterized with the new atlas.
      _patterns?.dispose();
      _patterns = null;
      refresh = true;
    }
    // Symbols are laid out at rasterize time; the paint pass checks the
    // flag per frame, so disabling hides labels immediately but enabling
    // needs the live tiles re-laid-out.
    if (widget.showLabels && !oldWidget.showLabels) refresh = true;
    if (oldWidget.memoryCacheMaxBytes != widget.memoryCacheMaxBytes) {
      for (final store in _stores.values) {
        store.memoryCacheMaxBytes = widget.memoryCacheMaxBytes;
      }
      for (final store in _rasterStores.values) {
        store.memoryCacheMaxBytes = widget.memoryCacheMaxBytes;
      }
    }
    if (oldWidget.rasterCacheMaxBytes != widget.rasterCacheMaxBytes &&
        widget.rasterCacheMaxBytes <= 0) {
      // Disabled at runtime: release the textures held for what this
      // layer was rendering. The *old* widget names that cache — this
      // update may also have changed the theme or sprites, and clearing
      // the new signature would leave the actual textures behind.
      // (Shrinking to a smaller budget is handled by `forSignature` on
      // next access.)
      TileResultCache.releaseSignature(
          _signatureOf(oldWidget, _devicePixelRatio));
    }
    if (oldWidget.theme != widget.theme ||
        oldWidget.tileProviders != widget.tileProviders ||
        oldWidget.rasterSources != widget.rasterSources ||
        oldWidget.tileOffset.zoomOffset != widget.tileOffset.zoomOffset) {
      _buildStores();
    } else if (refresh) {
      _refreshTiles();
    }
  }

  /// Re-rasterizes every live tile from already-decoded data — for
  /// widget changes that alter what is baked into the raster or the
  /// symbol set (sprites, showLabels) without changing the data. The
  /// old imagery stays on screen until its replacement is ready, and
  /// nothing re-fades.
  void _refreshTiles() {
    for (final tile in _tiles.values) {
      tile.renderedWith = null; // identical sources must still re-enqueue
      tile.loadGeneration++;
      unawaited(_loadTile(tile, 0, fadeIn: false));
    }
  }

  /// A background revalidation replaced [refreshed]'s decoded content —
  /// re-rasterize the visible display tiles it serves. The new raster
  /// cross-fades over the old imagery (see [_DisplayTile.setImage]).
  void _reloadRefreshed(
    TileKey? Function(TileKey displayKey) dataKeyOf,
    TileKey refreshed,
  ) {
    if (!mounted) return;
    // Finished results built from the replaced content are stale too —
    // including cached display tiles not currently on screen.
    _resultCache
        ?.removeWhere((displayKey) => dataKeyOf(displayKey) == refreshed);
    for (final tile in _tiles.values.toList()) {
      if (dataKeyOf(tile.key) != refreshed) continue;
      tile.renderedWith = null; // identical source set must still re-enqueue
      tile.loadGeneration++;
      unawaited(_loadTile(tile, 0));
    }
    // Retained tiles are on their way out and are not worth re-rendering,
    // but their queued jobs still hold the replaced sources. Retiring
    // the generation drops those jobs, so none of them can publish the
    // old content or write it back into the cache just invalidated.
    for (final tile in _retained.values) {
      if (dataKeyOf(tile.key) == refreshed) tile.loadGeneration++;
    }
  }

  /// Revalidates the data tiles behind [tile] when their disk entries
  /// have expired.
  ///
  /// Only for tiles served from the finished-result cache: every other
  /// path reaches the stores, which run this check as part of loading.
  /// The stores skip data tiles still held in memory (those were loaded
  /// — and so checked — during this process), so this costs a disk stat
  /// only for tiles whose rendered result outlived their source data.
  void _revalidateSourcesOf(_DisplayTile tile) {
    final offset = widget.tileOffset.zoomOffset;
    for (final store in _stores.values) {
      final dataKey = store.dataKeyFor(tile.key, offset);
      if (dataKey != null) store.revalidateIfStale(dataKey);
    }
    for (final store in _rasterStores.values) {
      final dataKey = store.dataKeyFor(tile.key, offset);
      if (dataKey != null) store.revalidateIfStale(dataKey);
    }
  }

  PatternResolver? get _patternResolver {
    final sprites = widget.sprites;
    if (sprites == null) return null;
    return _patterns ??= PatternResolver(sprites);
  }

  /// Everything that determines what a finished display tile looks
  /// like. Anything that would render differently must land in a
  /// different cache — providers by their cache keys (same theme over
  /// different endpoints must not collide), sprites by their content
  /// signature, the theme by its documented cache id. Widget changes
  /// that re-rasterize (sprites, showLabels) therefore simply miss the
  /// old cache.
  ///
  /// The sprite atlas contributes [SpriteAtlas.signature], not its
  /// object identity: re-reading a style yields a new atlas every time,
  /// so identity would mint a fresh cache on every map open and strand
  /// the previous one.
  static String _signatureOf(VectorTileLayer widget, double devicePixelRatio) {
    final providers = [
      for (final entry in widget.tileProviders.providers.entries)
        '${entry.key}=${entry.value.cacheKey}',
      for (final entry in widget.rasterSources.entries)
        'raster:${entry.key}=${entry.value.provider.cacheKey}',
    ]..sort();
    return '${widget.theme.id}|${widget.tileOffset.zoomOffset}|'
        '$devicePixelRatio|${widget.showLabels}|'
        '${widget.sprites?.signature}|${providers.join(',')}';
  }

  /// Memoized [_signatureOf] for the current widget: it is consulted on
  /// every tile load, store and invalidation, while its inputs only
  /// change when the widget is replaced or the screen's pixel ratio
  /// does. Sorting and joining the provider list per access was pure
  /// waste at a zoom crossing.
  String? _signature;
  VectorTileLayer? _signatureWidget;
  double? _signatureDpr;

  String get _resultSignature {
    final dpr = _devicePixelRatio;
    final cached = _signature;
    if (cached != null &&
        identical(_signatureWidget, widget) &&
        _signatureDpr == dpr) {
      return cached;
    }
    _signatureWidget = widget;
    _signatureDpr = dpr;
    return _signature = _signatureOf(widget, dpr);
  }

  /// The finished-tile cache for the current render signature, shared
  /// process-wide so a reopened map paints instantly. Null when
  /// disabled via [VectorTileLayer.rasterCacheMaxBytes] — the one place
  /// that decides whether this layer caches at all.
  TileResultCache? get _resultCache => widget.rasterCacheMaxBytes <= 0
      ? null
      : TileResultCache.forSignature(
          _resultSignature, widget.rasterCacheMaxBytes);

  @override
  void dispose() {
    _fadeTicker.dispose();
    _renderTicker.dispose();
    _clearTiles();
    for (final store in _stores.values) {
      store.dispose();
    }
    _stores.clear();
    for (final store in _rasterStores.values) {
      store.dispose();
    }
    _rasterStores.clear();
    _executor.dispose();
    _labelPainter.dispose();
    _patterns?.dispose();
    _repaint.dispose();
    super.dispose();
  }

  double _styleZoomOf(double displayZoom) =>
      math.max(0, displayZoom + widget.tileOffset.zoomOffset);

  void _updateGrid(MapCamera camera) {
    final layout = GridLayout.forCamera(camera, buffer: 1);

    // The integer tile bounds only change when the viewport crosses a
    // tile boundary or the zoom floor moves; on most gesture frames the
    // grid is identical and the remove/create scans (plus
    // keysByDistance's allocation and sort) would be pure waste.
    if (layout == _lastLayout) {
      _pruneRetained(camera, layout);
      return;
    }
    _lastLayout = layout;

    if (_currentZoom != layout.displayZoom) {
      // Fades still running belong to the level being replaced now, and
      // their labels were laid out two levels back. Drop them rather
      // than let them trail a second transition — zooming back reinstates
      // the real level anyway.
      _fadingLabels.clear();
      // Keep the previous level's imagery underneath until the new level
      // is rasterized — this is what prevents white flicker on zoom.
      for (final entry in _tiles.entries) {
        final existing = _retained[entry.key];
        if (existing != null && !identical(existing, entry.value)) {
          _disposeTile(existing);
        }
        // Retained tiles paint at full opacity, so their cross-fade
        // underlay is never drawn again — and the fade tick that would
        // release it only walks the current level. Left alone it pins a
        // second full-tile texture for the whole retention window.
        entry.value.disposeUnderlay();
        _retained[entry.key] = entry.value;
      }
      _tiles.clear();
      _currentZoom = layout.displayZoom;
    }

    // Drop tiles that left the viewport.
    final toRemove = <TileKey>[];
    _tiles.forEach((key, tile) {
      if (!layout.contains(key)) toRemove.add(key);
    });
    for (final key in toRemove) {
      final tile = _tiles.remove(key);
      if (tile != null) _disposeTile(tile);
    }

    // Create/load missing tiles, centre first.
    for (final key in layout.keysByDistance()) {
      if (_tiles.containsKey(key)) continue;
      final tile = _DisplayTile(key);
      _tiles[key] = tile;
      unawaited(_loadTile(tile, layout.priorityOf(key)));
    }
    _retainedSymbolKeys = null;

    _pruneRetained(camera, layout);
  }

  /// The current-level tiles, described for the retention rules in
  /// `grid/tile_retention.dart`. A tile whose raster landed but whose
  /// symbol extraction is still queued counts as loading: the retained
  /// level's labels must keep covering it or every label would blink
  /// out for the frames between the two phases.
  Iterable<CurrentTileStatus> _currentStatuses(DateTime now) =>
      _tiles.values.map((t) => (
            key: t.key,
            isLoading: t.state == _TileState.loading || t.symbolsPending,
            hasSymbols: t.symbols.isNotEmpty,
            isFadedIn: t.fadeProgress(now, widget.tileFadeDuration) >= 1,
          ));

  /// Recomputes [_retainedSymbolKeys] — called lazily from the label
  /// pass after any event invalidated it.
  Set<TileKey> _retainedKeysWithSymbols() {
    final current = _currentStatuses(DateTime.now()).toList();
    return {
      for (final retained in _retained.values)
        if (retainedSymbolsNeeded(
          retainedKey: retained.key,
          hasSymbols: retained.symbols.isNotEmpty,
          current: current,
        ))
          retained.key,
    };
  }

  void _pruneRetained(MapCamera camera, GridLayout layout) {
    if (_retained.isEmpty) return;
    final now = DateTime.now();
    final allReady = currentLevelReady(_currentStatuses(now));
    final viewport = camera.pixelBounds;
    final toRemove = <TileKey>[];
    _retained.forEach((key, tile) {
      if (allReady ||
          tile.image == null ||
          !displayTileRect(key, camera.zoom).overlaps(viewport)) {
        toRemove.add(key);
      }
    });
    for (final key in toRemove) {
      final tile = _retained.remove(key);
      if (tile != null) _disposeTile(tile);
    }
    if (toRemove.isNotEmpty) _retainedSymbolKeys = null;
  }

  /// Disposes a tile that has left the grid, dropping any jobs still
  /// queued for it first — those jobs own cloned raster image handles,
  /// and waiting for the pump to reach them holds that GPU memory (and
  /// the tile object) for as many frames as the queue is deep.
  void _disposeTile(_DisplayTile tile) {
    _renderQueue.remove(tile);
    tile.dispose();
  }

  Future<void> _loadTile(
    _DisplayTile tile,
    int priority, {
    bool fadeIn = true,
  }) async {
    final generation = _generation;
    final tileGeneration = tile.loadGeneration;
    final offset = widget.tileOffset.zoomOffset;

    // A finished result for this display tile skips the stores and the
    // render pump entirely — this is what makes returning to a recently
    // shown zoom level free. Only fresh tiles consult it: the refresh
    // and revalidation paths reset `renderedWith` after invalidating
    // their cache entries, so they can never be served stale content.
    if (tile.renderedWith == null) {
      final cached = _resultCache?.get(tile.key);
      if (cached != null) {
        tile.renderedWith = cached.renderedWith;
        tile.setImage(
          image: cached.image?.clone(),
          provisional: false,
          fadeIn: fadeIn && widget.tileFadeDuration > Duration.zero,
          symbolsPending: true,
        );
        _publishSymbols(tile, cached.symbols);
        // These labels never passed through the render pump, so nothing
        // has shaped their text — without this the first frame after a
        // reopen shapes a whole screenful of paragraphs inside paint.
        if (cached.symbols.isNotEmpty) {
          _labelPainter.prewarm(
              cached.symbols, _styleZoomOf(tile.key.z.toDouble()));
        }
        _retainedSymbolKeys = null;
        _repaint.trigger();
        _ensureFadeTicker();
        // Serving a rendered result bypasses the stores, and with them
        // the freshness check that would have revalidated an expired
        // data tile. Run it separately, or a cached level stays at
        // whatever it was rendered from for as long as it survives.
        _revalidateSourcesOf(tile);
        return;
      }
    }
    final sources = <String, PreparedTile>{};
    final pending = <String, Future<PreparedTile?>>{};
    final rasters = <String, RasterTile>{};
    final pendingRasters = <String, Future<RasterTile?>>{};

    // The vector and raster pipelines differ in type but not in shape;
    // one collector serves both. (Raster obtains carry no priority —
    // image decode has no executor queue to order, unlike tile
    // preparation.)
    void collect<S, T extends Object>(
      Map<String, S> stores,
      TileKey? Function(S store) dataKeyOf,
      T? Function(S store, TileKey key) peekIn,
      Future<T?> Function(S store, TileKey key) obtainFrom,
      Map<String, T> ready,
      Map<String, Future<T?>> pendingOut,
    ) {
      stores.forEach((id, store) {
        final dataKey = dataKeyOf(store);
        if (dataKey == null) return;
        final cached = peekIn(store, dataKey);
        if (cached != null) {
          ready[id] = cached;
        } else {
          pendingOut[id] = obtainFrom(store, dataKey);
        }
      });
    }

    collect(
      _stores,
      (s) => s.dataKeyFor(tile.key, offset),
      (s, k) => s.peek(k),
      (s, k) =>
          s.obtain(k, priority: priority, cancellation: tile.cancellation),
      sources,
      pending,
    );
    collect(
      _rasterStores,
      (s) => s.dataKeyFor(tile.key, offset),
      (s, k) => s.peek(k),
      (s, k) => s.obtain(k, cancellation: tile.cancellation),
      rasters,
      pendingRasters,
    );

    if (pending.isNotEmpty || pendingRasters.isNotEmpty) {
      // Render a provisional image from already-decoded ancestors so
      // fast zoom-ins never show blank tiles.
      void addAncestors<S extends Object, T extends Object>(
        Map<String, S> stores,
        Iterable<String> pendingIds,
        TileKey? Function(S store) dataKeyOf,
        T? Function(S store, TileKey key) peekAncestors,
        Map<String, T> into,
      ) {
        for (final id in pendingIds) {
          final store = stores[id]!;
          final dataKey = dataKeyOf(store);
          final ancestor =
              dataKey == null ? null : peekAncestors(store, dataKey);
          if (ancestor != null) into[id] = ancestor;
        }
      }

      final provisionalSources = Map.of(sources);
      addAncestors(_stores, pending.keys, (s) => s.dataKeyFor(tile.key, offset),
          (s, k) => s.peekWithAncestors(k), provisionalSources);
      final provisionalRasters = <String, RasterTile>{
        for (final entry in rasters.entries) entry.key: entry.value.retain(),
      };
      addAncestors(
          _rasterStores,
          pendingRasters.keys,
          (s) => s.dataKeyFor(tile.key, offset),
          (s, k) => s.peekWithAncestors(k),
          provisionalRasters);
      if (provisionalSources.isNotEmpty || provisionalRasters.isNotEmpty) {
        _enqueueRaster(tile, provisionalSources,
            rasters: provisionalRasters, provisional: true, priority: priority);
      }
      for (final entry in pending.entries) {
        final prepared = await entry.value;
        if (prepared != null) sources[entry.key] = prepared;
      }
      for (final entry in pendingRasters.entries) {
        final raster = await entry.value;
        if (raster != null) rasters[entry.key] = raster;
      }
    }

    if (!mounted ||
        generation != _generation ||
        tileGeneration != tile.loadGeneration ||
        tile.cancellation.isCancelled) {
      // Includes the case where the content changed while this load was
      // awaiting: publishing now would show — and cache — sources that
      // were replaced, and would make the reload look like a no-op.
      for (final raster in rasters.values) {
        raster.dispose();
      }
      return;
    }

    // A source that was awaited but never arrived failed transiently
    // (network loss, 5xx) — NotFound answers arrive as empty tiles, and
    // known-absent rasters are permanent. The stores throttle failed
    // keys but never re-ask on their own, so without a retry here the
    // tile would stay blank or partial until recreated.
    final missing = pending.keys.any((id) => !sources.containsKey(id)) ||
        pendingRasters.keys.any((id) {
          if (rasters.containsKey(id)) return false;
          final store = _rasterStores[id]!;
          final dataKey =
              store.dataKeyFor(tile.key, widget.tileOffset.zoomOffset);
          return dataKey != null && !store.knownAbsent(dataKey);
        });

    final resolved = {
      ...sources.keys,
      for (final id in rasters.keys) 'raster:$id',
    };
    if (setEquals(tile.renderedWith, resolved)) {
      // A retry that recovered nothing: re-rasterizing identical content
      // would only restart the fade. _enqueueRaster would take ownership
      // of the handles, so release them here instead.
      for (final raster in rasters.values) {
        raster.dispose();
      }
    } else {
      tile.renderedWith = resolved;
      tile.retryAttempt = 0; // progress restores the retry budget
      _enqueueRaster(tile, sources,
          rasters: rasters,
          provisional: false,
          priority: priority,
          fadeIn: fadeIn,
          complete: !missing);
    }

    if (missing && tile.retryAttempt < _maxLoadRetries) {
      tile.retryAttempt++;
      tile.scheduleRetry(_loadRetryDelay, () {
        if (!mounted || generation != _generation) return;
        unawaited(_loadTile(tile, priority));
      });
    }
  }

  /// Rasterization happens on the UI thread (`Picture.toImageSync`), so
  /// completed tiles are queued and processed within a per-frame time
  /// budget instead of all at once — with warm caches a zoom-level
  /// change completes every tile in the same instant, and rasterizing
  /// ~20 tiles in one frame drops frames. Each tile passes through two
  /// queue phases — geometry raster, then symbol extraction — so a
  /// crossing shows imagery for the whole viewport before it pays for
  /// any labels, and the worst single-job overrun is halved.
  /// Takes ownership of [rasters]: the handles are disposed with the job,
  /// whether it is painted, replaced or rejected.
  void _enqueueRaster(
    _DisplayTile tile,
    Map<String, PreparedTile> sources, {
    Map<String, RasterTile> rasters = const {},
    required bool provisional,
    required int priority,
    bool fadeIn = true,
    bool complete = false,
  }) {
    final job = _RenderJob(
        sources: sources,
        rasters: rasters,
        provisional: provisional,
        priority: priority,
        fadeIn: fadeIn,
        complete: complete,
        generation: tile.loadGeneration);
    if (tile.cancellation.isCancelled) {
      job.dispose();
      return;
    }
    if (provisional) {
      // Provisional imagery stands in for content that has not arrived
      // yet; it must never displace content that has. Each of these
      // says final content is already here or on its way, and accepting
      // the provisional job would undo it: the tile's own raster would
      // be disposed and its state flipped back to loading — which a
      // retry recovering nothing then never leaves, because an
      // unchanged source set skips the final re-enqueue.
      final queuedRaster = _renderQueue.pendingRaster(tile);
      final queuedSymbols = _renderQueue.pendingSymbols(tile);
      if ((queuedRaster != null && !queuedRaster.provisional) ||
          (queuedSymbols != null && !queuedSymbols.provisional) ||
          (!tile.isProvisional && tile.image != null)) {
        job.dispose();
        return;
      }
    }
    _renderQueue.enqueueRaster(tile, priority, job);
    // The accepted raster decides anew whether symbols will follow
    // (any pending symbol job for this tile was just superseded).
    tile.symbolsPending = _symbolsFollow(tile, sources);
    // That flag feeds the retained-label decision: a tile awaiting
    // symbols keeps the previous level's labels covering it.
    _retainedSymbolKeys = null;
    if (!_renderTicker.isActive) _renderTicker.start();
  }

  /// Whether a raster job for [tile] will be followed by a symbol
  /// phase. False below the first symbol layer's minzoom, so zooms
  /// without labels never pay for the extra phase.
  bool _symbolsFollow(_DisplayTile tile, Map<String, PreparedTile> sources) =>
      widget.showLabels &&
      sources.isNotEmpty &&
      SymbolLayouter.anySymbolLayerCovers(
          widget.theme, _styleZoomOf(tile.key.z.toDouble()));

  void _pumpRenderQueue(Duration _) {
    developer.Timeline.startSync('VT render pump');
    final stopwatch = Stopwatch()..start();
    var processed = 0;
    // At least one job per frame, more while within the time budget:
    // the viewport centre comes first, rasters before symbol jobs. The
    // budget is checked before every job — it cannot preempt inside
    // one, which is why a tile's two phases are separate jobs.
    while (!_renderQueue.isEmpty &&
        (processed == 0 || stopwatch.elapsedMicroseconds < 4000)) {
      final next = _renderQueue.pop()!;
      final tile = next.key;
      final job = next.job;
      // A job outlived by its tile's generation was built from content
      // that has since been replaced; running it would paint — and
      // cache — what the revalidation just invalidated.
      if (!tile.cancellation.isCancelled &&
          job.generation == tile.loadGeneration) {
        switch (next.phase) {
          case RenderPhase.raster:
            _rasterizeJob(tile, job);
          case RenderPhase.symbols:
            _layoutSymbolsJob(tile, job);
        }
        processed++;
      }
      job.dispose();
    }
    if (_renderQueue.isEmpty) _renderTicker.stop();
    developer.Timeline.finishSync();
  }

  void _rasterizeJob(_DisplayTile tile, _RenderJob job) {
    developer.Timeline.startSync('VT rasterize');
    final styleZoom = _styleZoomOf(tile.key.z.toDouble());
    final data = DisplayTileData(
        displayKey: tile.key, sources: job.sources, rasters: job.rasters);
    final image = TileRasterizer.rasterize(
      theme: widget.theme,
      data: data,
      styleZoom: styleZoom,
      devicePixelRatio: _devicePixelRatio,
      patterns: _patternResolver,
    );
    developer.Timeline.finishSync();

    final symbolsFollow = _symbolsFollow(tile, job.sources);
    tile.setImage(
      image: image,
      provisional: job.provisional,
      // With fades disabled no ticker runs to release an underlay, so
      // never create one — the swap is instant either way.
      fadeIn: job.fadeIn && widget.tileFadeDuration > Duration.zero,
      symbolsPending: symbolsFollow,
    );
    if (symbolsFollow) {
      // The symbol phase reuses the prepared sources; the raster
      // handles are not carried over — they die with this job.
      _renderQueue.enqueueSymbols(
          tile,
          job.priority,
          _RenderJob(
            sources: job.sources,
            rasters: const {},
            provisional: job.provisional,
            priority: job.priority,
            fadeIn: job.fadeIn,
            complete: job.complete,
            generation: job.generation,
          ));
    } else {
      // Still a publish: a tile that finishes with no labels at all is
      // what hands the retained level's labels over to the fade-out.
      _publishSymbols(tile, const []);
      _cacheResult(tile, job);
    }
    _retainedSymbolKeys = null;
    _repaint.trigger();
    _ensureFadeTicker();
  }

  void _layoutSymbolsJob(_DisplayTile tile, _RenderJob job) {
    developer.Timeline.startSync('VT symbols');
    final styleZoom = _styleZoomOf(tile.key.z.toDouble());
    final data = DisplayTileData(
        displayKey: tile.key, sources: job.sources, rasters: const {});
    final symbols = SymbolLayouter.layout(
        theme: widget.theme, data: data, styleZoom: styleZoom);
    // Shape the labels' text now, inside the budgeted tick — the next
    // paint finds everything in the text caches instead of shaping a
    // whole tile's labels during the paint phase.
    if (symbols.isNotEmpty) _labelPainter.prewarm(symbols, styleZoom);
    developer.Timeline.finishSync();

    _publishSymbols(tile, symbols);
    _cacheResult(tile, job);
    _retainedSymbolKeys = null;
    _repaint.trigger();
    _ensureFadeTicker();
  }

  /// Stores a finished tile in the result cache — final, fully sourced
  /// results only, so a cache hit can never mask a pending retry.
  void _cacheResult(_DisplayTile tile, _RenderJob job) {
    if (job.provisional || !job.complete) return;
    _resultCache?.put(
      tile.key,
      image: tile.image?.clone(),
      symbols: tile.symbols,
      renderedWith: tile.renderedWith ?? const {},
    );
  }

  /// Publishes [symbols] as [tile]'s labels, fading in only the ones the
  /// previous zoom level is not already showing over it.
  ///
  /// Every integer zoom crossing replaces the whole display level, so
  /// without this the arriving tiles — new objects, with no fade history
  /// — would fade their entire cohort in from zero while the retained
  /// level still draws the same labels at full opacity. The two copies
  /// then compete for the same collision space, and the winner is
  /// decided by a sub-pixel difference in anchor position, so a label
  /// would blink or (under `*-allow-overlap`) composite over itself for
  /// the length of the fade.
  void _publishSymbols(_DisplayTile tile, List<SymbolInstance> symbols) {
    final partitioned =
        partitionCarriedOver(symbols, _coveringLabelKeys(tile.key));
    tile.setSymbols(
      partitioned.symbols,
      carriedCount: partitioned.carriedCount,
      // A cohort the previous level covers entirely has nothing to mask.
      fadeIn: partitioned.carriedCount < partitioned.symbols.length &&
          widget.labelFadeDuration > Duration.zero,
    );
    _handOverRetainedLabels();
  }

  /// Starts a fade-out for the labels a retained tile is about to stop
  /// drawing and the arriving level does not replace.
  ///
  /// Publishing a cohort is what flips a retained tile from "still
  /// needed" to "done" — up to now that dropped its labels in one frame,
  /// so a label the tileset stops carrying at the next zoom vanished the
  /// instant the tiles finished loading. The ones the new level does
  /// carry are already covered: it draws them itself, at full opacity.
  /// The rest are orphans, and they are what fades.
  void _handOverRetainedLabels() {
    if (widget.labelFadeDuration <= Duration.zero || _retained.isEmpty) return;
    final current = _currentStatuses(DateTime.now()).toList();
    for (final retained in _retained.values) {
      if (retained.symbols.isEmpty || retained.labelsHandedOver) continue;
      if (retainedSymbolsNeeded(
        retainedKey: retained.key,
        hasSymbols: true,
        current: current,
      )) {
        continue;
      }
      retained.labelsHandedOver = true;
      final orphans = orphanedLabels(
        retained.symbols,
        // What the arriving level puts in this tile's place.
        labelContinuityKeys([
          for (final tile in _tiles.values)
            if (tilesOverlap(retained.key, tile.key)) tile.symbols,
        ]),
      );
      if (orphans.isEmpty) continue;
      _fadingLabels.add((
        key: retained.key,
        symbols: orphans,
        startedAt: DateTime.now(),
      ));
      _ensureFadeTicker();
    }
  }

  /// Drops fade-outs that have finished. Returns whether any is still
  /// running, so the fade ticker knows to keep going.
  bool _expireFadingLabels(DateTime now) {
    _fadingLabels.removeWhere((fading) =>
        fadeProgressOf(fading.startedAt, now, widget.labelFadeDuration) >= 1);
    return _fadingLabels.isNotEmpty;
  }

  /// The continuity keys of the labels the retained (previous) level is
  /// currently showing over [key]. Empty in the steady state, where
  /// nothing is retained — panning and first load keep fading normally.
  Set<Object> _coveringLabelKeys(TileKey key) => _retained.isEmpty
      ? const {}
      : coveringLabelKeys(key, [
          for (final retained in _retained.values)
            (key: retained.key, symbols: retained.symbols),
        ]);

  void _ensureFadeTicker() {
    final anyFades = widget.tileFadeDuration > Duration.zero ||
        widget.labelFadeDuration > Duration.zero;
    if (!_fading && anyFades) {
      _fading = true;
      if (!_fadeTicker.isActive) _fadeTicker.start();
    }
  }

  void _onFadeTick(Duration _) {
    final now = DateTime.now();
    var anyFading = _expireFadingLabels(now);
    for (final tile in _tiles.values) {
      if (tile.fadeProgress(now, widget.tileFadeDuration) < 1) {
        anyFading = true;
      } else {
        tile.disposeUnderlay(); // fully opaque — the underlay is covered
      }
      if (tile.labelFadeProgress(now, widget.labelFadeDuration) < 1) {
        anyFading = true;
      }
    }
    _repaint.trigger();
    if (!anyFading) {
      _fading = false;
      _fadeTicker.stop();
    }
  }

  double get _devicePixelRatio =>
      MediaQuery.maybeDevicePixelRatioOf(context) ?? 2.0;

  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);
    _updateGrid(camera);
    return CustomPaint(
      size: camera.nonRotatedSize,
      isComplex: true,
      painter: _VectorMapPainter(
        state: this,
        camera: camera,
        devicePixelRatio: _devicePixelRatio,
        repaint: _repaint,
      ),
    );
  }
}

class _RepaintNotifier extends ChangeNotifier {
  void trigger() => notifyListeners();
}

class _RenderJob {
  final Map<String, PreparedTile> sources;

  /// Owned raster tile handles; disposed with the job. Only the raster
  /// phase carries any — the symbol phase never needs them.
  final Map<String, RasterTile> rasters;
  final bool provisional;
  final int priority;

  /// False for refreshes of already-visible content (sprite or label
  /// changes), where restarting the fade would flash the background.
  final bool fadeIn;

  /// Whether every source resolved — only complete final results may
  /// enter the shared result cache.
  final bool complete;

  /// The tile's [_DisplayTile.loadGeneration] when this job was built.
  /// The pump drops the job if the tile has moved on since — its
  /// sources predate whatever replaced them.
  final int generation;

  const _RenderJob({
    required this.sources,
    required this.rasters,
    required this.provisional,
    required this.priority,
    required this.fadeIn,
    required this.complete,
    required this.generation,
  });

  void dispose() {
    for (final raster in rasters.values) {
      raster.dispose();
    }
  }
}

/// A cohort of labels from a zoom level that has been handed over,
/// fading out from [startedAt]. [key] is the display tile they were laid
/// out for, which is what positions them.
typedef _FadingLabels = ({
  TileKey key,
  List<SymbolInstance> symbols,
  DateTime startedAt,
});

enum _TileState { loading, ready, empty }

class _DisplayTile {
  final TileKey key;
  final cancellation = CancellationToken();
  var state = _TileState.loading;
  ui.Image? image;

  /// The raster that was visible when [image] last changed with a fade,
  /// painted at full opacity beneath it until the fade completes — so a
  /// swap (background refresh, recovered source) cross-fades instead of
  /// dipping to the background colour.
  ui.Image? underlay;
  List<SymbolInstance> symbols = const [];

  /// How many of [symbols], from the front, the previous zoom level was
  /// already showing when this cohort was published. They are drawn at
  /// full opacity while the rest fades in — see `_publishSymbols`.
  var carriedSymbolCount = 0;

  /// Set once this tile has been retained *and* stopped contributing
  /// labels, so its orphans are handed to the fade-out exactly once —
  /// see `_handOverRetainedLabels`.
  var labelsHandedOver = false;

  /// A symbol-extraction job is queued for this tile: its labels are
  /// not there yet, so for retention purposes it still counts as
  /// loading even when its raster already landed.
  var symbolsPending = false;
  var isProvisional = false;
  DateTime? readyAt;

  /// When this tile's labels first appeared, for the label fade-in.
  DateTime? symbolsReadyAt;

  /// The source ids baked into the last final raster, and how many
  /// retries were spent recovering the missing ones — see `_loadTile`.
  Set<String>? renderedWith;
  var retryAttempt = 0;
  Timer? _retryTimer;

  /// Bumped whenever the content behind this tile changed underneath an
  /// in-flight load (a background revalidation, a sprite refresh).
  ///
  /// A load captures already-decoded sources synchronously and then
  /// awaits the rest, so one that started before the change would
  /// publish — and cache — pre-change content, and its source-id set
  /// would equal the new load's, suppressing that one as "a retry that
  /// recovered nothing". Loads and the jobs they queue carry the
  /// generation they were built for and are dropped once it moves on.
  var loadGeneration = 0;

  _DisplayTile(this.key);

  void scheduleRetry(Duration delay, void Function() run) {
    _retryTimer?.cancel();
    _retryTimer = Timer(delay, run);
  }

  void setImage({
    required ui.Image? image,
    required bool provisional,
    required bool fadeIn,
    required bool symbolsPending,
  }) {
    final previous = this.image;
    underlay?.dispose();
    if (!provisional && fadeIn && previous != null && image != null) {
      // A fading raster is replacing visible imagery: keep the old
      // pixels underneath for the duration of the fade.
      underlay = previous;
    } else {
      underlay = null;
      previous?.dispose();
    }
    this.image = image;
    isProvisional = provisional;
    this.symbolsPending = symbolsPending;
    // A final tile with no image cannot be classified until its symbol
    // phase reports back — see [setSymbols].
    state = provisional
        ? _TileState.loading
        : (image != null
            ? _TileState.ready
            : (symbolsPending
                ? _TileState.loading
                : (symbols.isEmpty ? _TileState.empty : _TileState.ready)));
    if (!provisional) {
      readyAt = fadeIn ? DateTime.now() : null;
    }
  }

  void setSymbols(
    List<SymbolInstance> symbols, {
    required int carriedCount,
    required bool fadeIn,
  }) {
    final hadSymbols = this.symbols.isNotEmpty;
    this.symbols = symbols;
    carriedSymbolCount = carriedCount;
    symbolsPending = false;
    if (!isProvisional && state == _TileState.loading) {
      // Deferred classification of a final, image-less tile.
      state = (image == null && symbols.isEmpty)
          ? _TileState.empty
          : _TileState.ready;
    }
    if (symbols.isEmpty) {
      symbolsReadyAt = null;
    } else if (!fadeIn) {
      symbolsReadyAt = null; // draw at full opacity immediately
    } else if (!hadSymbols) {
      symbolsReadyAt = DateTime.now();
    }
    // hadSymbols && fadeIn: a refresh replaced existing labels — keep
    // the running (or finished) fade instead of blinking them out.
  }

  /// Called once the fade has finished — the underlay is fully covered.
  void disposeUnderlay() {
    underlay?.dispose();
    underlay = null;
  }

  double fadeProgress(DateTime now, Duration duration) =>
      fadeProgressOf(readyAt, now, duration);

  double labelFadeProgress(DateTime now, Duration duration) =>
      fadeProgressOf(symbolsReadyAt, now, duration);

  void dispose() {
    _retryTimer?.cancel();
    cancellation.cancel();
    image?.dispose();
    image = null;
    underlay?.dispose();
    underlay = null;
    symbols = const [];
    carriedSymbolCount = 0;
    symbolsPending = false;
  }
}

class _VectorMapPainter extends CustomPainter {
  final _VectorTileLayerState state;
  final MapCamera camera;
  final double devicePixelRatio;

  _VectorMapPainter({
    required this.state,
    required this.camera,
    required this.devicePixelRatio,
    required Listenable repaint,
  }) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    final now = DateTime.now();
    final styleZoom =
        math.max(0.0, camera.zoom + state.widget.tileOffset.zoomOffset);

    // 1. Solid background so gaps between tiles never flash white.
    final background = state.widget.theme.backgroundColor(styleZoom);
    if (background != null && background.a > 0) {
      canvas.drawRect(Offset.zero & size, Paint()..color = background);
    }

    // 2. Geometry rasters in map space. Tile rectangles are made
    // relative to the camera centre in Dart (float64) *before* they
    // reach the canvas: world pixel coordinates pass 2^24 around zoom
    // 16, and the canvas transform is float32, so absolute coordinates
    // would snap tiles onto a 2-8 px grid. That snapping is what reads
    // as the map shaking while zooming, and — because the label pass
    // below does its own float64 arithmetic — as the imagery sliding
    // out from under the labels while panning.
    final screenCenter = size.center(Offset.zero);
    final worldCenter = camera.projectAtZoom(camera.center, camera.zoom);
    canvas.save();
    canvas.translate(screenCenter.dx, screenCenter.dy);
    if (camera.rotation != 0) canvas.rotate(camera.rotationRad);

    if (state._retained.isNotEmpty) {
      final retained = state._retained.entries.toList()
        ..sort((a, b) => a.key.z.compareTo(b.key.z));
      for (final entry in retained) {
        _drawTileImage(canvas, entry.value, 1, worldCenter);
      }
    }
    for (final tile in state._tiles.values) {
      _drawTileImage(canvas, tile,
          tile.fadeProgress(now, state.widget.tileFadeDuration), worldCenter);
    }
    canvas.restore();

    // 3. Labels in screen space (upright, globally collision-checked).
    if (state.widget.showLabels) {
      _paintLabels(canvas, size, screenCenter, worldCenter, styleZoom);
    }
  }

  /// Reused across tiles and frames — the canvas records a copy of the
  /// paint at each draw call, so mutating it between calls is safe.
  static final _tilePaint = Paint()
    ..filterQuality = FilterQuality.medium
    ..isAntiAlias = false;

  void _drawTileImage(
      Canvas canvas, _DisplayTile tile, double opacity, Offset worldCenter) {
    final image = tile.image;
    if (image == null) return;
    final rect = displayTileRect(tile.key, camera.zoom).shift(-worldCenter);
    final underlay = tile.underlay;
    if (underlay != null && opacity < 1) {
      // The previous raster keeps covering the tile while its
      // replacement fades in — a swap never dips to the background.
      _paintTileImage(canvas, underlay, rect, 1);
    }
    if (opacity > 0) _paintTileImage(canvas, image, rect, opacity);
  }

  void _paintTileImage(
      Canvas canvas, ui.Image image, Rect rect, double opacity) {
    _tilePaint.color = opacity < 1
        ? Color.fromRGBO(255, 255, 255, opacity)
        : const Color(0xffffffff);
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      rect,
      _tilePaint,
    );
  }

  void _paintLabels(
    Canvas canvas,
    Size size,
    Offset screenCenter,
    Offset worldCenter,
    double styleZoom,
  ) {
    final rotation = camera.rotationRad;
    final cosR = math.cos(rotation);
    final sinR = math.sin(rotation);
    final now = DateTime.now();
    final placed = <PlacedSymbol>[];

    // Takes the key and the list rather than a tile: labels fading out
    // outlive the tile they were laid out for.
    void addSymbols(
      TileKey key,
      List<SymbolInstance> symbols,
      double fadeOpacity, {
      int start = 0,
      int? end,
      bool ghost = false,
    }) {
      final last = end ?? symbols.length;
      if (start >= last) return;
      final rect = displayTileRect(key, camera.zoom);
      final tileScale = rect.width / TileRasterizer.logicalTileSize;
      final d = rect.topLeft - worldCenter;
      final transform = TileTransform(
        origin: Offset(
          screenCenter.dx + d.dx * cosR - d.dy * sinR,
          screenCenter.dy + d.dx * sinR + d.dy * cosR,
        ),
        scale: tileScale,
        rotation: rotation,
      );
      for (var i = start; i < last; i++) {
        final symbol = symbols[i];
        placed.add(PlacedSymbol(
          instance: symbol,
          screenAnchor: transform.apply(symbol.anchor),
          screenAngle: symbol.alongLine ? symbol.angle + rotation : 0,
          transform: symbol.alongLine ? transform : null,
          fadeOpacity: fadeOpacity,
          order: placed.length,
          ghost: ghost,
        ));
      }
    }

    for (final tile in state._tiles.values) {
      final progress =
          tile.labelFadeProgress(now, state.widget.labelFadeDuration);
      if (progress >= 1) {
        addSymbols(tile.key, tile.symbols, 1);
        continue;
      }
      // Labels the outgoing level is still showing skip the fade — they
      // are already on screen, and re-fading them is what made labels
      // blink across a zoom level change.
      addSymbols(tile.key, tile.symbols, 1, end: tile.carriedSymbolCount);
      // Quantized to 1/8 steps so fading tiles group into few opacity
      // buckets (one translucent layer each in the label pass); ceil
      // keeps a fresh cohort from starting invisible.
      addSymbols(tile.key, tile.symbols, (progress * 8).ceil() / 8,
          start: tile.carriedSymbolCount);
    }
    // While a zoom level change is in flight, keep the previous level's
    // labels wherever the new level has no label data yet — otherwise
    // every label blinks out for a few frames on zoom. Current-level
    // symbols are added first, so they win collisions. In steady state
    // nothing is retained and the memoized key set need not be built.
    if (state._retained.isNotEmpty) {
      final needed =
          state._retainedSymbolKeys ??= state._retainedKeysWithSymbols();
      if (needed.isNotEmpty) {
        for (final retained in state._retained.values) {
          if (needed.contains(retained.key)) {
            addSymbols(retained.key, retained.symbols, 1);
          }
        }
      }
    }
    // Last: the labels the arriving level did not replace, on their way
    // out. Ghosts, so a dying label never takes space from a live one.
    for (final fading in state._fadingLabels) {
      final progress =
          fadeProgressOf(fading.startedAt, now, state.widget.labelFadeDuration);
      if (progress >= 1) continue;
      addSymbols(
        fading.key,
        fading.symbols,
        // Floor, mirroring the fade-in's ceil: a cohort on its way out
        // reaches zero rather than lingering at one visible step.
        ((1 - progress) * 8).floor() / 8,
        ghost: true,
      );
    }
    if (placed.isEmpty) return;
    state._labelPainter.paint(
      canvas: canvas,
      screenSize: size,
      styleZoom: styleZoom,
      symbols: placed,
      sprites: state.widget.sprites,
      devicePixelRatio: devicePixelRatio,
    );
  }

  @override
  bool shouldRepaint(covariant _VectorMapPainter oldDelegate) =>
      oldDelegate.camera != camera ||
      oldDelegate.state != state ||
      oldDelegate.devicePixelRatio != devicePixelRatio;
}
