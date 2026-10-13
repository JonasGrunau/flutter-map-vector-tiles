import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_map/flutter_map.dart';

import 'arms.dart';
import 'bench_page.dart' show browserPlanKey;
import 'config.dart';
import 'metrics.dart';
import 'platform/host.dart';
import 'scenarios.dart';

const _styles = {
  'liberty': 'Liberty',
  'bright': 'Bright',
  'positron': 'Positron',
};

/// The interactive demo: one package per page load, a live frame readout,
/// the benchmark's scripted camera paths on a button, and a side-by-side
/// view for comparing what each package draws.
class DemoPage extends StatefulWidget {
  const DemoPage({super.key, required this.config});

  final Config config;

  @override
  State<DemoPage> createState() => _DemoPageState();
}

class _DemoPageState extends State<DemoPage> with TickerProviderStateMixin {
  final _left = MapController();
  final _right = MapController();
  double _refreshMs = 16.667;
  List<LoadedArm>? _loaded;
  Object? _error;
  Ticker? _playing;
  bool _panelOpen = true;

  bool get _sideBySide => widget.config.arm == 'side';

  Arm get _rightArm =>
      Arm.tryParse(Uri.base.queryParameters['right'] ?? '') ?? Arm.vmtRaster;

  List<Arm> get _arms => _sideBySide
      ? [Arm.fmvt, _rightArm]
      : [Arm.tryParse(widget.config.arm) ?? Arm.fmvt];

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    _refreshMs = await FrameLog.instance.calibrate();
    try {
      final style = styleUrlFor(widget.config.style);
      final loaded = [for (final a in _arms) await loadArm(a, styleUrl: style)];
      if (mounted) setState(() => _loaded = loaded);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  void dispose() {
    _playing?.dispose();
    for (final l in _loaded ?? const <LoadedArm>[]) {
      l.dispose();
    }
    super.dispose();
  }

  /// Every switch is a page load, so each package starts in a fresh
  /// process with nothing cached by the other.
  void _go(Map<String, String> params) {
    navigate(Uri.base.replace(queryParameters: {
      ...Uri.base.queryParameters,
      ...params,
    }).toString());
  }

  void _play(Scenario s) {
    _playing?.dispose();
    final start = s.start;
    _left.moveAndRotate(start.center, start.zoom, start.rotation);
    _playing = createTicker((elapsed) {
      final t =
          math.min(1.0, elapsed.inMicroseconds / s.duration.inMicroseconds);
      final p = s.at(t);
      _left.moveAndRotate(p.center, p.zoom, p.rotation);
      if (_sideBySide) _right.moveAndRotate(p.center, p.zoom, p.rotation);
      if (t >= 1) {
        _playing?.dispose();
        _playing = null;
      }
    })
      ..start();
  }

  void _startBenchmark({required bool quick}) {
    writeLocal(
      browserPlanKey,
      jsonEncode({
        'plan': [
          'warmup',
          Arm.fmvt.id,
          Arm.fmvtRaster.id,
          Arm.vmtRaster.id,
          Arm.vmtVector.id,
        ],
        'index': 0,
        'scenarios': quick ? ['zoom', 'rotate'] : scenarios.map((s) => s.id),
        'results': <Object?>[],
        'started': DateTime.now().toIso8601String(),
      }),
    );
    _go({'mode': 'bench', 'step': '0'});
  }

  Widget _map(LoadedArm loaded, MapController controller,
      {MapController? mirror}) {
    return FlutterMap(
      mapController: controller,
      options: MapOptions(
        initialCenter: startPose.center,
        initialZoom: startPose.zoom,
        minZoom: 2,
        maxZoom: 20,
        onPositionChanged: mirror == null
            ? null
            : (camera, hasGesture) {
                if (hasGesture) {
                  mirror.moveAndRotate(
                      camera.center, camera.zoom, camera.rotation);
                }
              },
      ),
      children: [loaded.buildLayer()],
    );
  }

  @override
  Widget build(BuildContext context) {
    final loaded = _loaded;
    final Widget body;
    if (_error != null) {
      body = Center(child: Text('Could not load the style: $_error'));
    } else if (loaded == null) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_sideBySide) {
      body = Row(children: [
        Expanded(
            child:
                _labelled(loaded[0], _map(loaded[0], _left, mirror: _right))),
        const VerticalDivider(width: 2, thickness: 2),
        Expanded(
            child:
                _labelled(loaded[1], _map(loaded[1], _right, mirror: _left))),
      ]);
    } else {
      body = _map(loaded[0], _left);
    }
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(child: body),
          Positioned(
            left: 8,
            bottom: 4,
            child: Text(openFreeMapAttribution,
                style: Theme.of(context).textTheme.labelSmall),
          ),
          Positioned(
            right: 8,
            bottom: 24,
            child: _Readout(refreshMs: () => _refreshMs),
          ),
          Positioned(
            left: 8,
            top: 8,
            right: 8,
            child: Align(
              alignment: Alignment.topLeft,
              child: _panel(context),
            ),
          ),
        ],
      ),
    );
  }

  Widget _labelled(LoadedArm loaded, Widget map) => Stack(children: [
        Positioned.fill(child: map),
        Positioned(
          right: 8,
          top: 8,
          child: _Chip('${loaded.arm.label} ${versionOf(loaded.arm)}'),
        ),
      ]);

  Widget _panel(BuildContext context) {
    final theme = Theme.of(context);
    final current = widget.config.arm;
    return Card(
      elevation: 3,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Expanded(
                  child: Text('flutter_map_vector_tiles vs vector_map_tiles',
                      style: theme.textTheme.titleSmall),
                ),
                IconButton(
                  tooltip: 'About this demo',
                  icon: const Icon(Icons.info_outline),
                  onPressed: () => _about(context),
                ),
                IconButton(
                  tooltip: _panelOpen ? 'Collapse' : 'Expand',
                  icon:
                      Icon(_panelOpen ? Icons.expand_less : Icons.expand_more),
                  onPressed: () => setState(() => _panelOpen = !_panelOpen),
                ),
              ]),
              if (_panelOpen) ...[
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final a in [
                    Arm.fmvt,
                    Arm.fmvtRaster,
                    Arm.vmtRaster,
                    Arm.vmtVector,
                  ])
                    ChoiceChip(
                      label: Text(a.label),
                      selected: current == a.id,
                      onSelected: (_) => _go({'arm': a.id}),
                    ),
                  ChoiceChip(
                    label: const Text('side by side'),
                    selected: _sideBySide,
                    onSelected: (_) => _go({'arm': 'side'}),
                  ),
                ]),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text('Play:', style: theme.textTheme.labelMedium),
                    for (final s in scenarios)
                      ActionChip(
                        label: Text(s.id),
                        tooltip: s.title,
                        onPressed: _loaded == null ? null : () => _play(s),
                      ),
                    DropdownButton<String>(
                      value: widget.config.style,
                      isDense: true,
                      underline: const SizedBox.shrink(),
                      items: [
                        for (final MapEntry(:key, :value) in _styles.entries)
                          DropdownMenuItem(value: key, child: Text(value)),
                      ],
                      onChanged: (s) => _go({'style': s!}),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  FilledButton.tonal(
                    onPressed: () => _startBenchmark(quick: true),
                    child: const Text('Benchmark · quick (~4 min)'),
                  ),
                  OutlinedButton(
                    onPressed: () => _startBenchmark(quick: false),
                    child: const Text('Benchmark · full (~13 min)'),
                  ),
                ]),
                if (_sideBySide)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'Visual comparison only: both maps share one UI '
                      'thread, so this view says nothing about either '
                      "package's frame rate. Right map: ",
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                if (_sideBySide)
                  Wrap(spacing: 6, children: [
                    for (final a in [
                      Arm.fmvtRaster,
                      Arm.vmtRaster,
                      Arm.vmtVector,
                      Arm.fmvtNone
                    ])
                      ChoiceChip(
                        label: Text(a.label),
                        selected: _rightArm == a,
                        onSelected: (_) => _go({'arm': 'side', 'right': a.id}),
                      ),
                  ]),
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _about(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('About this demo'),
        content: const SingleChildScrollView(
          child: Text(
            'The same OpenFreeMap style, rendered by flutter_map_vector_tiles '
            '$fmvtVersion and vector_map_tiles $vmtVersion, both at their '
            'defaults (vector_map_tiles with maximumZoom: 22, without which '
            'it goes blank past z18). "LabelMode.tile" is '
            'flutter_map_vector_tiles with its labels drawn into the tiles, '
            'the counterpart of vector_map_tiles\' default raster mode.\n\n'
            'Every package switch reloads the page, so each one runs alone '
            'and starts with nothing cached by the other.\n\n'
            'The readout counts frames the display could have shown but did '
            'not get, whatever the cause — slow builds, slow rasterization, '
            'or work scheduled between frames. UI and raster times explain a '
            'drop; the drop count is the number that matters.\n\n'
            'Play runs the benchmark\'s scripted camera paths, so you can '
            'watch each package on the identical path. The benchmark buttons '
            'run every path cold and then warm for each package in turn and '
            'show a table. Browser numbers are noisier than device runs; see '
            'the repository for those.\n\n'
            'Drag to pan, scroll or pinch to zoom, Ctrl + drag to rotate.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.65),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Text(text,
              style: const TextStyle(color: Colors.white, fontSize: 12)),
        ),
      );
}

