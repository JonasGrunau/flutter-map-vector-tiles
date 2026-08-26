/// Frame-timing harness for zoom crossings. See `README.md` for how to run it
/// and `AGENTS.md` for why each knob is shaped the way it is.
///
/// Reports two numbers per phase, and the distinction is the whole point:
///
/// * **BUILD** is the UI thread — tile rasterization (`Picture.toImageSync`),
///   symbol layout and text shaping all land here, because the render pump
///   runs on it.
/// * **RASTER** is the GPU thread. `saveLayer` costs show up here and
///   *nowhere else*; a `saveLayer` only records an op during picture
///   recording, so no Dart-side stopwatch can see it.
///
/// Getting those two mixed up is the single easiest way to spend a day fixing
/// the wrong thing.
library;

// This reaches into the parent package's `src/` for two `@visibleForTesting`
// debug counters, and it is neither that library nor a test. Both lints are
// right in general and wrong here: a bench that cannot tell "served from
// cache" from "re-rendered the whole screen" is not worth running, and
// widening the public API for a development tool would be the worse trade.
// ignore_for_file: implementation_imports
// ignore_for_file: invalid_use_of_visible_for_testing_member

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_vector_tiles/flutter_map_vector_tiles.dart' as vt;
// Deliberately internal: the bench is a development tool, not a consumer of
// the public API, and these debug counters are how a phase distinguishes
// "served from cache" from "re-rendered the whole screen". See AGENTS.md.
import 'package:flutter_map_vector_tiles/src/render/label_painter.dart'
    show DrawnLabelRecord, LabelPainter;
import 'package:flutter_map_vector_tiles/src/render/symbol_layouter.dart'
    show SymbolLayouter;
import 'package:flutter_map_vector_tiles/src/render/tile_rasterizer.dart'
    show TileRasterizer;
import 'package:latlong2/latlong.dart';

/// Key-free by default so the harness is reproducible without a key. Any
/// MapLibre style URL works; `{key}` is substituted from [_apiKey].
const _styleUrl = String.fromEnvironment(
  'STYLE_URL',
  defaultValue: 'https://tiles.openfreemap.org/styles/liberty',
);
const _apiKey = String.fromEnvironment('MAPTILER_KEY');

/// Tag for the log lines, so two runs can be diffed.
const _label = String.fromEnvironment('BENCH_LABEL', defaultValue: 'run');

/// `bench` runs the phase matrix; `idle` parks the map at [_idleZoom] so you
/// can screenshot it and confirm which labels the style is actually drawing.
/// That check is not optional busywork: aiming this harness at a zoom band
/// whose POIs never switch on measures nothing, convincingly.
/// `manual` hands the camera to your fingers instead of the sweep driver:
/// gestures are enabled, a report is printed every [_manualWindowSeconds],
/// and every frame over the 60 Hz budget logs a `JANK` line tagged with the
/// zoom it happened at — for chasing a stutter you can feel but the scripted
/// sweep does not reproduce.
/// `stability` measures label steadiness instead of frame time: four slow
/// *monotonic* sweeps across the band (cold in/out, then warm in/out), each
/// reporting a `STABILITY` line counting pop-ins (a label appearing at full
/// opacity with no fade), pop-outs (vanishing from full opacity with no
/// ghost) and blinks (disappearing and returning at the same spot within
/// [_blinkWindow]). Monotonic is the point: on a one-way sweep a zoom gate
/// fires at most once, so every blink is a genuine placement flip-flop —
/// an oscillating sweep would re-cross its gates and drown the signal.
const _mode = String.fromEnvironment('BENCH_MODE', defaultValue: 'bench');

/// Which app's layer wiring the harness mirrors. `default` is the bench's
/// own setup. `safenow` reproduces the SafeNow app's `MapBaseLayer`/`SnMap`
/// wiring exactly: no raster sources, 16 MiB decoded-tile memory cache,
/// 150 MiB disk cache, zoom clamped to 2..21, the style's light background,
/// and the app's gesture set in manual mode. Point `STYLE_URL` at that
/// app's style document and pass its key via `MAPTILER_KEY` on the command
/// line — keys must never be committed to this repo.
const _setup = String.fromEnvironment('BENCH_SETUP', defaultValue: 'default');
const _safenow = _setup == 'safenow';

/// Reporting cadence for `manual` mode.
const _manualWindowSeconds = 5;

/// One direction of a `stability` sweep. Slow on purpose: ~0.16 zoom/s
/// gives every publish, placement pass and fade time to play out at each
/// crossing, the way a browsing finger does.
const _stabilitySweepSeconds = 16;

/// How long after a label disappears a reappearance nearby still counts
/// as a blink. At sweep speed this spans ~0.5 zoom — further apart than
/// that reads as two events, not a twitch.
const _blinkWindow = Duration(seconds: 4);

