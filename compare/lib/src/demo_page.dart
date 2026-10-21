import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_map/flutter_map.dart';

import 'arms.dart';
import 'bench_page.dart' show BenchmarkLength, startBrowserBenchmark;
import 'config.dart';
import 'metrics.dart';
import 'platform/host.dart';
import 'scenarios.dart';

const _styles = {
  'liberty': 'Liberty',
  'bright': 'Bright',
  'positron': 'Positron',
};

const repoUrl = 'https://github.com/JonasGrunau/flutter-map-vector-tiles';

/// The device results in plain words, for readers coming from the demo.
const summaryUrl = '$repoUrl/blob/main/compare/SUMMARY.md';

const _pathIcons = {
  'zoom': Icons.zoom_in,
  'pan': Icons.east,
  'rotate': Icons.rotate_right,
  'fling': Icons.swap_vert,
};

String _capitalized(String s) => s[0].toUpperCase() + s.substring(1);

/// How [arm] draws its labels, in a sentence or two.
String _strategy(Arm arm) => arm.bakesLabels
    ? 'Each label is drawn into its tile once, so moving the map costs '
        'little. Labels turn with the map and avoid each other only within '
        'a tile.'
    : arm.isVmt
        ? 'Labels, roads and buildings are drawn again on every frame.'
        : 'Labels are placed on every frame: they stay upright and avoid '
            'each other across the whole screen, at the price of work on '
            'every frame.';

