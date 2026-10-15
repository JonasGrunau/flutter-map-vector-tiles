// Turns lab sessions into the Markdown tables in RESULTS.md.
//
//   dart run tool/summarize.dart results/raw/2026-10-10-android [more…]
//
// Every number is the median over a session's rounds, and the delivered
// column also shows the range, so a single lucky or unlucky run is visible
// instead of being averaged away. A session that mixes viewports or builds,
// or reports a measurement twice, gets a warning above its tables.
library;

import 'dart:convert';
import 'dart:io';

const _armOrder = [
  'fmvt',
  'fmvt-none',
  'fmvt-raster',
  'fmvt-raster-none',
  'vmt-raster',
  'vmt-vector',
];
const _armTitle = {
  'fmvt': 'flutter_map_vector_tiles',
  'fmvt-none': 'flutter_map_vector_tiles · TileOffset.none',
  'fmvt-raster': 'flutter_map_vector_tiles · LabelMode.tile',
  'fmvt-raster-none':
      'flutter_map_vector_tiles · LabelMode.tile · TileOffset.none',
  'vmt-raster': 'vector_map_tiles · raster',
  'vmt-vector': 'vector_map_tiles · vector',
};
const _scenarioOrder = ['zoom', 'pan', 'rotate', 'fling'];

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: summarize.dart <session dir>…');
    exit(64);
  }
  for (final dir in args) {
    final file = File('$dir/results.jsonl');
    final rows = [
      for (final line in file.readAsLinesSync())
        if (line.trim().isNotEmpty) jsonDecode(line) as Map<String, dynamic>,
    ];
    stdout.writeln(_session(rows));
  }
}

