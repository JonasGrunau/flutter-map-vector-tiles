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
import 'core/tile_zoom.dart';
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
  /// the fade and immediately finishes any fade already in progress
  /// (labels appear instantly, as before 2.3.0).
  ///
  /// This also paces the label collision pass (capped at 300ms): a
  /// freshly published tile's labels are placed at the pass after their
  /// publish, so they appear at most one such interval later — the same
  /// window their fade-in spans anyway.
  final Duration labelFadeDuration;

  /// Byte budget for finished display tiles (rasterized geometry plus
  /// extracted symbols), kept so that zooming back to a recently shown
  /// level swaps its imagery in instead of re-rendering it. Shared
  /// process-wide per style, like [memoryCacheMaxBytes]. Zero disables.
  ///
  /// Defaults to [autoRasterCacheBytes], which sizes the budget for the
  /// actual device pixel ratio and viewport — see
  /// [autoRasterCacheBytesFor]. A fixed byte count overrides it.
  ///
  /// These are GPU texture bytes: one tile costs `(256·dpr)²·4` bytes —
  /// ~1 MiB at devicePixelRatio 2, ~2.25 MiB at 3 — and one phone
  /// viewport is ~25-35 tiles per zoom level, so a *single* level runs
  /// to ~80 MiB on a large dpr-3 phone. That is why a fixed default is
  /// the wrong shape: the 64 MiB this used to default to held about two
  /// levels at dpr 2 but under one at dpr 3, so on exactly the densest
  /// devices a zoom round trip evicted the level it was returning to
  /// and re-rendered the screen every crossing.
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
    this.rasterCacheMaxBytes = autoRasterCacheBytes,
    this.showLabels = true,
    this.logger = const Logger.noop(),
  });

  /// [rasterCacheMaxBytes] value meaning "size it for this device".
  ///
  /// Negative so it can never collide with a real byte budget, and so
  /// the documented `0` still means *disabled*.
  static const int autoRasterCacheBytes = -1;

  /// Tiles currently retained from a previous zoom level, as last
  /// written by whichever layer most recently changed its retained set
  /// — test instrumentation for the release-without-a-rebuild path,
  /// meaningless when several layers are mounted.
  @visibleForTesting
  static int debugRetainedTileCount = 0;

  /// How many screenfuls of finished tiles [autoRasterCacheBytes] aims
  /// to hold. Two would be the bare minimum for a zoom round trip — one
  /// level each side of a threshold — and the half is headroom for the
  /// buffer ring and a partly-scrolled third level. Measured on a
  /// dpr-3 phone crossing a POI threshold at ~7 crossings/second: at
  /// two-and-a-half levels the crossing re-rendered nothing at all,
  /// and doubling the budget again changed nothing, so this is the knee
  /// rather than a guess.
  static const double _cacheLevels = 2.5;

  /// Floor and ceiling for the automatic budget. The floor keeps small
  /// windows (a map in a card, a phone in split view) from caching so
  /// little that nothing survives a crossing; the ceiling keeps a large
  /// desktop window from pinning an unreasonable amount of GPU memory,
  /// since these are textures and not evictable pages.
  static const int _minAutoCacheBytes = 64 * 1024 * 1024;
  static const int _maxAutoCacheBytes = 256 * 1024 * 1024;

  /// The automatic [rasterCacheMaxBytes] for a [viewport] at
  /// [devicePixelRatio]: enough finished tiles for [_cacheLevels]
  /// screenfuls, clamped to a sane range.
  ///
  /// The tile count mirrors `GridLayout.forCamera(buffer: 1)`: a screen
  /// spans at most `ceil(extent / 256) + 1` tiles per axis, plus one
  /// each side for the buffer ring.
  @visibleForTesting
  static int autoRasterCacheBytesFor(Size viewport, double devicePixelRatio) {
    final tilePx = displayTileSize * devicePixelRatio;
    final tileBytes = tilePx * tilePx * 4;
    final tilesX = (viewport.width / displayTileSize).ceil() + 3;
    final tilesY = (viewport.height / displayTileSize).ceil() + 3;
    final perLevel = tilesX * tilesY * tileBytes;
    return (perLevel * _cacheLevels)
        .round()
        .clamp(_minAutoCacheBytes, _maxAutoCacheBytes);
  }

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
    with TickerProviderStateMixin, WidgetsBindingObserver {
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

  /// Generation of the inputs to label placement. Candidate churn and
  /// camera motion mark the frozen decision dirty; the throttle picks the
  /// latest generation up at its next due pass rather than on every
  /// publish or gesture frame.
  var _labelGeneration = 0;

  /// Last camera state that fed label placement. Ticker-only repaints keep
  /// this unchanged, which is how the throttle distinguishes animation
  /// frames from a camera move that really requires another collision pass.
  ({
    double latitude,
    double longitude,
    double zoom,
    double rotation
  })? _labelCamera;

  /// Invalidates everything memoized over the current label candidates.
  void _labelCandidatesChanged() {
    _retainedSymbolKeys = null;
    _labelGeneration++;
  }

  void _updateLabelCamera(MapCamera camera) {
    final current = (
      latitude: camera.center.latitude,
      longitude: camera.center.longitude,
      zoom: camera.zoom,
      rotation: camera.rotation,
    );
    if (current == _labelCamera) return;
    _labelCamera = current;
    _labelGeneration++;
  }

  /// Fade-out fallbacks for labels whose tile is gone: when a retained
  /// tile is disposed, its (pinned) symbols are parked here for one
  /// fade duration, so the label pass can keep drawing a fading key's
  /// ghost while it ramps to zero. Never placement candidates, and only
  /// plain Dart objects — no tile texture is pinned by a fade.
  final _ghostLabels = <_GhostLabels>[];

  /// The symbols the last label pass actually drew, by identity.
  ///
  /// A tile's `symbols` are placement *candidates*: the collision pass
  /// picks the winners afresh every frame, and on a dense screen most
  /// of them lose. Only the winners were ever on screen, so only they
  /// survive the retention pin (see `_updateGrid`): an outgoing level
  /// exists to keep what was visible, never to introduce labels.
  /// Rebuilt in place each frame, so the pin never guesses.
  final _drawnLastFrame = <SymbolInstance>{};

  /// Bounded retries for tiles that finalized with a source missing
  /// after a transient failure. Fired just past the stores' failure
  /// throttle, so each attempt can actually reach the network again.
  static const _maxLoadRetries = 4;
  Duration get _loadRetryDelay =>
      TileByteLoader.errorRetryDelay + const Duration(seconds: 1);

  // ---------------------------------------------------------------
  // Working around an engine bug: magenta rasters after a backgrounding
  //
  // iOS revokes GPU access for the whole process while an app is in the
  // background. A `toImageSync` raster whose Metal work is rejected does
  // not fail — Impeller fills the texture with solid magenta — and
  // nothing above the rasterizer can tell that from a real tile, so it
  // paints and caches like one. Process-wide caching then makes a
  // moment's bad luck last the whole session.
  //
  // The engine *has* this guard; `toImageSync` just does not use it.
  // Checked against flutter/flutter@master, August 2026, in
  // `engine/src/flutter/shell/common/snapshot_controller_impeller.cc`:
  //
  //   * `MakeImpellerSnapshot` — the async path behind `Picture.toImage`
  //     — runs under `GetIsGpuDisabledSyncSwitch()` and, when the GPU is
  //     disabled, parks the work via `StoreTaskForGPU` until it is back.
  //   * `MakeImpellerSnapshotSync` — the path behind
  //     `Picture.toImageSync` — calls `DoMakeRasterSnapshot` directly.
  //     No sync switch, no deferral: it rasterizes regardless.
  //
  // The engine's shipped fixes for the same symptom (#169378, #169596,
  // cherry-picked in #170846, plus the follow-up #190445) all harden the
  // *image decode/upload* path — `instantiateImageCodec` — and leave
  // offscreen render passes alone. Tracked upstream as
  // https://github.com/flutter/flutter/issues/191255, filed from this
  // investigation; every *other* "pink images" issue is closed and is
  // the decode path, so a closed-issue search is not evidence that this
  // is fixed.
  //
  // TO REMOVE THIS WORKAROUND: watch flutter/flutter#191255, and check
  // whether `MakeImpellerSnapshotSync` consults
  // `GetIsGpuDisabledSyncSwitch()`. Once it defers instead of
  // rasterizing into a revoked context, every member below and the
  // `_foregrounded` guards in `_pumpRenderQueue` and `_enqueueRaster`
  // can go, along with `WidgetsBindingObserver` and
  // `test/app_lifecycle_raster_test.dart` — then raise the package's
  // Flutter constraint to the first release carrying the fix. Deleting
  // it early is not a cosmetic regression: it puts permanently magenta
  // tiles back into a process-wide cache.
  // ---------------------------------------------------------------

  /// Whether the platform is in a state where rasterizing is safe.
  ///
  /// The window that matters is `inactive`, not `paused`: the scheduler
  /// keeps frames enabled through `inactive` — that is what draws the
  /// app-switcher snapshot on the way out and the first frames on the
  /// way back in — while iOS revokes the context somewhere alongside
  /// it. A frame-driven render pump left running there rasterizes into
  /// a context it is losing or has not been given back. From `hidden`
  /// onwards no frames are produced at all, so the gate costs nothing
  /// and simply stays shut. Only `resumed` is safe.
  ///
  /// This narrows the window rather than closing it, which is why the
  /// recovery below is the actual guarantee: `toImageSync` returns a
  /// *deferred* image, and the raster thread can get to it after the
  /// transition that the gate was checked before.
  ///
  /// Seeded from the binding rather than assumed, so a layer mounted
  /// while the app is already away does not rasterize its opening
  /// screenful into a context it does not have. `lifecycleState` is null
  /// until the first platform message arrives — and stays null under
  /// `flutter test` — and that has to read as foregrounded, or a layer
  /// waiting to be told it may paint would never paint at all.
  var _foregrounded = true;

  /// How many times the app has left the foreground.
  ///
  /// Process-wide, because the caches a departure condemns are
  /// process-wide too. A map screen rebuilt on the way back in is a
  /// brand-new layer with a brand-new observer, which lived through no
  /// departure at all — a per-layer flag would leave it reading suspect
  /// textures out of a cache that no surviving observer was there to
  /// clear.
  ///
  /// Counted from `hidden` onwards rather than from `inactive`: iOS
  /// revokes the context in `applicationDidEnterBackground`, so a
  /// control-centre swipe or a permission dialog — neither of which
  /// goes further than `inactive` — must not cost a screenful of
  /// re-rasterization.
  static var _departures = 0;

  /// Whether the app is away right now, so that the several layers one
  /// screen may hold count a single departure once between them.
  static var _away = false;

  /// The departure this layer has already recovered from; it recovers
  /// whenever this falls behind [_departures].
  late int _recovered;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foregrounded = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    // A layer mounting while the app is away — or into a return that no
    // other layer was left mounted to notice — lived through no
    // departure of its own, but the caches it is about to read were
    // filled before one. It starts a departure behind, and so recovers
    // alongside the layers that did live through it.
    _recovered = _away ? _departures - 1 : _departures;
    if (_foregrounded) _away = false;
    _executor = TilePrepareExecutor(concurrency: widget.concurrency);
    _fadeTicker = createTicker(_onFadeTick);
    _renderTicker = createTicker(_pumpRenderQueue);
    _diskCache = _obtainDiskCache();
    _buildStores();
    _recoverIfSuspect();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    _foregrounded = state == AppLifecycleState.resumed;
    if (!_foregrounded) {
      if (state != AppLifecycleState.inactive && !_away) {
        _away = true;
        _departures++;
      }
      return;
    }
    _away = false;
    _recoverIfSuspect();
    // The pump stops its own ticker when it is asked to run while the
    // app is away; whatever it left queued is still queued.
    if (!_renderQueue.isEmpty && !_renderTicker.isActive) {
      _renderTicker.start();
    }
  }

  /// Rebuilds anything this layer may be holding — or about to read —
  /// from before the last departure, once it is safe to rasterize again.
  ///
  /// Part of the `toImageSync` workaround documented above; it goes when
  /// the engine defers a snapshot instead of rasterizing into a revoked
  /// context.
  void _recoverIfSuspect() {
    if (!_foregrounded || _recovered == _departures) return;
    _recovered = _departures;
    _discardSuspectRasters();
  }

  /// Drops every image that may have been rasterized against a revoked
  /// GPU context, and rebuilds it from data that cannot have been.
  ///
  /// This is the load-bearing half of the `toImageSync` workaround
  /// documented above the lifecycle fields — the gate only narrows the
  /// window, this is what guarantees a magenta tile cannot outlive one
  /// resume. It goes when the engine's sync snapshot path defers.
  ///
  /// Recovery is cheap because only the last step of the pipeline is
  /// affected: decoded geometry is `Float32List`s on the Dart heap, so
  /// this is a re-rasterize pass — no network, no isolate, no decode.
  /// Live tiles keep their current imagery until the replacement lands
  /// (see [_refreshTiles]), so the recovery costs no blank frame.
  ///
  /// The order is load-bearing. The finished-result cache has to go
  /// first, or [_refreshTiles] hands back the very textures it is
  /// replacing: refreshing a tile resets `renderedWith`, and that is
  /// precisely what sends [_loadTile] to the cache again.
  void _discardSuspectRasters() {
    TileResultCache.clearAll();
    // Raster-source images are decoded rather than recorded, but they
    // are uploaded to the same context and are baked into the tiles
    // about to be re-rasterized. Their bytes stay on disk.
    RasterTileStore.clearMemoryCaches();
    // Pattern stamps are `toImageSync` images too, and the refresh
    // below bakes them into every fill and line that uses one.
    _patterns?.dispose();
    _patterns = null;
    _refreshTiles();
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
    VectorTileLayer.debugRetainedTileCount = 0;
    _labelCandidatesChanged();
    _ghostLabels.clear();
    // A theme or provider swap replaces every symbol instance and
    // changes what layer indices mean; stale fade state, a stale frozen
    // placement or a stale drawn snapshot would pin the old theme's
    // expression graphs.
    _labelPainter.reset();
    _drawnLastFrame.clear();
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
    if (!widget.showLabels && oldWidget.showLabels) {
      // The label pass stops running, so its fade and placement state
      // stops being updated: settle it here, or the fade ticker keeps
      // scheduling frames for labels that no longer paint.
      _labelPainter.reset();
      _drawnLastFrame.clear();
      _ghostLabels.clear();
    }
    if (oldWidget.memoryCacheMaxBytes != widget.memoryCacheMaxBytes) {
      for (final store in _stores.values) {
        store.memoryCacheMaxBytes = widget.memoryCacheMaxBytes;
      }
      for (final store in _rasterStores.values) {
        store.memoryCacheMaxBytes = widget.memoryCacheMaxBytes;
      }
    }
    if (_rasterCacheBytesOf(oldWidget) != _rasterCacheBytesOf(widget) &&
        _rasterCacheBytesOf(widget) <= 0) {
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
  /// The byte budget this layer is actually running with: the widget's
  /// value, or one sized for the device when it asks for the automatic
  /// one. Only the sentinel is special — every other value is taken
  /// literally, so `0` still disables exactly as documented.
  int _rasterCacheBytesOf(VectorTileLayer layer) =>
      layer.rasterCacheMaxBytes == VectorTileLayer.autoRasterCacheBytes
          ? VectorTileLayer.autoRasterCacheBytesFor(
              _viewportSize, _devicePixelRatio)
          : layer.rasterCacheMaxBytes;

  /// The viewport the automatic budget is sized against, refreshed in
  /// `build`. Zero until the first one, which cannot precede any cache
  /// access: every load starts from `_updateGrid`, which `build` calls.
  Size _viewportSize = Size.zero;

  /// disabled via [VectorTileLayer.rasterCacheMaxBytes] — the one place
  /// that decides whether this layer caches at all.
  TileResultCache? get _resultCache {
    final bytes = _rasterCacheBytesOf(widget);
    return bytes <= 0
        ? null
        : TileResultCache.forSignature(_resultSignature, bytes);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
      // Keep the previous level's imagery underneath until the new level
      // is rasterized — this is what prevents white flicker on zoom.
      final pinLabels =
          widget.showLabels && widget.labelFadeDuration > Duration.zero;
      for (final entry in _tiles.entries) {
        final existing = _retained[entry.key];
        if (existing != null && !identical(existing, entry.value)) {
          _parkGhostLabels(existing);
          _disposeTile(existing);
        }
        // Retained tiles paint at full opacity, so their cross-fade
        // underlay is never drawn again — and the fade tick that would
        // release it only walks the current level. Left alone it pins a
        // second full-tile texture for the whole retention window.
        entry.value.disposeUnderlay();
        if (pinLabels) {
          // An outgoing level only *keeps* labels on screen until the
          // new level covers them — it must not introduce any. The
          // crossing typically zoom-cuts whole layers at their minzoom
          // (POIs, say), and the freed space would otherwise go to the
          // candidates those labels had been suppressing: street names
          // never before on screen, sliding in for the moments until
          // the arriving level fades them back out. Its losing
          // candidates are dropped for good right here. (Skipped when
          // nothing tracks _drawnLastFrame — see the label pass — where
          // pinning would empty every retained cohort instead.)
          entry.value.symbols =
              drawnLabels(entry.value.symbols, _drawnLastFrame);
        }
        _retained[entry.key] = entry.value;
      }
      _tiles.clear();
      _currentZoom = layout.displayZoom;
      VectorTileLayer.debugRetainedTileCount = _retained.length;
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
    _labelCandidatesChanged();
    _pruneRetained(camera, layout);
  }

  /// The current-level tiles, described for the retention rules in
  /// `grid/tile_retention.dart`. A tile whose raster landed but whose
  /// symbol extraction is still queued counts as loading: the retained
  /// level's labels must keep covering it or every label would blink
  /// out for the frames between the two phases.
  ///
  /// Provisional cohorts — laid out from ancestor data — do not count as
  /// symbol coverage: they are nearly the previous level's own labels,
  /// so releasing (and irreversibly handing over) the retained level
  /// against them would fade out labels the final data still carries and
  /// consume the one-shot hand-over before the real arriving set exists.
  /// Until the final cohort lands, the retained labels and the
  /// provisional ones coexist as candidates; the collision pass keeps
  /// one of each pair.
  Iterable<CurrentTileStatus> _currentStatuses(DateTime now) =>
      _tiles.values.map((t) => (
            key: t.key,
            isLoading: t.state == _TileState.loading || t.symbolsPending,
            hasSymbols: !t.symbolsProvisional && t.symbols.isNotEmpty,
            isFadedIn: t.fadeProgress(now, widget.tileFadeDuration) >= 1,
          ));

  /// Recomputes [_retainedSymbolKeys] — called lazily from the label
  /// pass after any event invalidated it. A retained tile outside this
  /// set still offers its labels as fade-out fallbacks (ghost-only
  /// candidates); flipping back in is harmless, because a re-placed key
  /// resumes its fade from the current opacity rather than popping.
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
    _dropRetained(toRemove);
  }

  /// Releases the whole retained level the moment the current one no
  /// longer needs it. [_pruneRetained] applies the same rule but only
  /// runs on rebuilds, and a rebuild needs a camera change: a crossing
  /// whose gesture has ended finishes its fades on the ticker alone, so
  /// without this the outgoing level — its tile objects, pinned symbol
  /// lists and image handles — would sit in [_retained] (and be painted
  /// under the map every frame) until the *next* gesture. Called from
  /// the publish jobs and the fade tick, the two places readiness can
  /// change outside a rebuild; never from mid-[_updateGrid] paths,
  /// where the arriving grid is still incomplete and "every current
  /// tile is ready" would be answered over a partial level.
  void _releaseRetainedIfReady(DateTime now) {
    if (_retained.isEmpty) return;
    if (!currentLevelReady(_currentStatuses(now))) return;
    _dropRetained(_retained.keys.toList());
  }

  /// Removes [keys] from [_retained], parking their labels as fade-out
  /// fallbacks and disposing the tiles.
  void _dropRetained(List<TileKey> keys) {
    if (keys.isEmpty) return;
    for (final key in keys) {
      final tile = _retained.remove(key);
      if (tile == null) continue;
      _parkGhostLabels(tile);
      _disposeTile(tile);
    }
    VectorTileLayer.debugRetainedTileCount = _retained.length;
    _labelCandidatesChanged();
  }

  /// Whether any retained tile's imagery lies beneath [key] — what
  /// decides if a cache-served tile has anything to cross-fade over.
  bool _coveredByRetained(TileKey key) {
    for (final entry in _retained.entries) {
      if (entry.value.image != null && tilesOverlap(entry.key, key)) {
        return true;
      }
    }
    return false;
  }

  /// Parks a disposed retained tile's labels as fade-out fallbacks for
  /// one fade duration. Its keys that the new level replaces are drawn
  /// by the new tiles; the rest are mid-fade-out in the label painter,
  /// and without a surviving instance to lay out, a fading label would
  /// vanish at whatever opacity it had reached.
  void _parkGhostLabels(_DisplayTile tile) {
    if (tile.symbols.isEmpty ||
        !widget.showLabels ||
        widget.labelFadeDuration <= Duration.zero) {
      return;
    }
    _ghostLabels
        .add((key: tile.key, symbols: tile.symbols, since: DateTime.now()));
    _ensureFadeTicker();
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
        final owesShaping = cached.symbols.isNotEmpty;
        tile.setImage(
          image: cached.image?.clone(),
          provisional: false,
          // A cached result fades in only when retained imagery lies
          // beneath it to cross-fade over. With nothing beneath, the
          // fade runs over the bare background — on a zoom-out the
          // newly exposed ring did exactly that, a background-coloured
          // shimmer on every crossing even though the pixels were ready
          // — so ready imagery with nothing to blend against simply
          // pops. Fresh renders keep their fade: they arrive staggered,
          // and the fade is what masks that pop-in.
          fadeIn: fadeIn &&
              widget.tileFadeDuration > Duration.zero &&
              _coveredByRetained(tile.key),
          symbolsPending: owesShaping,
        );
        if (owesShaping) {
          // The imagery is free — that is what the cache is for — but
          // these labels never passed through the render pump, so
          // nothing has shaped their text. Shaping them here would be
          // the worst place for it: this runs synchronously inside
          // `build` (there is no `await` above it, and `_updateGrid`
          // calls `_loadTile` for every tile of the arriving level), so
          // a warm zoom crossing would shape a whole screen's labels —
          // tens of milliseconds — in one frame, outside every budget
          // this class has. Queue it as a symbol phase that owes only
          // the shaping instead, and let the pump slice it.
          _renderQueue.enqueueSymbols(
            tile,
            priority,
            _RenderJob(
              sources: const {},
              rasters: const {},
              provisional: false,
              priority: priority,
              fadeIn: fadeIn,
              complete: true,
              generation: tile.loadGeneration,
              fromCache: true,
              symbols: cached.symbols,
            ),
          );
          if (_foregrounded && !_renderTicker.isActive) {
            unawaited(_renderTicker.start());
          }
        } else {
          tile.setSymbols(const [], provisional: false);
        }
        _labelCandidatesChanged();
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
      // A zoom-out has no ancestors to borrow — the level just left lies
      // *below* the pending key. Compose its cached descendants instead:
      // a partial cover of sharp pixels beats the background.
      final descendantSources = <String, List<PreparedTile>>{};
      for (final id in pending.keys) {
        if (provisionalSources.containsKey(id)) continue;
        final store = _stores[id]!;
        final dataKey = store.dataKeyFor(tile.key, offset);
        if (dataKey == null) continue;
        final children = store.peekDescendants(dataKey);
        if (children.isNotEmpty) descendantSources[id] = children;
      }
      final descendantRasters = <String, List<RasterTile>>{};
      for (final id in pendingRasters.keys) {
        if (provisionalRasters.containsKey(id)) continue;
        final store = _rasterStores[id]!;
        final dataKey = store.dataKeyFor(tile.key, offset);
        if (dataKey == null) continue;
        final children = store.peekDescendants(dataKey);
        if (children.isNotEmpty) descendantRasters[id] = children;
      }
      if (provisionalSources.isNotEmpty ||
          provisionalRasters.isNotEmpty ||
          descendantSources.isNotEmpty ||
          descendantRasters.isNotEmpty) {
        _enqueueRaster(tile, provisionalSources,
            rasters: provisionalRasters,
            descendantSources: descendantSources,
            descendantRasters: descendantRasters,
            provisional: true,
            priority: priority);
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
    Map<String, List<PreparedTile>> descendantSources = const {},
    Map<String, List<RasterTile>> descendantRasters = const {},
    required bool provisional,
    required int priority,
    bool fadeIn = true,
    bool complete = false,
  }) {
    final job = _RenderJob(
        sources: sources,
        rasters: rasters,
        descendantSources: descendantSources,
        descendantRasters: descendantRasters,
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
    _labelCandidatesChanged();
    if (_foregrounded && !_renderTicker.isActive) _renderTicker.start();
  }

  /// Whether a raster job for [tile] will be followed by a symbol
  /// phase. False below the first symbol layer's minzoom, so zooms
  /// without labels never pay for the extra phase.
  bool _symbolsFollow(_DisplayTile tile, Map<String, PreparedTile> sources) =>
      widget.showLabels &&
      sources.isNotEmpty &&
      SymbolLayouter.anySymbolLayerCovers(
          widget.theme, _styleZoomOf(tile.key.z.toDouble()));

  /// Wall-clock the render pump may spend per frame. Checked before
  /// every job *and* between the labels of a symbol job's shaping, so
  /// no single unit of work can run away with the frame.
  static const int _pumpBudget = 4000;

  void _pumpRenderQueue(Duration _) {
    // Rasterizing while the app is away yields magenta textures that the
    // result cache would then serve for the life of the process. Park
    // the queue instead — [didChangeAppLifecycleState] restarts it.
    // Engine workaround; see the block above [_foregrounded] for what
    // has to change upstream before this can go.
    if (!_foregrounded) {
      _renderTicker.stop();
      return;
    }
    developer.Timeline.startSync('VT render pump');
    final stopwatch = Stopwatch()..start();
    var processed = 0;
    // At least one job per frame, more while within the time budget:
    // the viewport centre comes first, rasters before symbol jobs. The
    // budget is checked before every job — it cannot preempt inside
    // one, which is why a tile's two phases are separate jobs.
    while (!_renderQueue.isEmpty &&
        (processed == 0 || stopwatch.elapsedMicroseconds < _pumpBudget)) {
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
            if (!_symbolsJob(tile, job, stopwatch)) {
              // Shaping ran out of tick. The job keeps its cursor and
              // its already-extracted candidates; requeueing rather
              // than looping here is what lets a raster for another
              // tile — or a newer one for this tile, which supersedes
              // it — take its turn first.
              assert(
                  job.rasters.isEmpty && job.descendantRasters.isEmpty,
                  'a requeued symbols job must own no raster handles: the '
                  'pump skips dispose() for it');
              _renderQueue.enqueueSymbols(tile, job.priority, job);
              processed++;
              continue;
            }
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
        displayKey: tile.key,
        sources: job.sources,
        rasters: job.rasters,
        descendantSources: job.descendantSources,
        descendantRasters: job.descendantRasters);
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
      // what releases the retained level's labels over it into their
      // fade-out.
      tile.setSymbols(const [], provisional: job.provisional);
      _cacheResult(tile, job, const []);
    }
    _labelCandidatesChanged();
    _repaint.trigger();
    _ensureFadeTicker();
    // A publish can be what completes the current level (with fades
    // disabled nothing else would notice), and the pump runs outside
    // the grid update, so the level is complete enough to judge.
    _releaseRetainedIfReady(DateTime.now());
  }

  /// One slice of a tile's symbol phase: extract the candidates (once),
  /// then shape their text for as long as this tick allows. Returns
  /// whether the phase finished — the caller requeues the job if not.
  ///
  /// The tile publishes nothing until the whole batch is shaped. That
  /// is the point: the label pass shapes on a text-cache miss, so
  /// handing it a half-shaped tile would just move the remaining cost
  /// into paint, which has no budget. Until then [_DisplayTile.symbolsPending]
  /// stays set, which is what keeps the previous level's labels
  /// covering the tile — the same mechanism that already covers the
  /// gap between a tile's raster and its symbols.
  bool _symbolsJob(_DisplayTile tile, _RenderJob job, Stopwatch tick) {
    developer.Timeline.startSync('VT symbols');
    final styleZoom = _styleZoomOf(tile.key.z.toDouble());
    var symbols = job.symbols;
    if (symbols == null) {
      // Extraction is cheap next to shaping (sub-ms against several ms
      // on a dense tile), so it runs whole rather than in slices.
      final data = DisplayTileData(
          displayKey: tile.key, sources: job.sources, rasters: const {});
      symbols = job.symbols = SymbolLayouter.layout(
          theme: widget.theme, data: data, styleZoom: styleZoom);
    }
    job.shapeCursor = _labelPainter.prewarm(
      symbols,
      styleZoom,
      from: job.shapeCursor,
      outOfBudget: () => tick.elapsedMicroseconds >= _pumpBudget,
    );
    developer.Timeline.finishSync();
    if (job.shapeCursor < symbols.length) return false;

    tile.setSymbols(symbols, provisional: job.provisional);
    _cacheResult(tile, job, symbols);
    _labelCandidatesChanged();
    _repaint.trigger();
    _ensureFadeTicker();
    // Same as [_rasterizeJob]: a symbol publish can be the last thing
    // the current level was waiting on.
    _releaseRetainedIfReady(DateTime.now());
    return true;
  }

  /// Stores a finished tile in the result cache — final, fully sourced
  /// results only, so a cache hit can never mask a pending retry.
  ///
  /// [symbols] is the layouter's canonical output in its canonical
  /// order, which the collision and draw-order tiebreaks of every
  /// future session inherit through the shared entry.
  void _cacheResult(
      _DisplayTile tile, _RenderJob job, List<SymbolInstance> symbols) {
    if (job.provisional || !job.complete || job.fromCache) return;
    _resultCache?.put(
      tile.key,
      image: tile.image?.clone(),
      symbols: symbols,
      renderedWith: tile.renderedWith ?? const {},
    );
  }

  /// Drops parked fade-out fallbacks whose fade window has passed — any
  /// key still fading from them started no later than the moment its
  /// tile was disposed. Returns whether any are left, so the fade
  /// ticker knows to keep going.
  bool _expireGhostLabels(DateTime now) {
    _ghostLabels.removeWhere((ghosts) =>
        fadeProgressOf(ghosts.since, now, widget.labelFadeDuration) >= 1);
    return _ghostLabels.isNotEmpty;
  }

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
    // Readiness can complete on a fade tick (the last tile's fade-in
    // finishing is exactly such a tick), and after the gesture there is
    // no rebuild left to prune on. Before the ghost expiry: releasing
    // parks ghost labels, which must count as still fading below.
    _releaseRetainedIfReady(now);
    var anyFading = _expireGhostLabels(now);
    for (final tile in _tiles.values) {
      if (tile.fadeProgress(now, widget.tileFadeDuration) < 1) {
        anyFading = true;
      } else {
        tile.disposeUnderlay(); // fully opaque — the underlay is covered
      }
    }
    // Label fades advance inside the label pass; the painter reports
    // whether the last painted frame left any mid-flight. A frame that
    // replayed a frozen placement also owes a pass — without one more
    // frame, a decision taken mid-gesture would stand for good once the
    // gesture stops producing frames.
    anyFading |= _labelPainter.hasActiveFades || _labelPainter.placementPending;
    _repaint.trigger();
    if (!anyFading) {
      _fading = false;
      _fadeTicker.stop();
    }
  }

  /// Restarts the fade ticker from inside a paint. Label fades are
  /// driven by per-frame placement, so one can begin on any painted
  /// frame — the last frame of a gesture, say — without any publish
  /// having primed the ticker. Deferred to after this frame: a paint
  /// callback must not start tickers.
  void _requestFadeFrames() {
    if (_fading || !mounted) return;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted) _ensureFadeTicker();
    });
  }

  double get _devicePixelRatio =>
      MediaQuery.maybeDevicePixelRatioOf(context) ?? 2.0;

  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);
    _updateLabelCamera(camera);
    // Sized before the grid update: that is what triggers the loads
    // that consult the result cache.
    _viewportSize = camera.nonRotatedSize;
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

  /// Source id → cached descendant tiles composing a (possibly partial)
  /// provisional cover on zoom-out. Geometry only — the symbol phase
  /// never lays out from descendants. Only provisional jobs carry any.
  final Map<String, List<PreparedTile>> descendantSources;

  /// Owned descendant raster handles, disposed with the job — the
  /// zoom-out counterpart of the ancestors in [rasters].
  final Map<String, List<RasterTile>> descendantRasters;
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

  /// Whether this job's content came straight out of the result cache,
  /// in which case it is already there and must not be re-put — a
  /// second `put` under the same key mints a second master image and
  /// disposes the one the display tile's clone came from.
  final bool fromCache;

  /// The symbol phase's extracted candidates, held across the ticks its
  /// shaping is spread over. Null until the phase's first slice runs
  /// (or set up front by the result-cache path, which has them already
  /// and only owes the shaping).
  List<SymbolInstance>? symbols;

  /// How far [LabelPainter.prewarm] has got through [symbols]. The
  /// batch is published only once this reaches its length.
  int shapeCursor = 0;

  _RenderJob({
    required this.sources,
    required this.rasters,
    required this.provisional,
    required this.priority,
    required this.fadeIn,
    required this.complete,
    required this.generation,
    this.descendantSources = const {},
    this.descendantRasters = const {},
    this.fromCache = false,
    this.symbols,
  });

  void dispose() {
    for (final raster in rasters.values) {
      raster.dispose();
    }
    for (final rasters in descendantRasters.values) {
      for (final raster in rasters) {
        raster.dispose();
      }
    }
  }
}