/// The interactive demo: one package per page load, a live smoothness
/// meter, the benchmark's scripted camera paths on a button, and a
/// side-by-side view for comparing what each package draws.
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
  Ticker? _ticker;
  Scenario? _playing;

  /// Open on a wide screen; on a phone, and side by side, the maps come
  /// first.
  bool? _panelOpen;

  /// Set by the first camera move: until then the frames are the map
  /// loading, which the meter should not present as smoothness.
  final _moved = ValueNotifier(false);

  bool get _sideBySide => widget.config.arm == 'side';

  /// One arm, or the left and the right map's. Side by side pairs the two
  /// packages' arms with the same label strategy unless the URL says
  /// otherwise.
  List<Arm> get _arms {
    if (!_sideBySide) return [Arm.tryParse(widget.config.arm) ?? Arm.fmvt];
    final query = Uri.base.queryParameters;
    final right = Arm.tryParse(query['right'] ?? '') ?? Arm.vmtRaster;
    final left = Arm.tryParse(query['left'] ?? '') ??
        Arm.pick(vmt: false, baked: right.bakesLabels);
    return [left, right];
  }

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
    _moved.dispose();
    _ticker?.dispose();
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

  void _show({required bool vmt, required bool baked}) {
    if (_sideBySide) {
      _go({
        'arm': 'side',
        'left': Arm.pick(vmt: false, baked: baked).id,
        'right': Arm.pick(vmt: true, baked: baked).id,
      });
    } else {
      _go({'arm': Arm.pick(vmt: vmt, baked: baked).id});
    }
  }

  void _setSideBySide(bool on) {
    final baked = _arms.first.bakesLabels;
    if (on) {
      _go({
        'arm': 'side',
        'left': Arm.pick(vmt: false, baked: baked).id,
        'right': Arm.pick(vmt: true, baked: baked).id,
      });
    } else {
      _go({'arm': _arms.first.id});
    }
  }

  void _play(Scenario s) {
    _stop();
    final start = s.start;
    _left.moveAndRotate(start.center, start.zoom, start.rotation);
    if (_sideBySide) {
      _right.moveAndRotate(start.center, start.zoom, start.rotation);
    }
    setState(() => _playing = s);
    _ticker = createTicker((elapsed) {
      final t =
          math.min(1.0, elapsed.inMicroseconds / s.duration.inMicroseconds);
      final p = s.at(t);
      _left.moveAndRotate(p.center, p.zoom, p.rotation);
      if (_sideBySide) _right.moveAndRotate(p.center, p.zoom, p.rotation);
      if (t >= 1) _stop();
    })
      ..start();
  }

  void _stop() {
    _ticker?.dispose();
    _ticker = null;
    if (_playing != null && mounted) setState(() => _playing = null);
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
        onPositionChanged: (camera, hasGesture) {
          _moved.value = true;
          if (mirror != null && hasGesture) {
            mirror.moveAndRotate(camera.center, camera.zoom, camera.rotation);
          }
        },
      ),
      children: [loaded.buildLayer()],
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final narrow = size.width < 640;
    // Side by side, an open panel would hide most of the left map.
    final open = _panelOpen ??= !narrow && !_sideBySide;
    final loaded = _loaded;
    final Widget body;
    if (_error != null) {
      body = Center(child: Text('Could not load the style: $_error'));
    } else if (loaded == null) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_sideBySide) {
      final first =
          _labelled(loaded[0], _map(loaded[0], _left, mirror: _right));
      final second =
          _labelled(loaded[1], _map(loaded[1], _right, mirror: _left));
      // Stacked on a phone, where two columns would be too narrow to read.
      body = narrow
          ? Column(children: [
              Expanded(child: first),
              const Divider(height: 2, thickness: 2),
              Expanded(child: second),
            ])
          : Row(children: [
              Expanded(child: first),
              const VerticalDivider(width: 2, thickness: 2),
              Expanded(child: second),
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
          if (!_sideBySide)
            Positioned(
              right: 8,
              bottom: 24,
              child: _Meter(refreshMs: () => _refreshMs, moved: _moved),
            ),
          Positioned(
            left: 8,
            top: 8,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: math.min(440, size.width - 16),
                minWidth: math.min(440, size.width - 16),
                // Clear of the meter in the corner below.
                maxHeight: size.height - (_sideBySide ? 16 : 150),
              ),
              child: _panel(context, open: open),
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
          bottom: 24,
          child: _Chip('${loaded.arm.package} · ${loaded.arm.setup}'),
        ),
      ]);

  Widget _panel(BuildContext context, {required bool open}) {
    final theme = Theme.of(context);
    final arms = _arms;
    final baked = arms.first.bakesLabels;
    final vmt = arms.first.isVmt;
    return Card(
      elevation: 4,
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // The header opens and closes the panel; only it takes the
            // tap, so its ripple stays in the header instead of filling
            // the card as it opens.
            InkWell(
              onTap: () => setState(() => _panelOpen = !open),
              child: Padding(
                padding: EdgeInsets.fromLTRB(16, 8, 8, open ? 0 : 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Expanded(
                        child: Text('Vector tiles in flutter_map',
                            style: theme.textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w600)),
                      ),
                      IconButton(
                        tooltip: 'How this demo works',
                        icon: const Icon(Icons.help_outline),
                        onPressed: () => _about(context),
                      ),
                      IconButton(
                        tooltip: open ? 'Hide controls' : 'Show controls',
                        icon:
                            Icon(open ? Icons.expand_less : Icons.expand_more),
                        onPressed: () => setState(() => _panelOpen = !open),
                      ),
                    ]),
                    if (!open)
                      Text(
                        _sideBySide
                            ? 'Side by side · labels '
                                '${baked ? 'baked into tiles' : 'drawn every frame'}'
                            : '${arms.first.package} · ${arms.first.setup}',
                        style: theme.textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
            ),
            if (open)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Two Flutter packages draw the same OpenFreeMap '
                      'style. Pick one, move the map, and watch how '
                      'smoothly it follows.',
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                    // Side by side shows both; the description names
                    // them.
                    if (!_sideBySide) ...[
                      const _Heading('Package'),
                      _Segments<bool>(
                        values: const {
                          false: 'flutter_map_vector_tiles',
                          true: 'vector_map_tiles',
                        },
                        selected: {vmt},
                        onSelected: (v) => _show(vmt: v, baked: baked),
                      ),
                    ],
                    const _Heading('Labels'),
                    _Segments<bool>(
                      values: const {
                        true: 'Baked into the tiles',
                        false: 'Drawn every frame',
                      },
                      selected: {baked},
                      onSelected: (b) => _show(vmt: vmt, baked: b),
                    ),
                    const SizedBox(height: 8),
                    Text(_description(), style: theme.textTheme.bodySmall),
                    const SizedBox(height: 8),
                    Row(children: [
                      Switch(
                        value: _sideBySide,
                        onChanged: _setSideBySide,
                        // Flush with the text above, not inset by a
                        // tap target or the track's own padding.
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        padding: EdgeInsets.zero,
                      ),
                      const SizedBox(width: 12),
                      Text('Side by side', style: theme.textTheme.bodyMedium),
                      const Spacer(),
                      DropdownButton<String>(
                        value: widget.config.style,
                        isDense: true,
                        underline: const SizedBox.shrink(),
                        items: [
                          for (final MapEntry(:key, :value) in _styles.entries)
                            DropdownMenuItem(
                                value: key, child: Text('$value style')),
                        ],
                        onChanged: (s) => _go({'style': s!}),
                      ),
                    ]),
                    const _Heading('Play a camera path'),
                    Row(children: [
                      for (final (i, s) in scenarios.indexed) ...[
                        if (i > 0) const SizedBox(width: 8),
                        Expanded(
                          child: _PathButton(
                            icon:
                                _playing == s ? Icons.stop : _pathIcons[s.id]!,
                            label: _playing == s ? 'Stop' : _capitalized(s.id),
                            tooltip: s.title,
                            active: _playing == s,
                            onPressed: _loaded == null
                                ? null
                                : _playing == s
                                    ? _stop
                                    : () => _play(s),
                          ),
                        ),
                      ],
                    ]),
                    const SizedBox(height: 8),
                    Text(
                      _playing?.title ??
                          'The moves the benchmark makes, the same for '
                              'every package.',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 16),
                    const Divider(height: 1),
                    const SizedBox(height: 16),
                    Wrap(spacing: 8, runSpacing: 4, children: [
                      FilledButton.icon(
                        onPressed: () => _benchmark(context),
                        icon: const Icon(Icons.speed, size: 18),
                        label: const Text('Run the benchmark'),
                      ),
                      TextButton.icon(
                        onPressed: () => openInNewTab(summaryUrl),
                        icon: const Icon(Icons.open_in_new, size: 18),
                        label: const Text('Results from real devices'),
                      ),
                    ]),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _description() {
    final arms = _arms;
    if (_sideBySide) {
      return 'Left: ${arms[0].package}, ${arms[0].setup}. '
          'Right: ${arms[1].package}, ${arms[1].setup}. '
          'Both maps share one thread here, so this view shows what each '
          'package draws, not how smoothly it moves.';
    }
    final arm = arms.single;
    return '${arm.package} ${versionOf(arm)}, ${arm.setup}. '
        '${_strategy(arm)}';
  }

  void _benchmark(BuildContext context) {
    final theme = Theme.of(context);
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Benchmark in this browser'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Both packages, each with labels baked into the tiles and '
                  'with labels drawn every frame, drive the same camera '
                  'paths one after another. Each one gets a fresh page '
                  'load, after a warm-up that loads every tile, so no '
                  'package pays the network for another. A table with the '
                  'results comes at the end.',
                ),
                const SizedBox(height: 12),
                Text(
                  'Keep this tab in front and leave the mouse alone until '
                  'the results appear. Browser numbers vary more than the '
                  'device runs in the repository.',
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          OutlinedButton(
            onPressed: () => startBrowserBenchmark(
                BenchmarkLength.full, widget.config.style),
            child: Text('Full · ${BenchmarkLength.full.summary}'),
          ),
          FilledButton(
            onPressed: () => startBrowserBenchmark(
                BenchmarkLength.quick, widget.config.style),
            child: Text('Quick · ${BenchmarkLength.quick.summary}'),
          ),
        ],
      ),
    );
  }

  void _about(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('How this demo works'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: const SingleChildScrollView(
            child: Text(
              'The same OpenFreeMap style, drawn by flutter_map_vector_tiles '
              '$fmvtVersion or vector_map_tiles $vmtVersion. Both packages '
              'can draw labels in two ways. Baked into the tiles is '
              "vector_map_tiles' default (raster mode) and LabelMode.tile in "
              'flutter_map_vector_tiles. Drawn every frame is '
              "flutter_map_vector_tiles' default and vector mode in "
              'vector_map_tiles. Compare like with like. vector_map_tiles '
              'runs with maximumZoom: 22, without which it goes blank past '
              'z18; everything else is at its defaults.\n\n'
              'Every switch reloads the page, so each package runs alone '
              'and starts with nothing cached by the other.\n\n'
              'The smoothness meter counts, over the last two seconds of '
              'motion, how many screen refreshes got a new frame. Anything '
              'that holds up a frame counts, whether building it, drawing '
              'it, or work done between frames. 100% is perfectly smooth.\n\n'
              'The camera paths are the ones the benchmark drives, so you '
              'can watch each package on the identical path.\n\n'
              'Drag to pan, scroll or pinch to zoom, Ctrl + drag to rotate.',
            ),
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

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 6),
      child: Text(text,
          style: theme.textTheme.labelLarge
              ?.copyWith(color: theme.colorScheme.primary)),
    );
  }
}

