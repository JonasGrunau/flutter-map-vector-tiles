import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'arms.dart';
import 'bench_page.dart' show browserPlanKey;
import 'platform/host.dart';

/// The in-browser benchmark's table: one row per scenario and pass, one
/// column group per package.
class ResultsPage extends StatelessWidget {
  const ResultsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final raw = readLocal(browserPlanKey);
    final plan = raw == null ? null : jsonDecode(raw) as Map<String, dynamic>;
    final results = [
      for (final r in (plan?['results'] as List?) ?? const [])
        r as Map<String, dynamic>,
    ];
    final theme = Theme.of(context);
    final passes = results.where((r) => r['kind'] == 'pass').toList();
    final arms = [
      for (final id in passes.map((r) => r['arm'] as String).toSet())
        Arm.parse(id),
    ];
    final rows = <(String, String)>{
      for (final r in passes) (r['scenario'] as String, r['pass'] as String),
    }.toList();
    final first = results.firstOrNull;

    Map<String, dynamic>? cell(Arm arm, (String, String) row) =>
        passes.where((r) {
          return r['arm'] == arm.id &&
              r['scenario'] == row.$1 &&
              r['pass'] == row.$2;
        }).firstOrNull;

    String fmt(Object? v, [int digits = 1]) =>
        v is num ? v.toStringAsFixed(digits) : '–';

    return Scaffold(
      appBar: AppBar(title: const Text('Benchmark results')),
      body: results.isEmpty
          ? const Center(child: Text('No results yet.'))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  'Frames delivered is the share of display refreshes that '
                  'got a frame while the camera moved; it counts every '
                  'kind of stall. Settle is how long the map kept changing '
                  'after the camera stopped. Cold is the first pass over a '
                  'city, warm the immediate repeat.',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 8),
                if (first != null)
                  Text(
                    '${first['agent']} · dpr ${first['dpr']} · '
                    'viewport ${first['viewport']} · '
                    'refresh ${first['refreshMs']} ms',
                    style: theme.textTheme.bodySmall,
                  ),
                const SizedBox(height: 16),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    columnSpacing: 18,
                    columns: [
                      const DataColumn(label: Text('scenario')),
                      for (final a in arms)
                        DataColumn(
                          label: Text(
                            '${a.label}\ndelivered · stalls · UI p90 · settle',
                            style: theme.textTheme.labelSmall,
                          ),
                        ),
                    ],
                    rows: [
                      for (final row in rows)
                        DataRow(cells: [
                          DataCell(Text('${row.$1} · ${row.$2}')),
                          for (final a in arms)
                            DataCell(Builder(builder: (_) {
                              final c = cell(a, row);
                              if (c == null) return const Text('–');
                              final ui = c['buildMs'] as Map<String, dynamic>;
                              return Text(
                                '${fmt(c['deliveredPct'])}% · '
                                '${c['stalls50']} · '
                                '${fmt(ui['p90'])} ms · '
                                '${c['settleMs']} ms',
                              );
                            })),
                        ]),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Wrap(spacing: 8, children: [
                  FilledButton(
                    onPressed: () => navigate(Uri.base
                        .replace(queryParameters: {'arm': 'fmvt'}).toString()),
                    child: const Text('Back to the demo'),
                  ),
                  OutlinedButton(
                    onPressed: () =>
                        Clipboard.setData(ClipboardData(text: raw ?? '')),
                    child: const Text('Copy raw JSON'),
                  ),
                ]),
              ],
            ),
    );
  }
}
