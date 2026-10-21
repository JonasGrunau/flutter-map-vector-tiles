import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'arms.dart';
import 'bench_page.dart'
    show BenchmarkLength, browserPlanKey, openDemo, startBrowserBenchmark;
import 'config.dart';
import 'demo_page.dart' show summaryUrl;
import 'platform/host.dart';
import 'scenarios.dart';

/// The in-browser benchmark's results: one table per label strategy, the
/// two packages side by side, a row per camera path and pass.
class ResultsPage extends StatelessWidget {
  const ResultsPage({super.key, required this.config});

  final Config config;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final raw = readLocal(browserPlanKey);
    final plan = raw == null ? null : jsonDecode(raw) as Map<String, dynamic>;
    final results = [
      for (final r in (plan?['results'] as List?) ?? const [])
        r as Map<String, dynamic>,
    ];
    final passes = results.where((r) => r['kind'] == 'pass').toList();
    final scenarioIds = [
      for (final s in scenarios)
        if (passes.any((r) => r['scenario'] == s.id)) s.id,
    ];
    final length =
        scenarioIds.length > 2 ? BenchmarkLength.full : BenchmarkLength.quick;
    final first = results.firstOrNull;

    return Scaffold(
      backgroundColor: theme.colorScheme.surfaceContainerLow,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 820),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 32),
              children: [
                Text('Benchmark results',
                    style: theme.textTheme.headlineSmall
                        ?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                if (first != null)
                  Text(
                    'Measured in this browser · '
                    '${(1000 / (first['refreshMs'] as num)).round()} Hz '
                    'display · ${_viewport(first)} map · '
                    '${config.style[0].toUpperCase()}'
                    '${config.style.substring(1)} style',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                const SizedBox(height: 16),
                if (passes.isEmpty)
                  const Card(
                    child: Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('No results yet. Run the benchmark from '
                          'the demo first.'),
                    ),
                  )
                else ...[
                  const _Explainer(),
                  for (final baked in [true, false])
                    _PairTable(
                      title: baked
                          ? 'Labels baked into the tiles'
                          : 'Labels drawn every frame',
                      subtitle: baked
                          ? 'LabelMode.tile against raster mode, the '
                              "default of vector_map_tiles"
                          : 'The default of flutter_map_vector_tiles '
                              'against vector mode',
                      fmvt: Arm.pick(vmt: false, baked: baked),
                      vmt: Arm.pick(vmt: true, baked: baked),
                      scenarioIds: scenarioIds,
                      passes: passes,
                    ),
                ],
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  FilledButton.icon(
                    onPressed: () => openDemo(config.style),
                    icon: const Icon(Icons.map_outlined, size: 18),
                    label: const Text('Back to the demo'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () =>
                        startBrowserBenchmark(length, config.style),
                    icon: const Icon(Icons.replay, size: 18),
                    label: Text('Run it again (${length.summary})'),
                  ),
                  TextButton.icon(
                    onPressed: () => openInNewTab(summaryUrl),
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: const Text('Results from real devices'),
                  ),
                  if (raw != null)
                    TextButton.icon(
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: raw));
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content: Text('Raw results copied')));
                        }
                      },
                      icon: const Icon(Icons.copy, size: 18),
                      label: const Text('Copy raw data'),
                    ),
                ]),
                if (first != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    '${first['agent']}',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _viewport(Map<String, dynamic> row) {
    final v = row['viewport'] as Map<String, dynamic>;
    return '${v['w']}×${v['h']}';
  }
}

class _Explainer extends StatelessWidget {
  const _Explainer();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text.rich(
          const TextSpan(children: [
            TextSpan(
              text: 'Frames delivered ',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            TextSpan(
              text: 'is the main number: of all the times the screen '
                  'refreshed while the map moved, how often there was a new '
                  'frame. 100% is perfectly smooth; at 60 Hz, 80% means '
                  'about 12 skipped frames a second.\n\n',
            ),
            TextSpan(
              text: 'Cold ',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            TextSpan(text: 'is the first pass over a city, '),
            TextSpan(
              text: 'warm ',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            TextSpan(
              text: 'the same path again right after. Below each number: '
                  'pauses over 50 ms, and how long the map kept changing '
                  'after the camera stopped. Bold marks the better of the '
                  'two packages, by at least 1 point. One browser run is '
                  'noisy; run it twice before reading much into a few '
                  'points.',
            ),
          ]),
          style: theme.textTheme.bodyMedium,
        ),
      ),
    );
  }
}

/// One label strategy: a row per camera path and pass, the two packages
/// in columns.
class _PairTable extends StatelessWidget {
  const _PairTable({
    required this.title,
    required this.subtitle,
    required this.fmvt,
    required this.vmt,
    required this.scenarioIds,
    required this.passes,
  });

