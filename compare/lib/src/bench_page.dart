import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart' show FlutterVersion;
import 'package:flutter_map/flutter_map.dart';

import 'arms.dart';
import 'config.dart';
import 'lab.dart';
import 'metrics.dart';
import 'platform/host.dart';
import 'scenarios.dart';

/// localStorage key holding an in-browser benchmark across its reloads.
const browserPlanKey = 'fmvt-compare.plan';

/// One measured run: one arm, every scenario twice (cold, then warm), and —
/// in the first round of a lab session — the fidelity screenshots.
///
/// With a lab server the run comes from its queue and the process exits at
/// the end, so the next run starts fresh. Without one (the web demo's
/// "Benchmark" button) the plan lives in localStorage and every arm gets a
/// fresh page load instead.
class BenchPage extends StatefulWidget {
  const BenchPage({super.key, required this.config});

  final Config config;

  @override
  State<BenchPage> createState() => _BenchPageState();
}

class _BenchPageState extends State<BenchPage> with TickerProviderStateMixin {
  final _map = MapController();
  final _boundary = GlobalKey();
  final _log = FrameLog.instance;

  Lab? _lab;
  String _status = 'calibrating';
  Widget? _layer;
  String? _runId;

  /// Lifecycle states other than `resumed` seen since the last [_mark].
  /// A pass that saw one is flagged `interrupted`: an app that is not in
  /// front may legitimately stop or slow its rendering, and the numbers
  /// then describe that, not the package.
  final _awayStates = <String>{};
  late final AppLifecycleListener _lifecycle;

