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
///
/// This file is the app and the drivers of each mode; `env.dart` holds the
/// knobs, `frame_recorder.dart` a recording window and its report,
/// `extrusion_stats.dart` the 3D pass's lines in it, `opening.dart` the
/// first screen's, `label_stability.dart` the stability counters,
/// `query_mode.dart` the `query` mode, and `report.dart` the line formats.
library;

// This reaches into the parent package's `src/` for its
// `@visibleForTesting` debug counters and probes, and it is neither that
// library nor a test. Both lints are right in general and wrong here: a
// bench that cannot tell "served from cache" from "re-rendered the whole
// screen" is not worth running, and widening the public API for a
// development tool would be the worse trade.
// ignore_for_file: implementation_imports
// ignore_for_file: invalid_use_of_visible_for_testing_member

import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_vector_tiles/flutter_map_vector_tiles.dart' as vt;
import 'package:flutter_map_vector_tiles/src/render/extrusion_painter.dart'
    show ExtrusionPainter;
import 'package:flutter_map_vector_tiles/src/render/label_painter.dart'
    show DrawnLabelRecord, LabelPainter;
import 'package:flutter_map_vector_tiles/src/render/symbol_layouter.dart'
    show SymbolLayouter;
import 'package:flutter_map_vector_tiles/src/render/tile_rasterizer.dart'
    show TileRasterizer;

import 'env.dart';
import 'frame_recorder.dart';
import 'label_stability.dart';
import 'opening.dart';
import 'query_mode.dart';
import 'report.dart';
import 'worker_stats.dart';

void main() {
  ExtrusionPainter.debugForceOpaque = Env.extrude == ExtrudeArm.opaque;
  LabelPainter.debugHaloBlur = Env.haloBlur;
  runApp(const BenchApp());
}

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

/// One measured arm of the matrix.
///
/// [cacheMiB] of `-1` means [vt.VectorTileLayer.autoRasterCacheBytes] — the
/// shipped default. [cold] arms measure the *first* sweeps after the caches
/// are cleared — network/decode/rasterize/shaping all land inside the
/// recording window. That is the crossing a user feels first, and the
/// warmed arms deliberately exclude it.
typedef Phase = ({int ms, bool labels, int cacheMiB, bool cold});

