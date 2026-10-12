// The lab server behind every measured run: a record/replay proxy for
// OpenFreeMap, a run queue, and a sink for results and screenshots.
//
//   dart run tool/lab_server.dart --platform android --rounds 3
//
// Why a proxy at all: a benchmark that fetches tiles from the internet
// measures the internet. Every request goes through here instead, so both
// packages see the same bytes at the same (USB or loopback) latency, and the
// first run records the tiles into `--cache` while every later run — and
// every later session, with `--offline` — replays them. The TileJSON is
// recorded with the rest, which pins OpenFreeMap's dated tileset
// (`planet/<date>/…`) for as long as the cache directory lives.
//
// Why a run queue: one app binary serves every arm. At start-up the app asks
// `GET /_next` which arm to run, so a device run needs one build, not one
// per arm, and every arm still gets a fresh process. Arms rotate their order
// each round so a slow drift (thermal, battery) cannot favour one arm.
//
// Requests are attributed to a run by URL prefix (`/r/<run>/ofm/…`), which
// is what the app's style URL points at, so the per-run request and byte
// counts in the results are counted here rather than inside either package.
//
// No dependencies beyond dart:io, so it runs with a bare `dart`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const _upstream = 'https://tiles.openfreemap.org/';
const _userAgent = 'flutter_map_vector_tiles-compare/0.1 '
    '(+https://github.com/JonasGrunau/flutter-map-vector-tiles)';
const _defaultArms = [
  'fmvt',
  'fmvt-none',
  'fmvt-raster',
  'fmvt-raster-none',
  'vmt-raster',
  'vmt-vector',
];

Future<void> main(List<String> argv) async {
  final args = _Args(argv);
  final port = int.parse(args.get('port', '8790'));
  final cacheDir = Directory(args.get('cache', '.lab-cache'));
  final platform = args.get('platform', 'unknown');
  final rounds = int.parse(args.get('rounds', '3'));
  final arms = args.get('arms', _defaultArms.join(',')).split(',');
  final scenarios = args.get('scenarios', '');
  final offline = args.flag('offline');
  final latency =
      Duration(milliseconds: int.parse(args.get('latency-ms', '0')));
  final session = args.get(
    'session',
    '${DateTime.now().toIso8601String().substring(0, 10)}-$platform',
  );
  final outDir = Directory(args.get('out', 'results/raw/$session'));
  final appDir = args.get('app', '');

  await cacheDir.create(recursive: true);
  await Directory('${outDir.path}/shots').create(recursive: true);

  final queue = <_Run>[
    for (var r = 0; r < rounds; r++)
      for (var i = 0; i < arms.length; i++)
        _Run(
          id: '$platform-r$r-${arms[(i + r) % arms.length]}',
          arm: arms[(i + r) % arms.length],
          round: r,
        ),
  ];
  final server = _LabServer(
    cacheDir: cacheDir,
    outDir: outDir,
    queue: queue,
    platform: platform,
    scenarios: scenarios,
    offline: offline,
    latency: latency,
    appDir: appDir.isEmpty ? null : Directory(appDir),
  );

  final http = await HttpServer.bind(InternetAddress.anyIPv4, port);
  stdout.writeln('lab server on :$port · session $session · '
      '${queue.length} runs (${arms.join(', ')} × $rounds) · '
      'cache ${cacheDir.path}${offline ? ' (offline)' : ''} · '
      'results ${outDir.path}');
  await for (final request in http) {
    unawaited(server.handle(request));
  }
}

class _Run {
  _Run({required this.id, required this.arm, required this.round});

  final String id;
  final String arm;
  final int round;
  String state = 'pending'; // pending → running → done
  int requests = 0;
  int bytes = 0;
  int inflight = 0;
  DateTime lastActivity = DateTime.now();
}

class _LabServer {
  _LabServer({
    required this.cacheDir,
    required this.outDir,
    required this.queue,
    required this.platform,
    required this.scenarios,
    required this.offline,
    required this.latency,
    required this.appDir,
  });

  final Directory cacheDir;
  final Directory outDir;
  final List<_Run> queue;
  final String platform;
  final String scenarios;
  final bool offline;
  final Duration latency;

  /// A `flutter build web --base-href /app/` output to serve at `/app/`, so
  /// browser runs load the app from the same origin as the tiles.
  final Directory? appDir;
  final _client = HttpClient()..userAgent = _userAgent;
  final _pending = <String, Future<_Cached?>>{};

  /// Runs outside the queue (the demo, ad-hoc launches) still get counters.
  final _adHoc = <String, _Run>{};