/// Live frame readout over the last two seconds of motion.
class _Readout extends StatefulWidget {
  const _Readout({required this.refreshMs});

  final double Function() refreshMs;

  @override
  State<_Readout> createState() => _ReadoutState();
}

class _ReadoutState extends State<_Readout> {
  Timer? _timer;
  FrameStats _stats = FrameStats.empty;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      final stats = FrameLog.instance.recent(refreshMs: widget.refreshMs());
      // Only repaint when something moved: an idle map stays idle.
      if (stats.frames > 3 || _stats.frames > 3) {
        setState(() => _stats = stats);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = _stats;
    final hz = (1000 / widget.refreshMs()).round();
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: DefaultTextStyle(
          style: const TextStyle(
              color: Colors.white, fontSize: 12, fontFamily: 'monospace'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('display ${hz}Hz · last 2 s of motion'),
              Text('delivered ${s.deliveredPct.toStringAsFixed(1)}% · '
                  'dropped ${s.dropped}'),
              Text('stalls >50ms ${s.stalls50} · '
                  'worst gap ${s.gaps.max.toStringAsFixed(0)}ms'),
              Text('UI p90 ${s.build.p90.toStringAsFixed(1)}ms · '
                  'raster p90 ${s.raster.p90.toStringAsFixed(1)}ms'),
            ],
          ),
        ),
      ),
    );
  }
}