/// A disposed retained tile's labels, parked since [since] as fade-out
/// fallbacks — never placement candidates. [key] is the display tile
/// they were laid out for, which is what positions them.
typedef _GhostLabels = ({
  TileKey key,
  List<SymbolInstance> symbols,
  DateTime since,
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

  /// Whether [symbols] came from a provisional (ancestor-data) layout
  /// rather than this tile's own final data. Provisional labels bridge
  /// the screen but do not count as symbol coverage for the retention
  /// rules — see `_currentStatuses`.
  var symbolsProvisional = false;

  /// A symbol-extraction job is queued for this tile: its labels are
  /// not there yet, so for retention purposes it still counts as
  /// loading even when its raster already landed.
  var symbolsPending = false;
  var isProvisional = false;
  DateTime? readyAt;

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

  /// Publishes [symbols] as this tile's labels. Which of them fade in
  /// — and what their arrival fades *out* — is not decided here: the
  /// label painter tracks one opacity per label identity across all
  /// tiles, so a republish (provisional→final swap, refresh, retry) or
  /// a zoom crossing simply changes which instances carry each key.
  void setSymbols(
    List<SymbolInstance> symbols, {
    required bool provisional,
  }) {
    this.symbols = symbols;
    symbolsProvisional = provisional;
    symbolsPending = false;
    if (!isProvisional && state == _TileState.loading) {
      // Deferred classification of a final, image-less tile.
      state = (image == null && symbols.isEmpty)
          ? _TileState.empty
          : _TileState.ready;
    }
  }

  /// Called once the fade has finished — the underlay is fully covered.
  void disposeUnderlay() {
    underlay?.dispose();
    underlay = null;
  }

  double fadeProgress(DateTime now, Duration duration) =>
      fadeProgressOf(readyAt, now, duration);

  void dispose() {
    _retryTimer?.cancel();
    cancellation.cancel();
    image?.dispose();
    image = null;
    underlay?.dispose();
    underlay = null;
    symbols = const [];
    symbolsProvisional = false;
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
    // can outlive the tile they were laid out for. Ghost-only symbols
    // never compete for placement — they are fallback drawables for
    // keys mid-fade-out, nothing more.
    void addSymbols(
      TileKey key,
      List<SymbolInstance> symbols, {
      bool ghostOnly = false,
    }) {
      if (symbols.isEmpty) return;
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
      for (final symbol in symbols) {
        placed.add(PlacedSymbol(
          instance: symbol,
          screenAnchor: transform.apply(symbol.anchor),
          screenAngle: symbol.alongLine ? symbol.angle + rotation : 0,
          transform: symbol.alongLine ? transform : null,
          ghostOnly: ghostOnly,
          order: placed.length,
        ));
      }
    }

    for (final tile in state._tiles.values) {
      addSymbols(tile.key, tile.symbols);
    }
    // While a zoom level change is in flight, keep the previous level's
    // labels wherever the new level has no label data yet — otherwise
    // every label blinks out for a few frames on zoom. Current-level
    // symbols are added first, so they win collisions. Once the new
    // level covers a retained tile, its labels stop claiming space and
    // serve only as fade-out fallbacks. In steady state nothing is
    // retained and the memoized key set need not be built.
    if (state._retained.isNotEmpty) {
      final needed =
          state._retainedSymbolKeys ??= state._retainedKeysWithSymbols();
      for (final retained in state._retained.values) {
        addSymbols(retained.key, retained.symbols,
            ghostOnly: !needed.contains(retained.key));
      }
    }
    // Parked labels of disposed retained tiles — fallbacks for fades
    // their tile no longer exists to draw.
    for (final ghosts in state._ghostLabels) {
      addSymbols(ghosts.key, ghosts.symbols, ghostOnly: true);
    }
    if (placed.isEmpty) {
      state._drawnLastFrame.clear();
      // Nothing is on offer, so nothing can fade and nothing can be
      // placed. The painter's flags are read by the fade ticker, and
      // left at whatever the last frame with labels set them to they
      // would keep it scheduling frames forever — a fade with no
      // instance left to draw it, a pass with nothing to place.
      state._labelPainter.reset();
      return;
    }
    final drawn = state._labelPainter.paint(
      canvas: canvas,
      screenSize: size,
      styleZoom: styleZoom,
      symbols: placed,
      sprites: state.widget.sprites,
      devicePixelRatio: devicePixelRatio,
      labelFadeDuration: state.widget.labelFadeDuration,
      placementGeneration: state._labelGeneration,
      now: now,
    );
    // Recorded so the retention pin keeps what was actually on screen,
    // rather than every candidate offered. Rebuilt in place with a
    // plain loop: the set keeps its capacity, so steady-state frames
    // allocate nothing here. Left empty while label fades are disabled
    // — nothing consumes it then.
    state._drawnLastFrame.clear();
    if (state.widget.labelFadeDuration > Duration.zero) {
      for (final symbol in drawn) {
        state._drawnLastFrame.add(symbol.instance);
      }
      // A fade can begin on any painted frame, and a frame that replayed
      // a frozen placement owes a pass, so the ticker that keeps both
      // going after the last gesture frame is requested from here.
      if (state._labelPainter.hasActiveFades ||
          state._labelPainter.placementPending) {
        state._requestFadeFrames();
      }
    }
  }

  @override
  bool shouldRepaint(covariant _VectorMapPainter oldDelegate) =>
      oldDelegate.camera != camera ||
      oldDelegate.state != state ||
      oldDelegate.devicePixelRatio != devicePixelRatio;
}