class _BenchPageState extends State<BenchPage>
    with SingleTickerProviderStateMixin {
  /// The `bench` matrix. The labels-off arm is the control: if the label
  /// pipeline is what costs, turning it off at the same speed has to
  /// flatten the profile, and if it does not, the cost is somewhere else
  /// entirely.
  static const _phases = <Phase>[
    (ms: 1200, labels: true, cacheMiB: -1, cold: true),
    (ms: 150, labels: true, cacheMiB: -1, cold: false),
    (ms: 150, labels: true, cacheMiB: 64, cold: false),
    (ms: 150, labels: false, cacheMiB: -1, cold: false),
    (ms: 400, labels: true, cacheMiB: -1, cold: false),
  ];

  /// Long enough for ~1000 frames at 120 Hz — percentiles over a few hundred
  /// frames are noise.
  static const _measureSeconds = 8;

  /// Reporting cadence for `manual` mode.
  static const _manualWindowSeconds = 5;

  /// One direction of a `stability` sweep. Slow on purpose: ~0.16 zoom/s
  /// gives every publish, placement pass and fade time to play out at each
  /// crossing, the way a browsing finger does.
  static const _stabilitySweepSeconds = 16;

  late final Future<vt.Style> _style;
  late final AnimationController _zoom;
  final _controller = MapController();
  final _mapReady = Completer<void>();
  AppLifecycleListener? _lifecycle;

  final _recorder = FrameRecorder();
  final _opening = OpeningRecorder();
  final _stability = LabelStabilityTracker();

  // The package's work counters at the last frame's end, and the
  // placement worker's events, diffed by [_onFrameEnd].
  var _frameWork = WorkCounters.zero();
  var _frameWorkerEvents = 0;
  var _frameNo = 0;

  // The live zoom for the overlay. The notifier deliberately bypasses
  // setState — rebuilding the whole page on every frame of a pinch would put
  // the harness's own cost into the numbers it reports.
  final _liveZoom = ValueNotifier<double?>(null);

  var _showLabels = true;
  var _cacheMiB = -1;
  var _status = 'loading style…';

  // `query` mode: the controller under test, and the style with a
  // selection layer that reads feature state (no hosted style does).
  final _features = vt.VectorTileLayerController();
  vt.Theme? _queryTheme;

  @override
  void initState() {
    super.initState();
    _style = const vt.StyleReader(uri: Env.styleUrl, apiKey: Env.apiKey).read();
    // A crossing is a *sweep*: the camera passes through the threshold over
    // many frames, which is what staggers the tile publishes and the label
    // fades. A `move()` jump produces one frame per crossing and measures
    // nothing — an early version of this harness did exactly that and
    // reported a perfectly smooth map.
    _zoom = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 400))
      ..addListener(() => _controller.move(
          Env.centre, Env.lo + (Env.hi - Env.lo) * _zoom.value));
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    SchedulerBinding.instance.addPostFrameCallback(_onFrameEnd);
    switch (Env.mode) {
      case BenchMode.bench:
        // Only the count: the stability matcher is not needed here.
        LabelPainter.debugDrawnProbe = _recorder.countDrawn;
      case BenchMode.stability || BenchMode.manual:
        LabelPainter.debugDrawnProbe = _onLabelsDrawn;
        LabelPainter.debugRejectProbe = (key, reason, replay) {
          if (!_recorder.recording) return;
          _stability.onReject(key, reason, replay, zoom: _zoomNow());
        };
      case BenchMode.idle || BenchMode.query:
    }
    // A backgrounding mid-run parks the render pump (the layer stops
    // rasterizing from `inactive` onwards), so the numbers would be fiction.
    // Better to flag the run than to average it in.
    _lifecycle = AppLifecycleListener(onStateChange: (state) {
      if (_recorder.recording && state != AppLifecycleState.resumed) {
        _recorder.interrupted = true;
      }
    });
    unawaited(_run());
  }

  @override
  void dispose() {
    LabelPainter.debugDrawnProbe = null;
    LabelPainter.debugRejectProbe = null;
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    _lifecycle?.dispose();
    _liveZoom.dispose();
    _zoom.dispose();
    _style.then((style) => style.dispose()).ignore();
    super.dispose();
  }

  double? _zoomNow() => _mapReady.isCompleted ? _controller.camera.zoom : null;

  void _onTimings(List<FrameTiming> timings) {
    _opening.addTimings(timings);
    // The zoom is sampled rather than derived from the driver — in manual
    // mode the camera is in the user's hands.
    final zoom = _recorder.recording ? _zoomNow() : null;
    if (zoom != null) _liveZoom.value = zoom;
    _recorder.addTimings(timings, zoom);
  }

  /// Per-frame delta of the package's work counters. Runs as a
  /// self-re-registering post-frame callback, so each delta is exactly one
  /// frame's worth of publish work — the alignment a batched timings
  /// callback cannot give. A frame whose rasterize+layout+label time alone
  /// approaches the 120 Hz budget is logged with its split, which is the
  /// attribution the JANK lines lack.
  void _onFrameEnd(Duration _) {
    if (!mounted) return;
    SchedulerBinding.instance.addPostFrameCallback(_onFrameEnd);
    _frameNo++;
    final now = WorkCounters.now();
    final work = now.since(_frameWork);
    _frameWork = now;
    // A placing frame runs a pass in-frame or, with the placement worker,
    // sends one or adopts one's answer.
    final events = placementWorkerEvents() - _frameWorkerEvents;
    _frameWorkerEvents += events;
    _recorder.endFrame(PlatformDispatcher.instance.frameData.frameNumber,
        placing: work.placing + events > 0);
    _opening.endFrame(labelUs: work.labelUs, shapeUs: work.shapeUs);
    if (!_recorder.recording ||
        work.rasterUs + work.layoutUs + work.labelUs <= 6000) {
      return;
    }
    benchLog('WORK '
        'z=${_zoomNow()?.toStringAsFixed(2) ?? '?'} tiles=${work.rasters} '
        'raster=${ms(work.rasterUs)}ms layout=${ms(work.layoutUs)}ms '
        'labels=${ms(work.labelUs)}ms place=${ms(work.placeUs)}ms '
        'shape=${ms(work.shapeUs)}ms '
        'sweep=${ms(work.sweepUs)}ms draw=${ms(work.drawUs)}ms');
  }

  /// The label pass's drawn labels, for the frame's count and the
  /// stability matcher.
  void _onLabelsDrawn(double styleZoom, List<DrawnLabelRecord> drawn) {
    _recorder.countDrawn(styleZoom, drawn);
    _stability.onFrame(drawn,
        camera: _mapReady.isCompleted ? _controller.camera : null,
        recording: _recorder.recording);
  }

  /// Forces frames until nothing has been rasterized or laid out for
  /// [quiet], and returns when, and on which frame, the last of it
  /// landed — a publish is on screen at the end of the frame it lands in.
  Future<Quiet> _quiet(
      {Duration quiet = const Duration(milliseconds: 400)}) async {
    var last =
        (TileRasterizer.debugRasterizeCount, SymbolLayouter.debugLayoutCount);
    var at = DateTime.now();
    var frame = _frameNo;
    while (DateTime.now().difference(at) < quiet) {
      await SchedulerBinding.instance.endOfFrame;
      final now =
          (TileRasterizer.debugRasterizeCount, SymbolLayouter.debugLayoutCount);
      if (now != last) {
        last = now;
        at = DateTime.now();
        frame = _frameNo;
      }
    }
    return (at: at, frame: frame);
  }

  void _say(String message) {
    benchLog(message);
    if (mounted) setState(() => _status = message);
  }

  Future<void> _run() async {
    final style = await _style;
    // The map lives behind a FutureBuilder, so the style future completing is
    // not the same as the map being laid out — the controller throws until it
    // has rendered once.
    await _mapReady.future;
    await _opening.report();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    switch (Env.mode) {
      case BenchMode.idle:
        _runIdle(style);
      case BenchMode.manual:
        await _runManual();
      case BenchMode.stability:
        await _runStability();
      case BenchMode.query:
        await _runQuery(style);
      case BenchMode.bench:
        for (final phase in _phases) {
          await _runPhase(phase);
        }
        benchLog('===== END =====');
        _say('all phases done');
    }
  }

  /// Parks the map for a screenshot of what the style draws there.
  void _runIdle(vt.Style style) {
    _controller.move(Env.centre, Env.idleZoom);
    final symbols = style.theme.layers
        .where((l) => l.runtimeType.toString().contains('Symbol'))
        .length;
    _say('idle z${Env.idleZoom} · ${style.theme.layers.length} layers, '
        '$symbols symbol · sprites=${style.sprites != null}');
  }

  Future<void> _runPhase(Phase phase) async {
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
    final work0 = WorkCounters.now();
    final layers0 = layerTimesNow();
    _zoom.duration = Duration(milliseconds: phase.ms);
    _zoom.value = 0;
    _recorder.extrusion.start();
    _recorder.start();
    unawaited(_zoom.repeat(reverse: true));
    await Future<void>.delayed(const Duration(seconds: _measureSeconds));
    _recorder.stop();
    _zoom.stop();
    _recorder.report(
        '${phase.ms}ms labels=${phase.labels} cache=$cache'
        '${phase.cold ? ' COLD' : ''}',
        WorkCounters.now().since(work0),
        layerUs: layerTimesSince(layers0),
        labelSplit: true);
    await Future<void>.delayed(const Duration(seconds: 3));
  }

  /// The camera belongs to the user's fingers; this loop only watches.
  /// Records forever in fixed windows, reporting each window that produced
  /// frames — a window with none means an untouched screen, and printing it
  /// would drown the interesting ones. Cache-work counters are deltas per
  /// window, so `layouts=0 rasterizes=0` keeps its meaning: that window was
  /// served entirely from cache.
  Future<void> _runManual() async {
    _say('manual · zoom by hand · window=${_manualWindowSeconds}s');
    var work0 = WorkCounters.now();
    var layers0 = layerTimesNow();
    while (mounted) {
      _recorder.start();
      await Future<void>.delayed(const Duration(seconds: _manualWindowSeconds));
      _recorder.stop();
      final work = WorkCounters.now();
      if (_recorder.hasFrames) {
        _recorder.report('manual ${_recorder.zoomBand}', work.since(work0),
            layerUs: layerTimesSince(layers0), labelSplit: true);
        _stability.report('manual');
      }
      _stability.reset();
      work0 = work;
      layers0 = layerTimesNow();
    }
  }

  /// Four slow monotonic sweeps: cold in, back out, warm in, back out.
  /// Each reports its STABILITY counters plus the usual frame stats.
  Future<void> _runStability() async {
    _say('stability · monotonic z${Env.lo}↔${Env.hi} · '
        '${_stabilitySweepSeconds}s per direction');
    vt.VectorTileLayer.clearMemoryCache();
    _controller.move(Env.centre, Env.lo);
    await Future<void>.delayed(const Duration(seconds: 4));
    _zoom.duration = const Duration(seconds: _stabilitySweepSeconds);
    for (final pass in ['cold', 'warm']) {
      for (final direction in ['in', 'out']) {
        _say('stability $pass-$direction…');
        _stability.reset();
        final work0 = WorkCounters.now();
        _recorder.start();
        if (direction == 'in') {
          await _zoom.forward(from: 0);
        } else {
          await _zoom.reverse(from: 1);
        }
        // Let the tail-end fades land before closing the books.
        await Future<void>.delayed(const Duration(seconds: 2));
        _recorder.stop();
        _stability.report('$pass-$direction z=${Env.lo}..${Env.hi}');
        _recorder.report(
            'stability $pass-$direction', WorkCounters.now().since(work0));
      }
    }
    benchLog('===== END =====');
    _say('stability done');
  }

  Future<void> _runQuery(vt.Style style) async {
    _say('query · z${Env.idleZoom} · retainAllProperties=${Env.retainAll}');
    _controller.move(Env.centre, Env.idleZoom);
    await Future<void>.delayed(const Duration(seconds: 2));
    await _quiet(quiet: const Duration(seconds: 2));
    if (!mounted) return;
    await QueryRun(
      map: _controller,
      features: _features,
      recorder: _recorder,
      size: MediaQuery.sizeOf(context),
      quiet: _quiet,
      frame: () => _frameNo,
    ).run(style);
    benchLog('===== END =====');
    _say('query done');
  }

  /// Gestures would fight the driver — except in manual mode, where the
  /// fingers *are* the driver. The SafeNow setup uses the app's exact
  /// gesture set (no rotation).
  static int get _gestures => Env.mode != BenchMode.manual
      ? InteractiveFlag.none
      : Env.safenow
          ? InteractiveFlag.pinchZoom |
              InteractiveFlag.drag |
              InteractiveFlag.doubleTapZoom |
              InteractiveFlag.pinchMove
          : InteractiveFlag.all;

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
            _opening.start();
            return Stack(children: [
              _map(snapshot.data!),
              Positioned(left: 8, bottom: 8, child: _overlay()),
            ]);
          },
        ),
      );

  Widget _map(vt.Style style) => FlutterMap(
        mapController: _controller,
        options: MapOptions(
          initialCenter: Env.centre,
          initialZoom: Env.lo,
          // SafeNow clamps the camera and paints the light style's
          // background; the defaults here are flutter_map's own.
          minZoom: Env.safenow ? 2 : null,
          maxZoom: Env.safenow ? 21 : null,
          backgroundColor:
              Env.safenow ? const Color(0xfff9f9fb) : const Color(0xFFE0E0E0),
          interactionOptions: InteractionOptions(flags: _gestures),
          onMapReady: () {
            if (!_mapReady.isCompleted) _mapReady.complete();
          },
        ),
        children: [
          vt.VectorTileLayer(
            theme: Env.mode == BenchMode.query
                ? (_queryTheme ??= withSelection(style.theme))
                : style.theme,
            controller: Env.mode == BenchMode.query ? _features : null,
            retainAllProperties: Env.retainAll,
            tileProviders: style.providers,
            // SafeNow's MapBaseLayer does not pass rasterSources; the
            // non-safenow arms restate the package defaults the app leaves
            // untouched.
            rasterSources: Env.safenow ? const {} : style.rasterSources,
            sprites: style.sprites,
            glyphs: style.glyphs,
            showLabels: _showLabels,
            extrusionMode: Env.extrude == ExtrudeArm.flat
                ? vt.ExtrusionMode.flat
                : vt.ExtrusionMode.perspective,
            memoryCacheMaxBytes: (Env.safenow ? 16 : 24) * 1024 * 1024,
            diskCacheMaximumSizeInBytes: (Env.safenow ? 150 : 50) * 1024 * 1024,
            rasterCacheMaxBytes: _cacheMiB < 0
                ? vt.VectorTileLayer.autoRasterCacheBytes
                : _cacheMiB * 1024 * 1024,
          ),
        ],
      );

  /// The run's label, the live zoom and the driver's status.
  Widget _overlay() => ColoredBox(
        color: Colors.black54,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: ValueListenableBuilder<double?>(
            valueListenable: _liveZoom,
            builder: (context, zoom, _) => Text(
                zoom == null
                    ? '${Env.label} · $_status'
                    : '${Env.label} · z${zoom.toStringAsFixed(2)} · $_status',
                style: const TextStyle(color: Colors.white)),
          ),
        ),
      );
}
