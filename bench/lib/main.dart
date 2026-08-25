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

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_vector_tiles/flutter_map_vector_tiles.dart' as vt;
// Deliberately internal: the bench is a development tool, not a consumer of
// the public API, and these debug counters are how a phase distinguishes
// "served from cache" from "re-rendered the whole screen". See AGENTS.md.
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
const _mode = String.fromEnvironment('BENCH_MODE', defaultValue: 'bench');

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
  static const _phases = <({int ms, bool labels, int cacheMiB})>[
    (ms: 150, labels: true, cacheMiB: -1),
    (ms: 150, labels: true, cacheMiB: 64),
    (ms: 150, labels: false, cacheMiB: -1),
    (ms: 400, labels: true, cacheMiB: -1),
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

  var _showLabels = true;
  var _cacheMiB = -1;
  var _status = 'loading style…';

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
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    _lifecycle?.dispose();
    _zoom.dispose();
    _style.then((style) => style.dispose()).ignore();
    super.dispose();
  }

  void _onTimings(List<FrameTiming> timings) {
    _allFrames += timings.length;
    if (!_recording) return;
    for (final timing in timings) {
      _build.add(timing.buildDuration.inMicroseconds);
      _raster.add(timing.rasterDuration.inMicroseconds);
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

    for (final phase in _phases) {
      await _runPhase(phase);
    }
    debugPrint('BENCH[$_label] ===== END =====');
    _say('all phases done');
  }

  Future<void> _runPhase(({int ms, bool labels, int cacheMiB}) phase) async {
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

    _say('${phase.ms}ms · labels=${phase.labels} · cache=$cache (warming)');
    _zoom.duration = const Duration(milliseconds: 1200);
    for (var i = 0; i < 2; i++) {
      await _zoom.forward(from: 0);
      await Future<void>.delayed(const Duration(seconds: 3));
      await _zoom.reverse(from: 1);
      await Future<void>.delayed(const Duration(seconds: 3));
    }

    _say('${phase.ms}ms · labels=${phase.labels} · cache=$cache (measuring)');
    _build = <int>[];
    _raster = <int>[];
    _allFrames = 0;
    _interrupted = false;
    final layouts0 = SymbolLayouter.debugLayoutCount;
    final rasters0 = TileRasterizer.debugRasterizeCount;
    _zoom.duration = Duration(milliseconds: phase.ms);
    _zoom.value = 0;
    _recordStart = DateTime.now();
    _recording = true;
    unawaited(_zoom.repeat(reverse: true));
    await Future<void>.delayed(const Duration(seconds: _measureSeconds));
    _recording = false;
    _zoom.stop();

    _report('${phase.ms}ms labels=${phase.labels} cache=$cache',
        layouts: SymbolLayouter.debugLayoutCount - layouts0,
        rasters: TileRasterizer.debugRasterizeCount - rasters0);
    await Future<void>.delayed(const Duration(seconds: 3));
  }

  void _say(String message) {
    debugPrint('BENCH[$_label] $message');
    if (mounted) setState(() => _status = message);
  }

  void _report(String phase, {required int layouts, required int rasters}) {
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
                  // Gestures would fight the driver.
                  interactionOptions: const InteractionOptions(flags: 0),
                  onMapReady: () {
                    if (!_mapReady.isCompleted) _mapReady.complete();
                  },
                ),
                children: [
                  vt.VectorTileLayer(
                    theme: style.theme,
                    tileProviders: style.providers,
                    rasterSources: style.rasterSources,
                    sprites: style.sprites,
                    showLabels: _showLabels,
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
                    child: Text('$_label · $_status',
                        style: const TextStyle(color: Colors.white)),
                  ),
                ),
              ),
            ]);
          },
        ),
      );
}