  _Run _run(String id) => queue.firstWhere((r) => r.id == id, orElse: () {
        return _adHoc.putIfAbsent(
            id, () => _Run(id: id, arm: 'ad-hoc', round: -1));
      });

  Future<void> handle(HttpRequest req) async {
    final res = req.response;
    res.headers
      ..set('Access-Control-Allow-Origin', '*')
      ..set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
      ..set('Access-Control-Allow-Headers', '*')
      // The app and the control endpoints are never cached; proxied
      // OpenFreeMap resources override this in [_proxy].
      ..set('Cache-Control', 'no-store');
    try {
      if (req.method == 'OPTIONS') return await _end(res, 204);
      final path = req.uri.path;
      if (path == '/_next') return await _next(res);
      if (path == '/_net') return await _net(req, res);
      if (path == '/_result') return await _result(req, res);
      if (path == '/_shot') return await _shot(req, res);
      if (path == '/_done') return await _done(req, res);
      if (path == '/_status') return await _status(res);
      if (path == '/_log') {
        stdout.writeln('[app] ${await utf8.decodeStream(req)}');
        return await _end(res, 204);
      }
      final m = RegExp(r'^/r/([^/]+)/ofm/(.+)$').firstMatch(path);
      if (m != null) return await _proxy(req, res, _run(m[1]!), m[2]!);
      final bare = RegExp(r'^/ofm/(.+)$').firstMatch(path);
      if (bare != null) return await _proxy(req, res, _run('-'), bare[1]!);
      if (appDir != null && path.startsWith('/app/')) {
        return await _static(res, path.substring('/app/'.length));
      }
      await _end(res, 404);
    } catch (e, st) {
      stderr.writeln('error on ${req.uri}: $e\n$st');
      try {
        await _end(res, 500);
      } catch (_) {}
    }
  }

  Future<void> _static(HttpResponse res, String relative) async {
    if (relative.isEmpty) relative = 'index.html';
    if (relative.split('/').contains('..')) return _end(res, 400);
    final file = File('${appDir!.path}/$relative');
    if (!file.existsSync()) return _end(res, 404);
    final ext = relative.substring(relative.lastIndexOf('.') + 1);
    res.headers
        .set('Content-Type', _mimeTypes[ext] ?? 'application/octet-stream');
    await res.addStream(file.openRead());
    await res.close();
  }

  Future<void> _end(HttpResponse res, int status, [Object? json]) async {
    res.statusCode = status;
    if (json != null) {
      res.headers.contentType = ContentType.json;
      res.write(jsonEncode(json));
    }
    await res.close();
  }

  Future<void> _next(HttpResponse res) async {
    final run = queue.where((r) => r.state == 'pending').firstOrNull;
    if (run == null) return _end(res, 200, {'done': true});
    run.state = 'running';
    stdout.writeln('▶ ${run.id}');
    await _end(res, 200, {
      'run': run.id,
      'arm': run.arm,
      'round': run.round,
      'platform': platform,
      if (scenarios.isNotEmpty) 'scenarios': scenarios,
    });
  }

  Future<void> _net(HttpRequest req, HttpResponse res) async {
    final run = _run(req.uri.queryParameters['run'] ?? '-');
    await _end(res, 200, {
      'requests': run.requests,
      'bytes': run.bytes,
      'inflight': run.inflight,
      'idleMs': DateTime.now().difference(run.lastActivity).inMilliseconds,
    });
  }

  Future<void> _result(HttpRequest req, HttpResponse res) async {
    final line = (await utf8.decodeStream(req)).trim();
    jsonDecode(line); // reject anything that is not one JSON object
    await File('${outDir.path}/results.jsonl')
        .writeAsString('$line\n', mode: FileMode.append, flush: true);
    stdout.writeln('  ✓ ${line.length > 160 ? line.substring(0, 160) : line}');
    await _end(res, 204);
  }

  Future<void> _shot(HttpRequest req, HttpResponse res) async {
    final name = req.uri.queryParameters['name']!;
    if (!RegExp(r'^[\w.-]+$').hasMatch(name)) return _end(res, 400);
    final bytes = await _readAll(req);
    await File('${outDir.path}/shots/$name.png').writeAsBytes(bytes);
    await _end(res, 204);
  }

  Future<void> _done(HttpRequest req, HttpResponse res) async {
    final run = _run(req.uri.queryParameters['run'] ?? '-');
    run.state = 'done';
    stdout.writeln('■ ${run.id} (${run.requests} requests, '
        '${(run.bytes / 1e6).toStringAsFixed(1)} MB)');
    await _end(res, 204);
  }