String _session(List<Map<String, dynamic>> rows) {
  final out = StringBuffer();
  final errors = rows.where((r) => r['kind'] == 'error').toList();
  // A pass or an opening during which the app was not in front measures the
  // platform's throttling, not the package; it is reported, never averaged
  // in.
  bool measured(Map<String, dynamic> r, String kind) =>
      r['kind'] == kind && r['interrupted'] != true;
  final interrupted = rows
      .where((r) =>
          (r['kind'] == 'pass' || r['kind'] == 'open') &&
          r['interrupted'] == true)
      .toList();
  final passes = rows.where((r) => measured(r, 'pass')).toList();
  final opens = rows.where((r) => measured(r, 'open')).toList();
  if (passes.isEmpty) {
    out.writeln('> ⚠️ No measured pass in this session.');
    for (final e in errors) {
      out.writeln('> ⚠️ ${e['run']}: ${e['error']}');
    }
    return out.toString();
  }
  final first = passes.first;
  final arms = [
    for (final a in _armOrder)
      if (passes.any((r) => r['arm'] == a)) a,
  ];
  // Per arm: a failed or interrupted run leaves an arm with fewer.
  final runsPerArm = [
    for (final a in arms)
      passes.where((r) => r['arm'] == a).map((r) => r['run']).toSet().length,
  ];
  final fewestRuns = runsPerArm.reduce((a, b) => a < b ? a : b);
  final mostRuns = runsPerArm.reduce((a, b) => a > b ? a : b);
  final fmvtVersion = passes.firstWhere(
      (r) => r['package'] == 'flutter_map_vector_tiles',
      orElse: () => const {})['version'];
  final vmtVersion = passes.firstWhere(
      (r) => r['package'] == 'vector_map_tiles',
      orElse: () => const {})['version'];

  void warn(String message) => out
    ..writeln('> ⚠️ $message')
    ..writeln();

  final viewport = first['viewport'] as Map<String, dynamic>;
  // A phone turned mid-session changes the tile count per screen for every
  // run after it; such a session compares unlike with unlike. Error rows
  // carry no viewport.
  final viewports = {
    for (final r in rows)
      if (r['viewport'] != null) jsonEncode(r['viewport']),
  };
  if (viewports.length > 1) {
    warn('This session mixes viewports (${viewports.join(', ')}); '
        'the device was rotated or resized between runs.');
  }
  final commits = {
    for (final r in rows)
      if (r['commit'] != null) r['commit'],
  };
  if (commits.length > 1) {
    warn('This session mixes builds (commits ${commits.join(', ')}): two '
        'sessions were written into one directory.');
  }
  // The same measurement twice would be averaged in twice.
  final seen = <String>{};
  final duplicates = <String>{};
  for (final r in rows) {
    final key = [
      r['run'],
      r['kind'],
      if (r['scenario'] != null) r['scenario'],
      if (r['pass'] != null) r['pass'],
    ].join(' ');
    if (!seen.add(key)) duplicates.add(key);
  }
  if (duplicates.isNotEmpty) {
    warn('${duplicates.length} measurement(s) appear more than once '
        '(${duplicates.take(3).join('; ')}${duplicates.length > 3 ? '; …' : ''}): '
        'two sessions were written into one directory, or a run was '
        'reported twice.');
  }
  out
    ..writeln('### ${first['device']} · ${first['platform']}')
    ..writeln()
    ..writeln('Flutter ${first['flutter']} · flutter_map_vector_tiles '
        '$fmvtVersion (${first['commit']}) · vector_map_tiles $vmtVersion · '
        '${viewport['w']}×${viewport['h']} logical px at dpr ${first['dpr']} · '
        'display ${(1000 / (first['refreshMs'] as num)).round()} Hz · '
        'median of ${fewestRuns == mostRuns ? '$mostRuns' : '$fewestRuns–$mostRuns'} '
        'run${mostRuns == 1 ? '' : 's'} per arm'
        '${errors.isEmpty ? '' : ' · ⚠️ ${errors.length} failed run(s)'}'
        '${interrupted.isEmpty ? '' : ' · ⚠️ ${interrupted.length} interrupted '
            'measurement(s) excluded'}')
    ..writeln();

  List<Map<String, dynamic>> cell(String arm, String scenario, String pass) =>
      passes
          .where((r) =>
              r['arm'] == arm && r['scenario'] == scenario && r['pass'] == pass)
          .toList();

  final scenarios = [
    for (final s in _scenarioOrder)
      if (passes.any((r) => r['scenario'] == s)) s,
  ];
  final header = '| | ${arms.map((a) => _armTitle[a]).join(' | ')} |';
  final rule = '|---|${arms.map((_) => '---:').join('|')}|';

  void table(String title, String Function(List<Map<String, dynamic>>) f) {
    out
      ..writeln('**$title**')
      ..writeln()
      ..writeln(header)
      ..writeln(rule);
    for (final s in scenarios) {
      for (final p in ['cold', 'warm']) {
        out.writeln('| $s · $p | '
            '${arms.map((a) => f(cell(a, s, p))).join(' | ')} |');
      }
    }
    out.writeln();
  }

  table('Frames delivered while the camera moves (higher is better)', (c) {
    if (c.isEmpty) return '–';
    final v = c.map((r) => (r['deliveredPct'] as num).toDouble()).toList();
    final stalls = _median(c.map((r) => (r['stalls50'] as num).toDouble()));
    final range = v.length < 2
        ? ''
        : ' <sub>${_min(v).toStringAsFixed(1)}–'
            '${_max(v).toStringAsFixed(1)}</sub>';
    return '${_median(v).toStringAsFixed(1)} %$range'
        '${stalls > 0 ? ' · ${stalls.toStringAsFixed(0)} stall'
            '${stalls == 1 ? '' : 's'}' : ''}';
  });
  table('Worst frame gap, ms (lower is better)', (c) {
    if (c.isEmpty) return '–';
    return _median(c.map((r) => _num(r['gapMs'], 'max'))).toStringAsFixed(0);
  });
  table('UI thread p90 / raster thread p90, ms', (c) {
    if (c.isEmpty) return '–';
    final ui = _median(c.map((r) => _num(r['buildMs'], 'p90')));
    final raster = _median(c.map((r) => _num(r['rasterMs'], 'p90')));
    return '${ui.toStringAsFixed(1)} / ${raster.toStringAsFixed(1)}';
  });
  table('Settle: time from the camera stopping to the last repaint, ms', (c) {
    if (c.isEmpty) return '–';
    return _settleCell(c.map((r) => r['settleMs'] as num));
  });

  out
    ..writeln('**Opening the map, network and memory**')
    ..writeln()
    ..writeln(header)
    ..writeln(rule);
  String openCell(String arm) {
    final c = opens.where((r) => r['arm'] == arm).toList();
    return c.isEmpty ? '–' : _settleCell(c.map((r) => r['settleMs'] as num));
  }

  // A `net` row is a whole run's traffic (sessions recorded since
  // 2026-10-13). Older sessions only have the open and pass rows, whose sum
  // leaves out the jump to each scenario's start and the wait for it to
  // settle; the row says so instead of calling that a run.
  final wholeRuns = rows.any((r) => r['kind'] == 'net');
  final perRunLabel =
      wholeRuns ? 'per run' : 'while opening and in the measured passes';
  String runTotal(String arm, String key) {
    final perRun = <Object?, double>{};
    for (final r in rows.where((r) =>
        r['arm'] == arm &&
        (wholeRuns
            ? r['kind'] == 'net'
            : r['kind'] == 'pass' || r['kind'] == 'open'))) {
      perRun[r['run']] = (perRun[r['run']] ?? 0) + ((r[key] as num?) ?? 0);
    }
    return perRun.isEmpty ? '–' : _median(perRun.values).toStringAsFixed(0);
  }

  out
    ..writeln('| time to first complete map, ms | '
        '${arms.map(openCell).join(' | ')} |')
    // Every resource fetched through the lab: style, TileJSON, sprites and
    // tiles.
    ..writeln('| requests $perRunLabel | '
        '${arms.map((a) => runTotal(a, 'requests')).join(' | ')} |')
    ..writeln('| MB downloaded $perRunLabel | ${arms.map((a) {
      final b = runTotal(a, 'bytes');
      return b == '–' ? b : (double.parse(b) / 1e6).toStringAsFixed(1);
    }).join(' | ')} |');
  if (passes.any((r) => r['rssMaxMb'] != null)) {
    out.writeln('| peak RSS, MB | ${arms.map((a) {
      final v = passes
          .where((r) => r['arm'] == a && r['rssMaxMb'] != null)
          .map((r) => (r['rssMaxMb'] as num).toDouble());
      return v.isEmpty
          ? '–'
          : _median(_maxPerRun(passes, a)).toStringAsFixed(0);
    }).join(' | ')} |');
  }
  out.writeln();
  for (final e in errors) {
    out.writeln('> ⚠️ ${e['run']}: ${e['error']}');
  }
  return out.toString();
}

