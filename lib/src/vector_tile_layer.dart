import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart' hide Theme;
import 'package:flutter/scheduler.dart';
import 'package:flutter_map/flutter_map.dart';

import 'cache/byte_cache.dart';
import 'cache/cache_resolver.dart';
import 'core/cancellation.dart';
import 'core/tile_key.dart';
import 'grid/grid_layout.dart';
import 'grid/raster_tile_store.dart';
import 'grid/tile_retention.dart';
import 'grid/tile_store.dart';
import 'logger.dart';
import 'pipeline/executor/executor.dart';
import 'pipeline/prepared_tile.dart';
import 'render/display_tile_data.dart';
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
  /// served without touching the network. Older tiles are refetched, but
  /// kept on disk (up to the size cap) and served when the network is
  /// unavailable. Mind your tile provider's terms. Has no effect on web
  /// (no disk cache).
  final Duration diskCacheTtl;

  /// Resolves the disk cache directory path; defaults to a subdirectory
  /// of the application support directory, which — unlike the temporary
  /// directory — the OS does not purge, so recently viewed areas stay
  /// available offline.
  ///
  /// Ignored on web, which has no persistent tile cache: tiles fall back
  /// to the in-memory cache and the browser's own HTTP cache.
  final Future<String> Function()? cachePath;

  /// Memory budget for decoded tile data, per source.
  final int memoryCacheMaxBytes;

  /// Duration of the fade-in of newly rasterized tiles.
  final Duration tileFadeDuration;

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

  /// Tiles with decoded data waiting to be rasterized, a few per frame.
  final _rasterQueue = <_DisplayTile, _RasterJob>{};

  final _repaint = _RepaintNotifier();
  final _labelPainter = LabelPainter();
  PatternResolver? _patterns;
  late final Ticker _fadeTicker;
  late final Ticker _rasterTicker;
  var _fading = false;
  int? _currentZoom;
  var _generation = 0;

  @override
  void initState() {
    super.initState();
    _executor = TilePrepareExecutor(concurrency: widget.concurrency);
    _fadeTicker = createTicker(_onFadeTick);
    _rasterTicker = createTicker(_pumpRasterQueue);
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
      _stores[sourceId] = TileStore(
        provider: provider,
        executor: _executor,
        layerProperties: layerProperties,
        diskCache: _diskCache,
        memoryCacheMaxBytes: widget.memoryCacheMaxBytes,
      );
    });

    final rasterSourceIds = <String>{
      for (final layer in widget.theme.layers)
        if (layer is RasterThemeLayer && layer.source != null) layer.source!,
    };
    widget.rasterSources.forEach((sourceId, source) {
      if (!rasterSourceIds.contains(sourceId)) return; // unused by theme
      _rasterStores[sourceId] = RasterTileStore(
        source: source,
        diskCache: _diskCache,
        memoryCacheMaxBytes: widget.memoryCacheMaxBytes,
      );
    });

    _generation++;
    _clearTiles();
  }

  void _clearTiles() {
    for (final job in _rasterQueue.values) {
      job.dispose();
    }
    _rasterQueue.clear();
    for (final tile in _tiles.values) {
      tile.dispose();
    }
    _tiles.clear();
    for (final tile in _retained.values) {
      tile.dispose();
    }
    _retained.clear();
    _currentZoom = null;
  }

  @override
  void didUpdateWidget(covariant VectorTileLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sprites != widget.sprites) {
      _patterns?.dispose();
      _patterns = null;
    }
    if (oldWidget.theme != widget.theme ||
        oldWidget.tileProviders != widget.tileProviders ||
        oldWidget.rasterSources != widget.rasterSources ||
        oldWidget.tileOffset.zoomOffset != widget.tileOffset.zoomOffset) {
      _buildStores();
    }
  }

  PatternResolver? get _patternResolver {
    final sprites = widget.sprites;
    if (sprites == null) return null;
    return _patterns ??= PatternResolver(sprites);
  }

  @override
  void dispose() {
    _fadeTicker.dispose();
    _rasterTicker.dispose();
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

    if (_currentZoom != layout.displayZoom) {
      // Keep the previous level's imagery underneath until the new level
      // is rasterized — this is what prevents white flicker on zoom.
      for (final entry in _tiles.entries) {
        final existing = _retained[entry.key];
        if (existing != null && !identical(existing, entry.value)) {
          existing.dispose();
        }
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
      _tiles.remove(key)?.dispose();
    }

    // Create/load missing tiles, centre first.
    for (final key in layout.keysByDistance()) {
      if (_tiles.containsKey(key)) continue;
      final tile = _DisplayTile(key);
      _tiles[key] = tile;
      unawaited(_loadTile(tile, layout));
    }

    _pruneRetained(camera, layout);
  }

  /// The current-level tiles, described for the retention rules in
  /// `grid/tile_retention.dart`.
  Iterable<CurrentTileStatus> _currentStatuses(DateTime now) =>
      _tiles.values.map((t) => (
            key: t.key,
            isLoading: t.state == _TileState.loading,
            hasSymbols: t.symbols.isNotEmpty,
            isFadedIn: t.fadeProgress(now, widget.tileFadeDuration) >= 1,
          ));

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
      _retained.remove(key)?.dispose();
    }
  }

  Future<void> _loadTile(_DisplayTile tile, GridLayout layout) async {
    final generation = _generation;
    final priority = layout.priorityOf(tile.key);
    final sources = <String, PreparedTile>{};
    final pending = <String, Future<PreparedTile?>>{};
    final rasters = <String, RasterTile>{};
    final pendingRasters = <String, Future<RasterTile?>>{};

    for (final entry in _stores.entries) {
      final dataKey =
          entry.value.dataKeyFor(tile.key, widget.tileOffset.zoomOffset);
      if (dataKey == null) continue;
      final cached = entry.value.peek(dataKey);
      if (cached != null) {
        sources[entry.key] = cached;
      } else {
        pending[entry.key] = entry.value.obtain(
          dataKey,
          priority: priority,
          cancellation: tile.cancellation,
        );
      }
    }

    for (final entry in _rasterStores.entries) {
      final dataKey =
          entry.value.dataKeyFor(tile.key, widget.tileOffset.zoomOffset);
      if (dataKey == null) continue;
      final cached = entry.value.peek(dataKey);
      if (cached != null) {
        rasters[entry.key] = cached;
      } else {
        pendingRasters[entry.key] =
            entry.value.obtain(dataKey, cancellation: tile.cancellation);
      }
    }

    if (pending.isNotEmpty || pendingRasters.isNotEmpty) {
      // Render a provisional image from already-decoded ancestors so
      // fast zoom-ins never show blank tiles.
      final provisionalSources = Map.of(sources);
      for (final sourceId in pending.keys) {
        final store = _stores[sourceId]!;
        final dataKey =
            store.dataKeyFor(tile.key, widget.tileOffset.zoomOffset);
        final ancestor =
            dataKey == null ? null : store.peekWithAncestors(dataKey);
        if (ancestor != null) provisionalSources[sourceId] = ancestor;
      }
      final provisionalRasters = <String, RasterTile>{
        for (final entry in rasters.entries) entry.key: entry.value.retain(),
      };
      for (final sourceId in pendingRasters.keys) {
        final store = _rasterStores[sourceId]!;
        final dataKey =
            store.dataKeyFor(tile.key, widget.tileOffset.zoomOffset);
        final ancestor =
            dataKey == null ? null : store.peekWithAncestors(dataKey);
        if (ancestor != null) provisionalRasters[sourceId] = ancestor;
      }
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
        tile.cancellation.isCancelled) {
      for (final raster in rasters.values) {
        raster.dispose();
      }
      return;
    }
    _enqueueRaster(tile, sources,
        rasters: rasters, provisional: false, priority: priority);
  }

  /// Rasterization happens on the UI thread (`Picture.toImageSync`), so
  /// completed tiles are queued and processed within a per-frame time
  /// budget instead of all at once — with warm caches a zoom-level
  /// change completes every tile in the same instant, and rasterizing
  /// ~20 tiles in one frame drops frames.
  /// Takes ownership of [rasters]: the handles are disposed with the job,
  /// whether it is painted, replaced or rejected.
  void _enqueueRaster(
    _DisplayTile tile,
    Map<String, PreparedTile> sources, {
    Map<String, RasterTile> rasters = const {},
    required bool provisional,
    required int priority,
  }) {
    final job = _RasterJob(
        sources: sources,
        rasters: rasters,
        provisional: provisional,
        priority: priority);
    if (tile.cancellation.isCancelled) {
      job.dispose();
      return;
    }
    final existing = _rasterQueue[tile];
    // Never replace a queued final raster with a provisional one.
    if (existing != null && !existing.provisional && provisional) {
      job.dispose();
      return;
    }
    existing?.dispose();
    _rasterQueue[tile] = job;
    if (!_rasterTicker.isActive) _rasterTicker.start();
  }

  void _pumpRasterQueue(Duration _) {
    final stopwatch = Stopwatch()..start();
    var processed = 0;
    // At least one tile per frame, more while within the time budget:
    // the viewport centre comes first.
    while (_rasterQueue.isNotEmpty &&
        (processed == 0 || stopwatch.elapsedMicroseconds < 4000)) {
      _DisplayTile? best;
      _RasterJob? bestJob;
      _rasterQueue.forEach((tile, job) {
        if (bestJob == null || job.priority < bestJob!.priority) {
          best = tile;
          bestJob = job;
        }
      });
      final tile = best!;
      final job = _rasterQueue.remove(tile)!;
      if (!tile.cancellation.isCancelled) {
        _rasterizeNow(tile, job.sources,
            rasters: job.rasters, provisional: job.provisional);
        processed++;
      }
      job.dispose();
    }
    if (_rasterQueue.isEmpty) _rasterTicker.stop();
  }

  void _rasterizeNow(
    _DisplayTile tile,
    Map<String, PreparedTile> sources, {
    Map<String, RasterTile> rasters = const {},
    required bool provisional,
  }) {
    final styleZoom = _styleZoomOf(tile.key.z.toDouble());
    final data = DisplayTileData(
        displayKey: tile.key, sources: sources, rasters: rasters);
    final image = TileRasterizer.rasterize(
      theme: widget.theme,
      data: data,
      styleZoom: styleZoom,
      devicePixelRatio: _devicePixelRatio,
      patterns: _patternResolver,
    );
    final symbols = widget.showLabels && sources.isNotEmpty
        ? SymbolLayouter.layout(
            theme: widget.theme, data: data, styleZoom: styleZoom)
        : const <SymbolInstance>[];

    tile.setResult(
      image: image,
      symbols: symbols,
      provisional: provisional,
      fadeIn: !provisional,
    );
    _repaint.trigger();
    _ensureFadeTicker();
  }

  void _ensureFadeTicker() {
    if (!_fading && widget.tileFadeDuration > Duration.zero) {
      _fading = true;
      if (!_fadeTicker.isActive) _fadeTicker.start();
    }
  }

  void _onFadeTick(Duration _) {
    final now = DateTime.now();
    var anyFading = false;
    for (final tile in _tiles.values) {
      if (tile.fadeProgress(now, widget.tileFadeDuration) < 1) {
        anyFading = true;
        break;
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

class _RasterJob {
  final Map<String, PreparedTile> sources;

  /// Owned raster tile handles; disposed with the job.
  final Map<String, RasterTile> rasters;
  final bool provisional;
  final int priority;

  const _RasterJob({
    required this.sources,
    required this.rasters,
    required this.provisional,
    required this.priority,
  });

  void dispose() {
    for (final raster in rasters.values) {
      raster.dispose();
    }
  }
}

enum _TileState { loading, ready, empty }

class _DisplayTile {
  final TileKey key;
  final cancellation = CancellationToken();
  var state = _TileState.loading;
  ui.Image? image;
  List<SymbolInstance> symbols = const [];
  var isProvisional = false;
  DateTime? readyAt;

  _DisplayTile(this.key);

  void setResult({
    required ui.Image? image,
    required List<SymbolInstance> symbols,
    required bool provisional,
    required bool fadeIn,
  }) {
    this.image?.dispose();
    this.image = image;
    this.symbols = symbols;
    isProvisional = provisional;
    state = provisional
        ? _TileState.loading
        : (image == null && symbols.isEmpty
            ? _TileState.empty
            : _TileState.ready);
    if (!provisional) {
      readyAt = fadeIn ? DateTime.now() : null;
    }
  }

  double fadeProgress(DateTime now, Duration duration) {
    final start = readyAt;
    if (start == null || duration <= Duration.zero) return 1;
    final t = now.difference(start).inMilliseconds / duration.inMilliseconds;
    return t.clamp(0.0, 1.0);
  }

  void dispose() {
    cancellation.cancel();
    image?.dispose();
    image = null;
    symbols = const [];
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

    final retained = state._retained.entries.toList()
      ..sort((a, b) => a.key.z.compareTo(b.key.z));
    for (final entry in retained) {
      _drawTileImage(canvas, entry.value, 1, worldCenter);
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

  void _drawTileImage(
      Canvas canvas, _DisplayTile tile, double opacity, Offset worldCenter) {
    final image = tile.image;
    if (image == null || opacity <= 0) return;
    final rect = displayTileRect(tile.key, camera.zoom).shift(-worldCenter);
    final paint = Paint()
      ..filterQuality = FilterQuality.medium
      ..isAntiAlias = false;
    if (opacity < 1) {
      paint.color = Color.fromRGBO(255, 255, 255, opacity);
    }
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      rect,
      paint,
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
    final placed = <PlacedSymbol>[];

    void addSymbols(_DisplayTile tile) {
      if (tile.symbols.isEmpty) return;
      final rect = displayTileRect(tile.key, camera.zoom);
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
      for (final symbol in tile.symbols) {
        placed.add(PlacedSymbol(
          instance: symbol,
          screenAnchor: transform.apply(symbol.anchor),
          screenAngle: symbol.alongLine ? symbol.angle + rotation : 0,
          transform: symbol.alongLine ? transform : null,
        ));
      }
    }

    for (final tile in state._tiles.values) {
      addSymbols(tile);
    }
    // While a zoom level change is in flight, keep the previous level's
    // labels wherever the new level has no label data yet — otherwise
    // every label blinks out for a few frames on zoom. Current-level
    // symbols are added first, so they win collisions.
    final current = state._currentStatuses(DateTime.now()).toList();
    for (final retained in state._retained.values) {
      if (retainedSymbolsNeeded(
        retainedKey: retained.key,
        hasSymbols: retained.symbols.isNotEmpty,
        current: current,
      )) {
        addSymbols(retained);
      }
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