  Future<void> _status(HttpResponse res) => _end(res, 200, {
        for (final s in ['pending', 'running', 'done'])
          s: queue.where((r) => r.state == s).map((r) => r.id).toList(),
      });

  Future<void> _proxy(
      HttpRequest req, HttpResponse res, _Run run, String path) async {
    run.requests++;
    run.inflight++;
    run.lastActivity = DateTime.now();
    try {
      final cached = await _fetch(path);
      if (latency > Duration.zero) await Future<void>.delayed(latency);
      if (cached == null) return await _end(res, offline ? 504 : 404);
      var body = cached.bytes;
      if (cached.contentType.contains('json')) {
        // Point every OpenFreeMap URL in style.json / TileJSON back here,
        // under this run's prefix, so nothing escapes to the internet.
        final host = req.headers.host ?? 'localhost';
        final port = req.connectionInfo?.localPort;
        final base = 'http://$host${port == null ? '' : ':$port'}'
            '/r/${run.id}/ofm/';
        body = utf8.encode(utf8.decode(body).replaceAll(_upstream, base));
      }
      run.bytes += body.length;
      // OpenFreeMap lets browsers cache everything it serves, for a day
      // (style, TileJSON) to ten years (tiles, sprites). On the web,
      // flutter_map_vector_tiles has no disk cache and counts on that HTTP
      // cache to bring back a tile it has evicted from memory, so `no-store`
      // here would measure a tile server nobody runs. Nothing carries over
      // between runs: every run has its own URL prefix and, on the web, a
      // fresh browser context. Native HTTP clients have no HTTP cache.
      res.headers
        ..set('Content-Type', cached.contentType)
        ..set('Cache-Control', 'public, max-age=86400');
      res.add(body);
      await res.close();
    } finally {
      run.inflight--;
      run.lastActivity = DateTime.now();
    }
  }

  /// Disk-cached upstream fetch, coalesced per path.
  Future<_Cached?> _fetch(String path) {
    final key = path.replaceAll(RegExp(r'[^\w.-]'), '_');
    // A block body on purpose: an arrow would return the removed future —
    // this one — and `whenComplete` would wait for itself forever.
    return _pending[key] ??= _fetchUncoalesced(path, key).whenComplete(() {
      _pending.remove(key);
    });
  }

  Future<_Cached?> _fetchUncoalesced(String path, String key) async {
    final body = File('${cacheDir.path}/$key');
    final meta = File('${cacheDir.path}/$key.type');
    if (body.existsSync() && meta.existsSync()) {
      return _Cached(await body.readAsBytes(), await meta.readAsString());
    }
    if (offline) {
      stderr.writeln('offline miss: $path');
      return null;
    }
    final request = await _client.getUrl(Uri.parse('$_upstream$path'));
    final response = await request.close();
    final bytes = await _readAll(response);
    if (response.statusCode != 200) {
      stderr.writeln('upstream ${response.statusCode}: $path');
      return null;
    }
    final type =
        response.headers.contentType?.mimeType ?? 'application/octet-stream';
    await body.writeAsBytes(bytes);
    await meta.writeAsString(type);
    return _Cached(bytes, type);
  }
}

const _mimeTypes = {
  'html': 'text/html; charset=utf-8',
  'js': 'text/javascript',
  'mjs': 'text/javascript',
  'wasm': 'application/wasm',
  'json': 'application/json',
  'png': 'image/png',
  'ico': 'image/x-icon',
  'css': 'text/css',
  'otf': 'font/otf',
  'ttf': 'font/ttf',
  'symbols': 'text/plain',
};

class _Cached {
  _Cached(this.bytes, this.contentType);
  final List<int> bytes;
  final String contentType;
}

Future<List<int>> _readAll(Stream<List<int>> stream) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    builder.add(chunk);
  }
  return builder.takeBytes();
}

class _Args {
  _Args(List<String> argv) {
    for (var i = 0; i < argv.length; i++) {
      final a = argv[i];
      if (!a.startsWith('--')) continue;
      final eq = a.indexOf('=');
      if (eq > 0) {
        _values[a.substring(2, eq)] = a.substring(eq + 1);
      } else if (i + 1 < argv.length && !argv[i + 1].startsWith('--')) {
        _values[a.substring(2)] = argv[++i];
      } else {
        _values[a.substring(2)] = 'true';
      }
    }
  }

  final _values = <String, String>{};
  String get(String name, String fallback) => _values[name] ?? fallback;
  bool flag(String name) => _values[name] == 'true';
}