/// Zooms are given in tenths, because `double.fromEnvironment` does not exist.
const _idleZoom = int.fromEnvironment('BENCH_ZOOM10', defaultValue: 170) / 10;

/// The crossing to oscillate across. The default straddles z17, which is where
/// OpenFreeMap Liberty opens the POI floodgates — see `AGENTS.md` for that
/// style's rank table, and re-derive it for any other style before trusting a
/// number out of this harness.
const _lo = int.fromEnvironment('BENCH_LO', defaultValue: 163) / 10;
const _hi = int.fromEnvironment('BENCH_HI', defaultValue: 177) / 10;

/// Munich centre — dense enough to have something to draw at every zoom.
const _lat = int.fromEnvironment('BENCH_LAT_E5', defaultValue: 4813720) / 1e5;
const _lon = int.fromEnvironment('BENCH_LON_E5', defaultValue: 1157550) / 1e5;

void main() => runApp(const BenchApp());

class BenchApp extends StatelessWidget {
  const BenchApp({super.key});

  @override
  Widget build(BuildContext context) => const MaterialApp(
        title: 'flutter_map_vector_tiles bench',
        debugShowCheckedModeBanner: false,
        home: BenchPage(),
      );
}

class BenchPage extends StatefulWidget {
  const BenchPage({super.key});

  @override
  State<BenchPage> createState() => _BenchPageState();
}