  Config get _config => widget.config;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onStateChange: (state) {
      if (state != AppLifecycleState.resumed) _awayStates.add(state.name);
      unawaited(_lab?.log(_runId, 'lifecycle ${state.name}'));
    });
    if (_config.hasLab) _lab = Lab(_config.lab);
    // Let the first frame (and the page) settle before calibrating.
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_main()));
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  /// Starts a new window for [_lifecycleFields].
  void _mark() {
    _awayStates.clear();
    final now = WidgetsBinding.instance.lifecycleState;
    if (now != null && now != AppLifecycleState.resumed) {
      _awayStates.add(now.name);
    }
  }

  Map<String, Object?> _lifecycleFields() => {
        'interrupted': _awayStates.isNotEmpty,
        if (_awayStates.isNotEmpty) 'lifecycle': _awayStates.toList(),
      };

  void _say(String status) {
    if (mounted) setState(() => _status = status);
    unawaited(_lab?.log(_runId, status));
  }

  Future<void> _main() async {
    try {
      if (_lab != null) {
        await _labRun();
      } else {
        await _browserRun();
      }
    } catch (e, st) {
      _say('failed: $e');
      debugPrint('$e\n$st');
      if (_runId != null) {
        await _lab?.result({'kind': 'error', 'run': _runId, 'error': '$e'});
        await _lab?.done(_runId!);
      }
      exitApp();
    }
  }

  Future<void> _labRun() async {
    final refresh = await _log.calibrate();
    final run = await _lab!.next();
    if (run == null) {
      _say('queue empty — all runs done');
      exitApp();
      return;
    }
    _runId = run.id;
    await _measure(
      arm: Arm.parse(run.arm),
      runId: run.id,
      round: run.round,
      refreshMs: refresh,
      scenarioIds: run.scenarios,
      shots: run.round == 0,
      emit: _lab!.result,
    );
    await _lab!.done(run.id);
    _say('done');
    exitApp();
  }

  Future<void> _browserRun() async {
    final raw = readLocal(browserPlanKey);
    if (raw == null) {
      _say('No benchmark in progress. Start one from the demo.');
      return;
    }
    final plan = jsonDecode(raw) as Map<String, dynamic>;
    final steps = (plan['plan'] as List).cast<String>();
    final index = plan['index'] as int;
    final scenarioIds = (plan['scenarios'] as List).cast<String>();
    final results = (plan['results'] as List).cast<Object?>();
    final refresh = await _log.calibrate();
    final step = steps[index];
    _runId = 'browser-$index-$step';
    if (step == 'warmup') {
      await _warmUp(scenarioIds);
    } else {
      await _measure(
        arm: Arm.parse(step),
        runId: _runId!,
        round: 0,
        refreshMs: refresh,
        scenarioIds: scenarioIds,
        shots: false,
        emit: (json) async => results.add(json),
      );
    }
    plan
      ..['index'] = index + 1
      ..['results'] = results;
    writeLocal(browserPlanKey, jsonEncode(plan));
    final more = index + 1 < steps.length;
    navigate(Uri.base.replace(queryParameters: {
      'mode': more ? 'bench' : 'results',
      if (more) 'step': '${index + 1}',
    }).toString());
  }

  /// Fills the browser's HTTP cache along every path before the first
  /// measured arm, so no arm pays the network on behalf of the others.
  ///
  /// Twice, because the packages load different tiles for the same camera:
  /// this package's default loads data tiles one zoom below flutter_map's
  /// (`TileOffset.maplibre`), `vector_map_tiles` at flutter_map's zoom,
  /// which `TileOffset.none` reproduces.
  Future<void> _warmUp(List<String> scenarioIds) async {
    LoadedArm? previous;
    for (final arm in [Arm.fmvt, Arm.fmvtNone]) {
      _say('warming the HTTP cache: ${arm.label}');
      final loaded = await loadArm(arm, styleUrl: styleUrlFor(_config.style));
      // Where the measured arms open.
      _jump(startPose);
      // A key per arm: a fresh layer, not the previous one reconfigured.
      setState(() => _layer =
          KeyedSubtree(key: ValueKey(arm), child: loaded.buildLayer()));
      await _settle(sinceUs: _log.nowUs);
      previous?.dispose();
      previous = loaded;
      for (final id in scenarioIds) {
        final s = scenarioById(id);
        _jump(s.start);
        await _settle(sinceUs: _log.nowUs);
        await _animate(s, speed: 2);
        await _settle(sinceUs: _log.nowUs);
      }
    }
  }

  Future<void> _measure({
    required Arm arm,
    required String runId,
    required int round,
    required double refreshMs,
    required List<String>? scenarioIds,
    required bool shots,
    required Future<void> Function(Map<String, Object?>) emit,
  }) async {
    _say('loading ${arm.label}');
    final view = View.of(context);
    final cacheDir = await freshCacheDir(runId);
    await resetBrowserStorage();
    final loaded = await loadArm(
      arm,
      styleUrl: styleUrlFor(_config.style, lab: _config.lab, runId: runId),
      cacheDir: cacheDir,
    );
    final base = <String, Object?>{
      'run': runId,
      'arm': arm.id,
      'package': arm.package,
      'variant': arm.variant,
      'version': versionOf(arm),
      'round': round,
      'platform': platformName,
      'device': _config.device,
      'agent': kIsWeb ? userAgent : null,
      'flutter': FlutterVersion.version,
      'commit': const String.fromEnvironment('GIT_SHA'),
      'style': _config.style,
      'dpr': view.devicePixelRatio,
      'viewport': {
        'w': (view.physicalSize.width / view.devicePixelRatio).round(),
        'h': (view.physicalSize.height / view.devicePixelRatio).round(),
      },
      'refreshMs': (refreshMs * 100).round() / 100,
    };

    // Opening: from the layer's first frame until every tile in view has
    // loaded and nothing repaints any more.
    final rss = RssSampler();
    final mounted = _log.nowUs;
    _mark();
    setState(() => _layer = loaded.buildLayer());
    final open = await _settle(sinceUs: mounted);
    await emit({
      ...base,
      'kind': 'open',
      'settleMs': open,
      'rssMaxMb': rss.stop(),
      ..._lifecycleFields(),
      ...await _net(runId, null),
    });

    // vector_map_tiles scans its disk cache 3 s after mounting; keep that
    // out of every measured window.
    final sinceMount = _log.nowUs - mounted;
    if (sinceMount < 3500 * 1000) {
      await Future<void>.delayed(
          Duration(microseconds: 3500 * 1000 - sinceMount));
    }

    for (final s in [
      for (final id in scenarioIds ?? scenarios.map((s) => s.id))
        scenarioById(id),
    ]) {
      for (final pass in ['cold', 'warm']) {
        _say('${s.id} · $pass');
        _jump(s.start);
        await _settle(sinceUs: _log.nowUs);
        final net0 = await _netRaw(runId);
        final sampler = RssSampler();
        _mark();
        _log.start();
        await _animate(s);
        final motionEnd = _log.lastFrameUs;
        final stats = await _log.stop(refreshMs: refreshMs);
        final settle = await _settle(sinceUs: motionEnd);
        await emit({
          ...base,
          'kind': 'pass',
          'scenario': s.id,
          'pass': pass,
          ...stats.toJson(),
          'settleMs': settle,
          'rssMaxMb': sampler.stop(),
          ..._lifecycleFields(),
          ...await _net(runId, net0),
        });
      }
    }

    // The whole run's traffic, from the style request to the end of the
    // last pass: what `summarize.dart` reports per run. A pass row counts
    // only its own motion and settle, not the jump to its start, and the
    // screenshots below would add round 0's extra cameras.
    if (_lab != null) {
      await emit({...base, 'kind': 'net', ...await _net(runId, null)});
    }

    if (shots && _lab != null) {
      for (final MapEntry(key: name, value: pose) in shotPoses.entries) {
        _say('shot $name');
        _jump(pose);
        await _settle(sinceUs: _log.nowUs);
        // The last fade must have finished, not just the last frame.
        await Future<void>.delayed(const Duration(milliseconds: 600));
        await _lab!.shot('$platformName-${arm.id}-$name', await _capture());
      }
    }

    loaded.dispose();
    await deleteCacheDir(cacheDir);
  }

  Future<NetSnapshot?> _netRaw(String runId) async => _lab?.net(runId);

  Future<Map<String, Object?>> _net(String runId, NetSnapshot? since) async {
    final now = await _netRaw(runId);
    if (now == null) return const {};
    return {
      'requests': now.requests - (since?.requests ?? 0),
      'bytes': now.bytes - (since?.bytes ?? 0),
    };
  }

  void _jump(Pose pose) =>
      _map.moveAndRotate(pose.center, pose.zoom, pose.rotation);

  /// Drives [s] by elapsed time, one camera update per frame.
  Future<void> _animate(Scenario s, {double speed = 1}) {
    final done = Completer<void>();
    final duration = s.duration * (1 / speed);
    late final Ticker ticker;
    ticker = createTicker((elapsed) {
      final t = math.min(1.0, elapsed.inMicroseconds / duration.inMicroseconds);
      final pose = s.at(t);
      _map.moveAndRotate(pose.center, pose.zoom, pose.rotation);
      if (t >= 1) {
        ticker.dispose();
        done.complete();
      }
    })
      ..start();
    return done.future;
  }

  /// Waits until nothing has repainted for 4 s and — with a lab — no tile
  /// request is in flight, and returns how long after [sinceUs] the last
  /// frame came: the time until the screen stopped changing. -1 on timeout.
  ///
  /// The quiet window must outlast the longest stretch a package works
  /// without producing a frame. `vector_map_tiles` renders, rasterizes and
  /// PNG-encodes tiles between frames: on a Nothing Phone (1) it went
  /// 1.75 s without a frame while filling a fresh z14 screen, so the 1.5 s
  /// used before caught it mid-render: screenshots with missing tiles, and
  /// cold passes that began with its previous view still rendering.
  Future<int> _settle({required int sinceUs}) async {
    const quietUs = 4000 * 1000;
    final deadline = _log.nowUs + 25 * 1000 * 1000;
    while (true) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      var networkIdle = true;
      if (_lab != null && _runId != null) {
        final net = await _lab!.net(_runId!);
        networkIdle = net.inflight == 0 && net.idleMs >= quietUs ~/ 1000;
      }
      if (_log.nowUs - _log.lastFrameUs >= quietUs && networkIdle) {
        return math.max(0, _log.lastFrameUs - sinceUs) ~/ 1000;
      }
      if (_log.nowUs > deadline) return -1;
    }
  }

  Future<Uint8List> _capture() async {
    final boundary =
        _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image =
        await boundary.toImage(pixelRatio: View.of(context).devicePixelRatio);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data!.buffer.asUint8List();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          RepaintBoundary(
            key: _boundary,
            child: FlutterMap(
              mapController: _map,
              options: MapOptions(
                initialCenter: startPose.center,
                initialZoom: startPose.zoom,
                minZoom: 2,
                maxZoom: 20,
                interactionOptions:
                    const InteractionOptions(flags: InteractiveFlag.none),
              ),
              children: [if (_layer != null) _layer!],
            ),
          ),
          Positioned(
            left: 8,
            bottom: 4,
            child: Text(
              openFreeMapAttribution,
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
          Positioned(
            left: 8,
            top: MediaQuery.paddingOf(context).top + 8,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Text(
                  _status,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