/// One camera path: icon over name, in an even row of four.
class _PathButton extends StatelessWidget {
  const _PathButton({
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.active,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final String tooltip;
  final bool active;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final child = Column(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 20),
      const SizedBox(height: 4),
      Text(label),
    ]);
    const style = ButtonStyle(
      // Desktop's compact density takes 8 px off the vertical padding,
      // which put the icon and the label against the edges.
      visualDensity: VisualDensity.standard,
      padding: WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 4, vertical: 10)),
      shape: WidgetStatePropertyAll(RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(12)))),
    );
    return Tooltip(
      message: tooltip,
      child: active
          ? FilledButton(onPressed: onPressed, style: style, child: child)
          : FilledButton.tonal(
              onPressed: onPressed, style: style, child: child),
    );
  }
}

/// A two-way choice that keeps long package names on one line.
class _Segments<T> extends StatelessWidget {
  const _Segments({
    required this.values,
    required this.selected,
    required this.onSelected,
  });

  final Map<T, String> values;
  final Set<T> selected;
  final void Function(T)? onSelected;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: double.infinity,
        child: SegmentedButton<T>(
          segments: [
            for (final MapEntry(:key, :value) in values.entries)
              ButtonSegment(
                value: key,
                label: FittedBox(fit: BoxFit.scaleDown, child: Text(value)),
              ),
          ],
          selected: selected,
          multiSelectionEnabled: selected.length > 1,
          showSelectedIcon: false,
          onSelectionChanged: onSelected == null
              ? null
              : (s) {
                  if (s.length == 1 && !selected.contains(s.single)) {
                    onSelected!(s.single);
                  }
                },
          style: const ButtonStyle(
            visualDensity: VisualDensity.compact,
            padding:
                WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 8)),
          ),
        ),
      );
}