class _BenchPageState extends State<BenchPage>
    with SingleTickerProviderStateMixin {
  /// One measured arm of the matrix.
  ///
  /// [cacheMiB] of `-1` means [vt.VectorTileLayer.autoRasterCacheBytes] — the
  /// shipped default. The labels-off arm is the control: if the label pipeline
  /// is what costs, turning it off at the same speed has to flatten the
  /// profile, and if it does not, the cost is somewhere else entirely.
  /// [cold] arms measure the *first* sweeps after the caches are
  /// cleared — network/decode/rasterize/shaping all land inside the
  /// recording window. That is the crossing a user feels first, and the
  /// warmed arms deliberately exclude it.
  static const _phases = <({int ms, bool labels, int cacheMiB, bool cold})>[
    (ms: 1200, labels: true, cacheMiB: -1, cold: true),
    (ms: 150, labels: true, cacheMiB: -1, cold: false),
    (ms: 150, labels: true, cacheMiB: 64, cold: false),
    (ms: 150, labels: false, cacheMiB: -1, cold: false),
    (ms: 400, labels: true, cacheMiB: -1, cold: false),
  ];

  /// Long enough for ~1000 frames at 120 Hz — percentiles over a few hundred
  /// frames are noise.
  static const _measureSeconds = 8;

  late final Future<vt.Style> _style;
  late final AnimationController _zoom;
  final _controller = MapController();
  final _mapReady = Completer<void>();
  AppLifecycleListener? _lifecycle;

  var _build = <int>[];
  var _raster = <int>[];
  var _recording = false;
  var _interrupted = false;
  var _allFrames = 0;
  DateTime? _recordStart;

  // Manual mode: zoom band covered inside the current reporting window, and
  // the live zoom for the overlay. The notifier deliberately bypasses
  // setState — rebuilding the whole page on every frame of a pinch would put
  // the harness's own cost into the numbers it reports.
  var _windowZoomLo = double.infinity;
  var _windowZoomHi = double.negativeInfinity;
  final _liveZoom = ValueNotifier<double?>(null);

  // Last-seen values of the package's phase-time accumulators, diffed once
  // per frame by [_onFrameEnd] to attribute a build spike to rasterize /
  // symbol layout / label paint — and, within the label pass, to a full
  // placement pass vs paragraph shaping.
  var _frameRasterCount = 0;
  var _frameRasterUs = 0;
  var _frameLayoutUs = 0;
  var _frameLabelUs = 0;
  var _framePlaceUs = 0;
  var _frameShapeUs = 0;
  var _frameSweepUs = 0;
  var _frameDrawUs = 0;

  var _showLabels = true;
  var _cacheMiB = -1;
  var _status = 'loading style…';

  // Label-stability tracking (`stability` and `manual` modes): what the
  // label pass drew last frame, per continuity key, in zoom-20 world
  // pixels — a frame-rate- and camera-independent identity, so a label
  // can be recognised across a whole sweep, not just across one frame.
  final _labelsPrev = <Object, List<_SeenLabel>>{};
  final _labelsGone = <_GoneLabel>[];
  var _stab = _StabilityCounters();

  @override
  void initState() {
    super.initState();
    _style = const vt.StyleReader(uri: _styleUrl, apiKey: _apiKey).read();
    // A crossing is a *sweep*: the camera passes through the threshold over
    // many frames, which is what staggers the tile publishes and the label
    // fades. A `move()` jump produces one frame per crossing and measures
    // nothing — an early version of this harness did exactly that and
    // reported a perfectly smooth map.
    _zoom = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 400))
      ..addListener(() {
        _controller.move(
            const LatLng(_lat, _lon), _lo + (_hi - _lo) * _zoom.value);
      });
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    SchedulerBinding.instance.addPostFrameCallback(_onFrameEnd);
    if (_mode == 'stability' || _mode == 'manual') {
      LabelPainter.debugDrawnProbe = _onLabelsDrawn;
    }
    // A backgrounding mid-run parks the render pump (the layer stops
    // rasterizing from `inactive` onwards), so the numbers would be fiction.
    // Better to flag the run than to average it in.
    _lifecycle = AppLifecycleListener(onStateChange: (state) {
      if (_recording && state != AppLifecycleState.resumed) _interrupted = true;
    });
    unawaited(_run());
  }

  @override
  void dispose() {
    LabelPainter.debugDrawnProbe = null;
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    _lifecycle?.dispose();
    _liveZoom.dispose();
    _zoom.dispose();
    _style.then((style) => style.dispose()).ignore();
    super.dispose();
  }

  /// Per-frame delta of the package's phase-time accumulators. Runs as a
  /// self-re-registering post-frame callback, so each delta is exactly one
  /// frame's worth of publish work — the alignment a batched timings
  /// callback cannot give. A frame whose rasterize+layout+label time alone
  /// approaches the 120 Hz budget is logged with its split, which is the
  /// attribution the JANK lines lack.
  void _onFrameEnd(Duration _) {
    if (!mounted) return;
    SchedulerBinding.instance.addPostFrameCallback(_onFrameEnd);
    final tiles = TileRasterizer.debugRasterizeCount - _frameRasterCount;
    final raster = TileRasterizer.debugRasterizeMicros - _frameRasterUs;
    final layout = SymbolLayouter.debugLayoutMicros - _frameLayoutUs;
    final labels = LabelPainter.debugPaintMicros - _frameLabelUs;
    final place = LabelPainter.debugPlaceMicros - _framePlaceUs;
    final shape = LabelPainter.debugShapeMicros - _frameShapeUs;
    final sweep = LabelPainter.debugSweepMicros - _frameSweepUs;
    final draw = LabelPainter.debugDrawMicros - _frameDrawUs;
    _frameRasterCount += tiles;
    _frameRasterUs += raster;
    _frameLayoutUs += layout;
    _frameLabelUs += labels;
    _framePlaceUs += place;
    _frameShapeUs += shape;
    _frameSweepUs += sweep;
    _frameDrawUs += draw;
    if (!_recording || raster + layout + labels <= 6000) return;
    String ms(int us) => (us / 1000).toStringAsFixed(1);
    final zoom = _zoomNow();
    debugPrint('BENCH[$_label] WORK '
        'z=${zoom?.toStringAsFixed(2) ?? '?'} tiles=$tiles '
        'raster=${ms(raster)}ms layout=${ms(layout)}ms '
        'labels=${ms(labels)}ms place=${ms(place)}ms shape=${ms(shape)}ms '
        'sweep=${ms(sweep)}ms draw=${ms(draw)}ms');
  }

  double? _zoomNow() => _mapReady.isCompleted ? _controller.camera.zoom : null;

  /// Matching radii, in screen pixels at the moment of the event. A
  /// continuation must be found within one frame's camera drift; a blink
  /// may return slightly off (the successor level re-derives anchors).
  static const _continuityRadiusPx = 48.0;
  static const _blinkRadiusPx = 64.0;

  /// Seam twins draw one label twice at (near) the same anchor; merged
  /// before matching or every twin count change reads as an event.
  static const _twinRadiusPx = 4.0;

  /// Consumes one frame's drawn-label report from the painter. Converts
  /// every anchor to zoom-20 world pixels, matches it against last
  /// frame's, and counts the three stability violations: a label
  /// *appearing* at full opacity (pop-in — it skipped its fade-in), a
  /// full-opacity label *vanishing* with no ghost behind it (pop-out),
  /// and a label returning to a spot it left within [_blinkWindow]
  /// (blink — the visible→hidden→visible twitch). Counters only move
  /// while a window is recording; the frame-to-frame memory runs
  /// always, so a window never opens against an empty previous frame.
  void _onLabelsDrawn(double styleZoom, List<DrawnLabelRecord> drawn) {
    if (!_mapReady.isCompleted) return;
    final camera = _controller.camera;
    final scale = math.pow(2.0, 20 - camera.zoom).toDouble();
    final worldCenter = camera.projectAtZoom(camera.center, camera.zoom);
    final size = camera.nonRotatedSize;
    final screenCenter = Offset(size.width / 2, size.height / 2);
    final cosR = math.cos(camera.rotationRad);
    final sinR = math.sin(camera.rotationRad);
    final now = DateTime.now();

    // This frame's labels, twins merged, in zoom-20 world pixels.
    final current = <Object, List<_SeenLabel>>{};
    final twinR2 = math.pow(_twinRadiusPx * scale, 2);
    for (final record in drawn) {
      final rel = record.position - screenCenter;
      // Anchors are screen-space; undo the camera rotation.
      final level =
          Offset(rel.dx * cosR + rel.dy * sinR, rel.dy * cosR - rel.dx * sinR);
      final world = (worldCenter + level) * scale;
      final list = current[record.key] ??= [];
      _SeenLabel? twin;
      for (final other in list) {
        if ((other.world - world).distanceSquared < twinR2) {
          twin = other;
          break;
        }
      }
      if (twin != null) {
        twin.opacity = math.max(twin.opacity, record.opacity);
        twin.ghost = twin.ghost && record.ghost;
      } else {
        list.add(
            _SeenLabel(world, record.opacity, record.ghost, record.alongLine));
      }
    }

    final contR2 = math.pow(_continuityRadiusPx * scale, 2);
    final blinkR2 = math.pow(_blinkRadiusPx * scale, 2);
    current.forEach((key, list) {
      final prev = _labelsPrev[key];
      for (final label in list) {
        _SeenLabel? match;
        var best = contR2;
        if (prev != null) {
          for (final p in prev) {
            if (p.matched) continue;
            final d = (p.world - label.world).distanceSquared;
            if (d < best) {
              best = d;
              match = p;
            }
          }
        }
        if (match != null) {
          match.matched = true;
          continue;
        }
        // A ghost never starts a life: an unmatched one is the tail of a
        // fade whose start this tracker missed.
        if (label.ghost || !_recording) continue;
        label.alongLine ? _stab.appearLn++ : _stab.appearPt++;
        if (label.opacity >= 1) {
          label.alongLine ? _stab.popInLn++ : _stab.popInPt++;
        }
        for (var i = 0; i < _labelsGone.length; i++) {
          final gone = _labelsGone[i];
          if (gone.key == key &&
              (gone.world - label.world).distanceSquared < blinkR2) {
            label.alongLine ? _stab.blinkLn++ : _stab.blinkPt++;
            _labelsGone.removeAt(i);
            break;
          }
        }
      }
    });
    _labelsPrev.forEach((key, list) {
      for (final p in list) {
        if (p.matched) continue;
        if (_recording) {
          p.alongLine ? _stab.goneLn++ : _stab.gonePt++;
          if (!p.ghost && p.opacity >= 1) {
            p.alongLine ? _stab.popOutLn++ : _stab.popOutPt++;
          }
        }
        _labelsGone.add(_GoneLabel(key, p.world, now, p.alongLine));
      }
    });
    _labelsGone.removeWhere((gone) => now.difference(gone.at) > _blinkWindow);
    _labelsPrev
      ..clear()
      ..addAll(current);
    if (_recording) {
      _stab.frames++;
      _stab.seen += drawn.length;
    }
  }

  void _reportStability(String phase) {
    final s = _stab;
    final frames = s.frames == 0 ? 1 : s.frames;
    debugPrint('BENCH[$_label] STABILITY $phase frames=${s.frames} '
        'seen/frame=${(s.seen / frames).toStringAsFixed(0)} · '
        'pt popIn=${s.popInPt} popOut=${s.popOutPt} blink=${s.blinkPt} '
        'appear=${s.appearPt} gone=${s.gonePt} · '
        'ln popIn=${s.popInLn} popOut=${s.popOutLn} blink=${s.blinkLn} '
        'appear=${s.appearLn} gone=${s.goneLn}');
  }

  /// Four slow monotonic sweeps: cold in, back out, warm in, back out.
  /// Each reports its STABILITY counters plus the usual frame stats.
  Future<void> _runStability() async {
    _say('stability · monotonic z$_lo↔$_hi · '
        '${_stabilitySweepSeconds}s per direction');
    vt.VectorTileLayer.clearMemoryCache();
    _controller.move(const LatLng(_lat, _lon), _lo);
    await Future<void>.delayed(const Duration(seconds: 4));
    _zoom.duration = const Duration(seconds: _stabilitySweepSeconds);
    for (final pass in ['cold', 'warm']) {
      for (final direction in ['in', 'out']) {
        _stab = _StabilityCounters();
        _build = <int>[];
        _raster = <int>[];
        _allFrames = 0;
        _interrupted = false;
        final layouts0 = SymbolLayouter.debugLayoutCount;
        final rasters0 = TileRasterizer.debugRasterizeCount;
        final rasterUs0 = TileRasterizer.debugRasterizeMicros;
        final layoutUs0 = SymbolLayouter.debugLayoutMicros;
        final labelUs0 = LabelPainter.debugPaintMicros;
        _say('stability $pass-$direction…');
        _recordStart = DateTime.now();
        _recording = true;
        if (direction == 'in') {
          await _zoom.forward(from: 0);
        } else {
          await _zoom.reverse(from: 1);
        }
        // Let the tail-end fades land before closing the books.
        await Future<void>.delayed(const Duration(seconds: 2));
        _recording = false;
        _reportStability('$pass-$direction z=$_lo..$_hi');
        _report('stability $pass-$direction',
            layouts: SymbolLayouter.debugLayoutCount - layouts0,
            rasters: TileRasterizer.debugRasterizeCount - rasters0,
            rasterUs: TileRasterizer.debugRasterizeMicros - rasterUs0,
            layoutUs: SymbolLayouter.debugLayoutMicros - layoutUs0,
            labelUs: LabelPainter.debugPaintMicros - labelUs0);
      }
    }
    debugPrint('BENCH[$_label] ===== END =====');
    _say('stability done');
  }

  void _onTimings(List<FrameTiming> timings) {
    _allFrames += timings.length;
    if (!_recording) return;
    // The zoom is sampled rather than derived from the driver — in manual
    // mode the camera is in the user's hands. The timings callback lags the
    // frames it describes by a beat, which is close enough to tag a jank
    // with the zoom that caused it.
    final zoom = _zoomNow();
    if (zoom != null) {
      if (zoom < _windowZoomLo) _windowZoomLo = zoom;
      if (zoom > _windowZoomHi) _windowZoomHi = zoom;
      _liveZoom.value = zoom;
    }
    for (final timing in timings) {
      final build = timing.buildDuration.inMicroseconds;
      final raster = timing.rasterDuration.inMicroseconds;
      _build.add(build);
      _raster.add(raster);
      // A frame past the 60 Hz budget is a hitch anyone can see; log it the
      // moment it happens so it lines up with what the finger just did.
      if (zoom != null && (build > 16667 || raster > 16667)) {
        debugPrint('BENCH[$_label] JANK z=${zoom.toStringAsFixed(2)} '
            'build=${(build / 1000).toStringAsFixed(1)}ms '
            'raster=${(raster / 1000).toStringAsFixed(1)}ms');
      }
    }
  }

  Future<void> _run() async {
    final style = await _style;
    // The map lives behind a FutureBuilder, so the style future completing is
    // not the same as the map being laid out — the controller throws until it
    // has rendered once.
    await _mapReady.future;
    await Future<void>.delayed(const Duration(milliseconds: 500));

    if (_mode == 'idle') {
      _controller.move(const LatLng(_lat, _lon), _idleZoom);
      final symbols = style.theme.layers
          .where((l) => l.runtimeType.toString().contains('Symbol'))
          .length;
      _say('idle z$_idleZoom · ${style.theme.layers.length} layers, '
          '$symbols symbol · sprites=${style.sprites != null}');
      return;
    }

    if (_mode == 'manual') {
      await _runManual();
      return;
    }

    if (_mode == 'stability') {
      await _runStability();
      return;
    }

    for (final phase in _phases) {
      await _runPhase(phase);
    }
    debugPrint('BENCH[$_label] ===== END =====');
    _say('all phases done');
  }

  /// The camera belongs to the user's fingers; this loop only watches.
  /// Records forever in fixed windows, reporting each window that produced
  /// frames — a window with none means an untouched screen, and printing it
  /// would drown the interesting ones. Cache-work counters are deltas per
  /// window, so `layouts=0 rasterizes=0` keeps its meaning: that window was
  /// served entirely from cache.
  Future<void> _runManual() async {
    _say('manual · zoom by hand · window=${_manualWindowSeconds}s');
    var layouts = SymbolLayouter.debugLayoutCount;
    var rasters = TileRasterizer.debugRasterizeCount;
    var rasterUs = TileRasterizer.debugRasterizeMicros;
    var layoutUs = SymbolLayouter.debugLayoutMicros;
    var labelUs = LabelPainter.debugPaintMicros;
    var layerUs = Map<String, int>.of(TileRasterizer.debugLayerMicros);
    var placeUs = LabelPainter.debugPlaceMicros;
    var replayUs = LabelPainter.debugReplayMicros;
    var sortUs = LabelPainter.debugSortMicros;
    var shapeUs = LabelPainter.debugShapeMicros;
    var sweepUs = LabelPainter.debugSweepMicros;
    var drawUs = LabelPainter.debugDrawMicros;
    var placingFrames = LabelPainter.debugPlacingFrames;
    while (mounted) {
      _build = <int>[];
      _raster = <int>[];
      _allFrames = 0;
      _interrupted = false;
      _windowZoomLo = double.infinity;
      _windowZoomHi = double.negativeInfinity;
      _recordStart = DateTime.now();
      _recording = true;
      await Future<void>.delayed(const Duration(seconds: _manualWindowSeconds));
      _recording = false;
      final layoutsNow = SymbolLayouter.debugLayoutCount;
      final rastersNow = TileRasterizer.debugRasterizeCount;
      final rasterUsNow = TileRasterizer.debugRasterizeMicros;
      final layoutUsNow = SymbolLayouter.debugLayoutMicros;
      final labelUsNow = LabelPainter.debugPaintMicros;
      if (_build.isNotEmpty) {
        final band = _windowZoomLo.isFinite
            ? 'z=${_windowZoomLo.toStringAsFixed(2)}'
                '..${_windowZoomHi.toStringAsFixed(2)}'
            : 'z=?';
        _report('manual $band',
            layouts: layoutsNow - layouts,
            rasters: rastersNow - rasters,
            rasterUs: rasterUsNow - rasterUs,
            layoutUs: layoutUsNow - layoutUs,
            labelUs: labelUsNow - labelUs,
            layerUs: _layerDelta(layerUs),
            labelSplit: (
              place: LabelPainter.debugPlaceMicros - placeUs,
              replay: LabelPainter.debugReplayMicros - replayUs,
              sort: LabelPainter.debugSortMicros - sortUs,
              shape: LabelPainter.debugShapeMicros - shapeUs,
              sweep: LabelPainter.debugSweepMicros - sweepUs,
              draw: LabelPainter.debugDrawMicros - drawUs,
              placing: LabelPainter.debugPlacingFrames - placingFrames,
            ));
        _reportStability('manual');
      }
      _stab = _StabilityCounters();
      layouts = layoutsNow;
      rasters = rastersNow;
      rasterUs = rasterUsNow;
      layoutUs = layoutUsNow;
      labelUs = labelUsNow;
      layerUs = Map<String, int>.of(TileRasterizer.debugLayerMicros);
      placeUs = LabelPainter.debugPlaceMicros;
      replayUs = LabelPainter.debugReplayMicros;
      sortUs = LabelPainter.debugSortMicros;
      shapeUs = LabelPainter.debugShapeMicros;
      sweepUs = LabelPainter.debugSweepMicros;
      drawUs = LabelPainter.debugDrawMicros;
      placingFrames = LabelPainter.debugPlacingFrames;
    }
  }

  Future<void> _runPhase(
      ({int ms, bool labels, int cacheMiB, bool cold}) phase) async {
    final cache = phase.cacheMiB < 0 ? 'AUTO' : '${phase.cacheMiB}MiB';
    if (phase.labels != _showLabels || phase.cacheMiB != _cacheMiB) {
      setState(() {
        _showLabels = phase.labels;
        _cacheMiB = phase.cacheMiB;
      });
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    // Every arm starts cold, or a later one inherits the warm tiles an
    // earlier one left and the comparison means nothing.
    vt.VectorTileLayer.clearMemoryCache();
    await Future<void>.delayed(const Duration(seconds: 2));

    if (!phase.cold) {
      _say('${phase.ms}ms · labels=${phase.labels} · cache=$cache (warming)');
      _zoom.duration = const Duration(milliseconds: 1200);
      for (var i = 0; i < 2; i++) {
        await _zoom.forward(from: 0);
        await Future<void>.delayed(const Duration(seconds: 3));
        await _zoom.reverse(from: 1);
        await Future<void>.delayed(const Duration(seconds: 3));
      }
    }

    final kind = phase.cold ? 'COLD measuring' : 'measuring';
    _say('${phase.ms}ms · labels=${phase.labels} · cache=$cache ($kind)');
    _build = <int>[];
    _raster = <int>[];
    _allFrames = 0;
    _interrupted = false;
    final layouts0 = SymbolLayouter.debugLayoutCount;
    final rasters0 = TileRasterizer.debugRasterizeCount;
    final rasterUs0 = TileRasterizer.debugRasterizeMicros;
    final layoutUs0 = SymbolLayouter.debugLayoutMicros;
    final labelUs0 = LabelPainter.debugPaintMicros;
    final layerUs0 = Map<String, int>.of(TileRasterizer.debugLayerMicros);
    final placeUs0 = LabelPainter.debugPlaceMicros;
    final replayUs0 = LabelPainter.debugReplayMicros;
    final sortUs0 = LabelPainter.debugSortMicros;
    final shapeUs0 = LabelPainter.debugShapeMicros;
    final sweepUs0 = LabelPainter.debugSweepMicros;
    final drawUs0 = LabelPainter.debugDrawMicros;
    final placing0 = LabelPainter.debugPlacingFrames;
    _zoom.duration = Duration(milliseconds: phase.ms);
    _zoom.value = 0;
    _recordStart = DateTime.now();
    _recording = true;
    unawaited(_zoom.repeat(reverse: true));
    await Future<void>.delayed(const Duration(seconds: _measureSeconds));
    _recording = false;
    _zoom.stop();

    _report(
        '${phase.ms}ms labels=${phase.labels} cache=$cache'
        '${phase.cold ? ' COLD' : ''}',
        layouts: SymbolLayouter.debugLayoutCount - layouts0,
        rasters: TileRasterizer.debugRasterizeCount - rasters0,
        rasterUs: TileRasterizer.debugRasterizeMicros - rasterUs0,
        layoutUs: SymbolLayouter.debugLayoutMicros - layoutUs0,
        labelUs: LabelPainter.debugPaintMicros - labelUs0,
        layerUs: _layerDelta(layerUs0),
        labelSplit: (
          place: LabelPainter.debugPlaceMicros - placeUs0,
          replay: LabelPainter.debugReplayMicros - replayUs0,
          sort: LabelPainter.debugSortMicros - sortUs0,
          shape: LabelPainter.debugShapeMicros - shapeUs0,
          sweep: LabelPainter.debugSweepMicros - sweepUs0,
          draw: LabelPainter.debugDrawMicros - drawUs0,
          placing: LabelPainter.debugPlacingFrames - placing0,
        ));
    await Future<void>.delayed(const Duration(seconds: 3));
  }

  void _say(String message) {
    debugPrint('BENCH[$_label] $message');
    if (mounted) setState(() => _status = message);
  }

  /// Per-layer paint time accumulated since [before] was snapshotted.
  static Map<String, int> _layerDelta(Map<String, int> before) {
    final delta = <String, int>{};
    TileRasterizer.debugLayerMicros.forEach((id, us) {
      final d = us - (before[id] ?? 0);
      if (d > 0) delta[id] = d;
    });
    return delta;
  }

  void _report(String phase,
      {required int layouts,
      required int rasters,
      required int rasterUs,
      required int layoutUs,
      required int labelUs,
      Map<String, int>? layerUs,
      ({
        int place,
        int replay,
        int sort,
        int shape,
        int sweep,
        int draw,
        int placing
      })? labelSplit}) {
    String stats(String name, List<int> samples) {
      if (samples.isEmpty) return '$name: no frames';
      final sorted = [...samples]..sort();
      int percentile(double p) => sorted[((sorted.length - 1) * p).round()];
      String ms(int us) => (us / 1000).toStringAsFixed(2);
      // 8.33ms is the budget on a ProMotion device and 16.7ms on a 60Hz one.
      // Both are reported because a run that clears 16.7 but misses 8.3 on a
      // 120Hz phone is still a visible hitch.
      final over8 = samples.where((x) => x > 8333).length;
      final over16 = samples.where((x) => x > 16667).length;
      return '$name n=${samples.length} '
          'p50=${ms(percentile(0.5))} p90=${ms(percentile(0.90))} '
          'p99=${ms(percentile(0.99))} max=${ms(sorted.last)} '
          '>8.3=$over8 (${(100 * over8 / samples.length).toStringAsFixed(1)}%) '
          '>16.7=$over16 '
          '(${(100 * over16 / samples.length).toStringAsFixed(1)}%)';
    }

    final seconds =
        DateTime.now().difference(_recordStart!).inMilliseconds / 1000;
    // layouts/rasterizes are the headline for cache work: a crossing served
    // entirely from the finished-tile cache reports zero of both.
    debugPrint('BENCH[$_label] --- $phase --- '
        'window=${seconds.toStringAsFixed(1)}s '
        'fps=${(_allFrames / seconds).toStringAsFixed(1)} '
        'layouts=$layouts rasterizes=$rasters interrupted=$_interrupted');
    debugPrint('BENCH[$_label]   ${stats("BUILD ", _build)}');
    debugPrint('BENCH[$_label]   ${stats("RASTER", _raster)}');
    // Where the window's publish work went, in UI-thread wall time. The
    // remainder of BUILD (flutter_map, widget build, everything else) is
    // whatever these three do not account for.
    String ms(int us) => (us / 1000).toStringAsFixed(1);
    debugPrint('BENCH[$_label]   WORK   rasterize=${ms(rasterUs)}ms '
        'layout=${ms(layoutUs)}ms labels=${ms(labelUs)}ms');
    // The label pass split: full placement passes (and how many frames ran
    // one), replayed frames, the per-frame candidate sort, and paragraph
    // shaping on cache misses. Whatever `labels` holds beyond these is
    // drawing the placed symbols.
    if (labelSplit != null) {
      debugPrint('BENCH[$_label]   LABELS-SPLIT '
          'place=${ms(labelSplit.place)}ms/${labelSplit.placing}passes '
          'replay=${ms(labelSplit.replay)}ms sort=${ms(labelSplit.sort)}ms '
          'shape=${ms(labelSplit.shape)}ms sweep=${ms(labelSplit.sweep)}ms '
          'draw=${ms(labelSplit.draw)}ms');
    }
    // Which style layers the rasterize time went to, worst first — the
    // level below WORK's phase split, naming the actual culprit.
    if (layerUs != null && layerUs.isNotEmpty) {
      final top = layerUs.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      debugPrint('BENCH[$_label]   LAYERS '
          '${top.take(8).map((e) => '${e.key}=${ms(e.value)}').join(' ')}');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: FutureBuilder<vt.Style>(
          future: _style,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(child: Text('style failed: ${snapshot.error}'));
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final style = snapshot.data!;
            return Stack(children: [
              FlutterMap(
                mapController: _controller,
                options: MapOptions(
                  initialCenter: const LatLng(_lat, _lon),
                  initialZoom: _lo,
                  // SafeNow clamps the camera and paints the light style's
                  // background; the defaults here are flutter_map's own.
                  minZoom: _safenow ? 2 : null,
                  maxZoom: _safenow ? 21 : null,
                  backgroundColor: _safenow
                      ? const Color(0xfff9f9fb)
                      : const Color(0xFFE0E0E0),
                  // Gestures would fight the driver — except in manual mode,
                  // where the fingers *are* the driver. The SafeNow setup
                  // uses the app's exact gesture set (no rotation).
                  interactionOptions: const InteractionOptions(
                      flags: _mode != 'manual'
                          ? InteractiveFlag.none
                          : _safenow
                              ? InteractiveFlag.pinchZoom |
                                  InteractiveFlag.drag |
                                  InteractiveFlag.doubleTapZoom |
                                  InteractiveFlag.pinchMove
                              : InteractiveFlag.all),
                  onMapReady: () {
                    if (!_mapReady.isCompleted) _mapReady.complete();
                  },
                ),
                children: [
                  vt.VectorTileLayer(
                    theme: style.theme,
                    tileProviders: style.providers,
                    // SafeNow's MapBaseLayer does not pass rasterSources;
                    // the non-safenow arms restate the package defaults the
                    // app leaves untouched.
                    rasterSources: _safenow ? const {} : style.rasterSources,
                    sprites: style.sprites,
                    showLabels: _showLabels,
                    memoryCacheMaxBytes: (_safenow ? 16 : 24) * 1024 * 1024,
                    diskCacheMaximumSizeInBytes:
                        (_safenow ? 150 : 50) * 1024 * 1024,
                    rasterCacheMaxBytes: _cacheMiB < 0
                        ? vt.VectorTileLayer.autoRasterCacheBytes
                        : _cacheMiB * 1024 * 1024,
                  ),
                ],
              ),
              Positioned(
                left: 8,
                bottom: 8,
                child: ColoredBox(
                  color: Colors.black54,
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: ValueListenableBuilder<double?>(
                      valueListenable: _liveZoom,
                      builder: (context, zoom, _) => Text(
                          zoom == null
                              ? '$_label · $_status'
                              : '$_label · z${zoom.toStringAsFixed(2)} · '
                                  '$_status',
                          style: const TextStyle(color: Colors.white)),
                    ),
                  ),
                ),
              ),
            ]);
          },
        ),
      );
}

/// One label drawn last frame, in zoom-20 world pixels. [matched] marks
/// it as continued by the current frame during matching.
class _SeenLabel {
  final Offset world;
  double opacity;
  bool ghost;
  final bool alongLine;
  bool matched = false;

  _SeenLabel(this.world, this.opacity, this.ghost, this.alongLine);
}

/// A label that stopped drawing, kept for [_blinkWindow] so a
/// reappearance at the same spot can be recognised as a blink.
class _GoneLabel {
  final Object key;
  final Offset world;
  final DateTime at;
  final bool alongLine;

  _GoneLabel(this.key, this.world, this.at, this.alongLine);
}

/// Stability violations inside one recording window, split point (`Pt`)
/// vs along-line (`Ln`) — the two label kinds fail differently and are
/// fixed by different mechanisms.
class _StabilityCounters {
  var frames = 0;
  var seen = 0;
  var popInPt = 0, popOutPt = 0, blinkPt = 0, appearPt = 0, gonePt = 0;
  var popInLn = 0, popOutLn = 0, blinkLn = 0, appearLn = 0, goneLn = 0;
}
