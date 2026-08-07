import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart' hide Theme;
import 'package:flutter/scheduler.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:path_provider/path_provider.dart';

import 'cache/disk_cache.dart';
import 'core/cancellation.dart';
import 'core/tile_key.dart';
import 'grid/grid_layout.dart';
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

  /// Sprite atlas for icon rendering (optional).
  final SpriteAtlas? sprites;

  /// See [TileOffset]. Defaults to [TileOffset.maplibre], which renders
  /// MapLibre-authored styles (MapTiler etc.) exactly as designed.
  final TileOffset tileOffset;

  /// Number of background isolates decoding tiles.
  final int concurrency;

  /// Maximum size of the tile byte cache on disk. Zero disables disk
  /// caching.
  final int diskCacheMaximumSizeInBytes;

  /// Time-to-live for disk-cached tiles. Mind your tile provider's terms.
  final Duration diskCacheTtl;

  /// Resolves the disk cache folder; defaults to a subdirectory of the
  /// system temporary directory.
  final Future<Directory> Function()? cacheFolder;

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
    this.sprites,
    this.tileOffset = TileOffset.maplibre,
    this.concurrency = 3,
    this.diskCacheMaximumSizeInBytes = 50 * 1024 * 1024,
    this.diskCacheTtl = const Duration(days: 14),
    this.cacheFolder,
    this.memoryCacheMaxBytes = 24 * 1024 * 1024,
    this.tileFadeDuration = const Duration(milliseconds: 150),
    this.showLabels = true,
    this.logger = const Logger.noop(),
  });

  @override
  State<VectorTileLayer> createState() => _VectorTileLayerState();
}

class _VectorTileLayerState extends State<VectorTileLayer>
    with SingleTickerProviderStateMixin {
  late TilePrepareExecutor _executor;
  DiskCache? _diskCache;
  final _stores = <String, TileStore>{};
  final _tiles = <TileKey, _DisplayTile>{};

  /// Tiles of other zoom levels kept until the current level is ready.
  final _retained = <TileKey, _DisplayTile>{};

  final _repaint = _RepaintNotifier();
  final _labelPainter = LabelPainter();
  PatternResolver? _patterns;
  late final Ticker _fadeTicker;
  var _fading = false;
  int? _currentZoom;
  var _generation = 0;

  @override
  void initState() {
    super.initState();
    _executor = TilePrepareExecutor(concurrency: widget.concurrency);
    _fadeTicker = createTicker(_onFadeTick);
    _initCaches();
    _buildStores();
  }

  Future<void> _initCaches() async {
    if (widget.diskCacheMaximumSizeInBytes <= 0) return;
    try {
      final dir = widget.cacheFolder != null
          ? await widget.cacheFolder!()
          : Directory(
              '${(await getTemporaryDirectory()).path}'
              '${Platform.pathSeparator}flutter_map_vector_tiles');
      final cache = DiskCache(
        directory: dir,
        ttl: widget.diskCacheTtl,
        maxSizeBytes: widget.diskCacheMaximumSizeInBytes,
        logger: widget.logger,
      );
      await cache.initialize();
      if (!mounted) {
        return;
      }
      _diskCache = cache;
      _buildStores();
    } catch (e) {
      widget.logger.warn('disk cache unavailable: $e');
    }
  }

  void _buildStores() {
    for (final store in _stores.values) {
      store.dispose();
    }
    _stores.clear();

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

    _generation++;
    _clearTiles();
  }

  void _clearTiles() {
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
    _clearTiles();
    for (final store in _stores.values) {
      store.dispose();
    }
    _stores.clear();
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

  void _pruneRetained(MapCamera camera, GridLayout layout) {
    if (_retained.isEmpty) return;
    final allReady = _tiles.values
        .every((t) => t.state != _TileState.loading);
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
    final pending =
        <String, Future<PreparedTile?>>{};

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

    if (pending.isNotEmpty) {
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
      if (provisionalSources.isNotEmpty) {
        _rasterize(tile, provisionalSources, provisional: true);
      }
      for (final entry in pending.entries) {
        final prepared = await entry.value;
        if (prepared != null) sources[entry.key] = prepared;
      }
    }

    if (!mounted ||
        generation != _generation ||
        tile.cancellation.isCancelled) {
      return;
    }
    _rasterize(tile, sources, provisional: false);
  }

  void _rasterize(
    _DisplayTile tile,
    Map<String, PreparedTile> sources, {
    required bool provisional,
  }) {
    if (tile.cancellation.isCancelled) return;
    final styleZoom = _styleZoomOf(tile.key.z.toDouble());
    final data = DisplayTileData(displayKey: tile.key, sources: sources);
    final image = TileRasterizer.rasterize(
      theme: widget.theme,
      data: data,
      styleZoom: styleZoom,
      devicePixelRatio:
          MediaQuery.maybeDevicePixelRatioOf(context) ?? 2.0,
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
        repaint: _repaint,
      ),
    );
  }
}

class _RepaintNotifier extends ChangeNotifier {
  void trigger() => notifyListeners();
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
    final t =
        now.difference(start).inMilliseconds / duration.inMilliseconds;
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

  _VectorMapPainter({
    required this.state,
    required this.camera,
    required Listenable repaint,
  }) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    final now = DateTime.now();
    final styleZoom = math.max(
        0.0, camera.zoom + state.widget.tileOffset.zoomOffset);

    // 1. Solid background so gaps between tiles never flash white.
    final background = state.widget.theme.backgroundColor(styleZoom);
    if (background != null && background.a > 0) {
      canvas.drawRect(Offset.zero & size, Paint()..color = background);
    }

    // 2. Geometry rasters in map space.
    final screenCenter = size.center(Offset.zero);
    final worldCenter = camera.projectAtZoom(camera.center, camera.zoom);
    canvas.save();
    canvas.translate(screenCenter.dx, screenCenter.dy);
    if (camera.rotation != 0) canvas.rotate(camera.rotationRad);
    canvas.translate(-worldCenter.dx, -worldCenter.dy);

    final retained = state._retained.entries.toList()
      ..sort((a, b) => a.key.z.compareTo(b.key.z));
    for (final entry in retained) {
      _drawTileImage(canvas, entry.value, 1);
    }
    for (final tile in state._tiles.values) {
      _drawTileImage(canvas,
          tile, tile.fadeProgress(now, state.widget.tileFadeDuration));
    }
    canvas.restore();

    // 3. Labels in screen space (upright, globally collision-checked).
    if (state.widget.showLabels) {
      _paintLabels(canvas, size, screenCenter, worldCenter, styleZoom);
    }
  }

  void _drawTileImage(Canvas canvas, _DisplayTile tile, double opacity) {
    final image = tile.image;
    if (image == null || opacity <= 0) return;
    final rect = displayTileRect(tile.key, camera.zoom);
    final paint = Paint()
      ..filterQuality = FilterQuality.medium
      ..isAntiAlias = false;
    if (opacity < 1) {
      paint.color = Color.fromRGBO(255, 255, 255, opacity);
    }
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(
          0, 0, image.width.toDouble(), image.height.toDouble()),
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

    for (final tile in state._tiles.values) {
      if (tile.symbols.isEmpty) continue;
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
    if (placed.isEmpty) return;
    state._labelPainter.paint(
      canvas: canvas,
      screenSize: size,
      styleZoom: styleZoom,
      symbols: placed,
      sprites: state.widget.sprites,
    );
  }

  @override
  bool shouldRepaint(covariant _VectorMapPainter oldDelegate) =>
      oldDelegate.camera != camera || oldDelegate.state != state;
}