class _Chip extends StatelessWidget {
  const _Chip(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Text(text,
              style: const TextStyle(color: Colors.white, fontSize: 12)),
        ),
      );
}

/// Smoothness over the last two seconds of motion.
class _Meter extends StatefulWidget {
  const _Meter({required this.refreshMs, required this.moved});

  final double Function() refreshMs;
  final ValueListenable<bool> moved;

  @override
  State<_Meter> createState() => _MeterState();
}

class _MeterState extends State<_Meter> {
  Timer? _timer;
  FrameStats? _stats;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!widget.moved.value) return;
      final stats = FrameLog.instance.recent(refreshMs: widget.refreshMs());
      // Only repaint when something moved: an idle map stays idle.
      if (stats.frames > 3 || (_stats?.frames ?? 0) > 3) {
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
    const muted = TextStyle(color: Colors.white70, fontSize: 12);
    final pct = s?.deliveredPct;
    final color = pct == null
        ? Colors.white
        : pct >= 95
            ? const Color(0xFF7BE07F)
            : pct >= 80
                ? const Color(0xFFFFC857)
                : const Color(0xFFFF7A6B);
    return Tooltip(
      message: s == null
          ? 'Share of screen refreshes that got a new frame'
          : 'UI thread p90 ${s.build.p90.toStringAsFixed(1)} ms · '
              'raster p90 ${s.raster.p90.toStringAsFixed(1)} ms',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.75),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
          child: SizedBox(
            width: 228,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(children: [
                  const Expanded(
                    child: Text('Smoothness',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w600)),
                  ),
                  Text('$hz Hz display', style: muted),
                ]),
                if (s == null)
                  const Padding(
                    padding: EdgeInsets.only(top: 4),
                    child: Text(
                      'Move the map or play a path to measure.',
                      style: TextStyle(color: Colors.white, fontSize: 13),
                    ),
                  )
                else ...[
                  Text(
                    '${pct!.toStringAsFixed(pct >= 99.95 ? 0 : 1)}%',
                    style: TextStyle(
                      color: color,
                      fontSize: 28,
                      fontWeight: FontWeight.w600,
                      height: 1.2,
                    ),
                  ),
                  const Text('frames delivered in the last 2 s of motion',
                      style: muted),
                  const SizedBox(height: 4),
                  Text(
                    '${s.dropped} dropped · longest pause '
                    '${s.gaps.max.toStringAsFixed(0)} ms',
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