  final String title;
  final String subtitle;
  final Arm fmvt;
  final Arm vmt;
  final List<String> scenarioIds;
  final List<Map<String, dynamic>> passes;

  Map<String, dynamic>? _row(Arm arm, String scenario, String pass) => passes
      .where((r) =>
          r['arm'] == arm.id && r['scenario'] == scenario && r['pass'] == pass)
      .firstOrNull;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final header = theme.textTheme.labelMedium
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    TableRow headerRow() => TableRow(
          decoration: BoxDecoration(
            border: Border(
                bottom: BorderSide(color: theme.colorScheme.outlineVariant)),
          ),
          children: [
            _cell(Text('Camera path', style: header)),
            // On a phone a package name wraps after an underscore, not
            // in the middle of a word.
            for (final name in ['flutter_map_vector_tiles', 'vector_map_tiles'])
              _cell(Text(name.replaceAll('_', '_​'), style: header)),
          ],
        );
    var aAhead = 0, bAhead = 0, compared = 0;
    for (final id in scenarioIds) {
      for (final pass in ['cold', 'warm']) {
        final pa = _row(fmvt, id, pass)?['deliveredPct'] as num?;
        final pb = _row(vmt, id, pass)?['deliveredPct'] as num?;
        if (pa == null || pb == null) continue;
        compared++;
        if (pa - pb >= 1) aAhead++;
        if (pb - pa >= 1) bAhead++;
      }
    }
    final verdict = switch ((aAhead, bAhead)) {
      (0, 0) => 'No difference of 1 point or more in $compared passes.',
      (final a, 0) when a == compared =>
        'flutter_map_vector_tiles delivered more frames in all $a passes.',
      (0, final b) when b == compared =>
        'vector_map_tiles delivered more frames in all $b passes.',
      (final a, 0) => 'flutter_map_vector_tiles delivered more frames in '
          '$a of $compared passes; the rest were even.',
      (0, final b) => 'vector_map_tiles delivered more frames in $b of '
          '$compared passes; the rest were even.',
      (final a, final b) => 'flutter_map_vector_tiles was ahead in $a of '
          '$compared passes, vector_map_tiles in $b.',
    };
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600)),
            Text(subtitle,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 8),
            Text(verdict, style: theme.textTheme.bodyMedium),
            const SizedBox(height: 4),
            Table(
              columnWidths: const {
                0: FlexColumnWidth(1.1),
                1: FlexColumnWidth(),
                2: FlexColumnWidth(),
              },
              defaultVerticalAlignment: TableCellVerticalAlignment.top,
              children: [
                headerRow(),
                for (final id in scenarioIds)
                  for (final pass in ['cold', 'warm'])
                    _resultRow(context, id, pass),
              ],
            ),
          ],
        ),
      ),
    );
  }

  TableRow _resultRow(BuildContext context, String id, String pass) {
    final theme = Theme.of(context);
    final a = _row(fmvt, id, pass);
    final b = _row(vmt, id, pass);
    final pa = (a?['deliveredPct'] as num?)?.toDouble();
    final pb = (b?['deliveredPct'] as num?)?.toDouble();
    final aWins = pa != null && pb != null && pa - pb >= 1;
    final bWins = pa != null && pb != null && pb - pa >= 1;
    return TableRow(
      decoration: BoxDecoration(
        border: Border(
            bottom: BorderSide(
                color:
                    theme.colorScheme.outlineVariant.withValues(alpha: 0.5))),
      ),
      children: [
        _cell(Text(
          '${id[0].toUpperCase()}${id.substring(1)}, $pass',
          style: theme.textTheme.bodyMedium,
        )),
        _cell(_Result(a, best: aWins)),
        _cell(_Result(b, best: bWins)),
      ],
    );
  }

  static Widget _cell(Widget child) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: child,
      );
}

class _Result extends StatelessWidget {
  const _Result(this.row, {required this.best});

  final Map<String, dynamic>? row;
  final bool best;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = row;
    if (r == null) return const Text('–');
    final pct = (r['deliveredPct'] as num).toDouble();
    final stalls = r['stalls50'] as int;
    final settle = r['settleMs'] as num;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${pct.toStringAsFixed(1)}%',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: best ? FontWeight.w700 : FontWeight.w400,
            color: best ? theme.colorScheme.primary : null,
          ),
        ),
        Text(
          '$stalls ${stalls == 1 ? 'pause' : 'pauses'} · '
          // -1: the map never settled (`_settle`).
          '${switch (settle) {
            < 0 => 'never settled',
            < 50 => 'settled at once',
            _ => 'settled in ${(settle / 1000).toStringAsFixed(1)} s',
          }}',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}