/// Peak RSS of each run of [arm] (the max over its passes).
Iterable<double> _maxPerRun(List<Map<String, dynamic>> passes, String arm) {
  final perRun = <Object?, double>{};
  for (final r in passes.where((r) => r['arm'] == arm)) {
    final v = (r['rssMaxMb'] as num?)?.toDouble();
    if (v == null) continue;
    final run = r['run'];
    if (v > (perRun[run] ?? 0)) perRun[run] = v;
  }
  return perRun.values;
}

/// The median of [settles] in ms. -1 means the app's `_settle` gave up
/// before the map went quiet, so it counts as longer than any measured
/// value, and the cell says how many did.
String _settleCell(Iterable<num> settles) {
  final v = [
    for (final s in settles) s < 0 ? double.infinity : s.toDouble(),
  ];
  final timedOut = v.where((x) => x.isInfinite).length;
  final median = _median(v);
  if (timedOut == 0) return median.toStringAsFixed(0);
  return median.isFinite
      ? '${median.toStringAsFixed(0)} ($timedOut timed out)'
      : 'timed out ($timedOut of ${v.length})';
}

double _num(Object? map, String key) =>
    ((map as Map<String, dynamic>)[key] as num).toDouble();

double _median(Iterable<double> values) {
  final v = values.toList()..sort();
  if (v.isEmpty) return 0;
  final mid = v.length ~/ 2;
  return v.length.isOdd ? v[mid] : (v[mid - 1] + v[mid]) / 2;
}

double _min(List<double> v) => v.reduce((a, b) => a < b ? a : b);
double _max(List<double> v) => v.reduce((a, b) => a > b ? a : b);
