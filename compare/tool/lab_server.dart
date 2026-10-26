// The lab server behind every measured run: a record/replay proxy for
// OpenFreeMap, a run queue, and a sink for results and screenshots.
//
//   dart run tool/lab_server.dart --platform android --rounds 4
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
// per arm, and every arm still gets a fresh process. Rounds come in pairs,
// the second running the first one's order backwards (see [_roundOrder]),
// so a steady drift (thermal, battery) costs every arm the same over each
// pair. An odd round count leaves the last round unpaired.
//
// Requests are attributed to a run by URL prefix (`/r/<run>/ofm/…`), which
// is what the app's style URL points at, so the per-run request and byte
// counts in the results are counted here rather than inside either package.
//
// A run whose app stops talking — it crashed natively, or hung — is given up
// after `--run-timeout` seconds (default 120) without a request for it: an
// error row goes into the results and the run counts as done, so the run
// scripts launch the next one instead of waiting forever. The longest a
// healthy run goes quiet is one camera path without a tile request (16 s).
//
// Every session gets its own directory: the server refuses to start when
// the session's results.jsonl exists, rather than mixing two sessions.
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
  final rounds = int.parse(args.get('rounds', '4'));
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
  final runTimeout =
      Duration(seconds: int.parse(args.get('run-timeout', '120')));

  // Two sessions in one file would be summarized as one: same-day runs on
  // one platform share the default name, so the second must pick its own.
  final results = File('${outDir.path}/results.jsonl');
  if (results.existsSync()) {
    stderr.writeln('${results.path} already exists. A session never '
        'appends to another: name this one with --session <name> '
        '(or --out <dir>).');
    exit(1);
  }

  await cacheDir.create(recursive: true);
  await Directory('${outDir.path}/shots').create(recursive: true);

  final queue = <_Run>[
    for (var r = 0; r < rounds; r++)
      for (final arm in _roundOrder(arms, r))
        _Run(id: '$platform-r$r-$arm', arm: arm, round: r),
  ];
  final server = _LabServer(
    cacheDir: cacheDir,
    outDir: outDir,
    queue: queue,
    platform: platform,
    scenarios: scenarios,
    offline: offline,
    latency: latency,
    runTimeout: runTimeout,
    appDir: appDir.isEmpty ? null : Directory(appDir),
  );

  // Loopback: Android devices reach it through `adb reverse`, which
  // connects to the Mac's loopback, and the Mac app, the browser and the
  // scripts use `localhost`. Both address families, because `localhost`
  // may resolve to either first. An iPhone has no `adb reverse`, so
  // run_ios.sh adds the Mac's end of the phone's USB link with `--bind`:
  // one address on a cable to one device, never every interface.
  final servers = [await HttpServer.bind(InternetAddress.loopbackIPv4, port)];
  try {
    servers.add(await HttpServer.bind(InternetAddress.loopbackIPv6, port,
        v6Only: true));
  } on SocketException catch (e) {
    stdout.writeln('no IPv6 loopback (${e.osError?.message ?? e.message}); '
        'serving 127.0.0.1 only');
  }
  final bind = args.get('bind', '');
  if (bind.isNotEmpty) servers.add(await HttpServer.bind(bind, port));
  stdout.writeln('lab server on :$port · session $session · '
      '${queue.length} runs (${arms.join(', ')} × $rounds) · '
      'cache ${cacheDir.path}${offline ? ' (offline)' : ''} · '
      'results ${outDir.path}');
  if (rounds.isOdd && rounds > 1) {
    stdout.writeln('note: $rounds rounds: the last one has no partner to '
        'balance its arm order; use an even count');
  }
  Timer.periodic(const Duration(seconds: 5), (_) => server.reap());
  for (final http in servers) {
    http.listen((request) => unawaited(server.handle(request)));
  }
}

/// The order of [arms] in [round]. Rounds come in pairs: the first of a
/// pair runs the arms in order, starting one arm further along with every
/// pair, and the second runs that order backwards. An arm's two slots in a
/// pair therefore always add up to `arms.length - 1`, so a steady drift
/// over the session (the phone warming up, the battery draining) costs
/// every arm the same on average over each pair of rounds. A plain
/// rotation does not: with six arms and three rounds it ran one arm in the
/// back half every time and another in the front half every time.
List<String> _roundOrder(List<String> arms, int round) {
  final shift = (round ~/ 2) % arms.length;
  final order = [
    for (var i = 0; i < arms.length; i++) arms[(i + shift) % arms.length],
  ];
  return round.isOdd ? order.reversed.toList() : order;
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

  /// The last proxied request for this run: when its network went idle.
  DateTime lastActivity = DateTime.now();

  /// The last request of any kind about this run — proxied, `/_net`,
  /// `/_result`, `/_log` — for the inactivity timeout.
  DateTime lastContact = DateTime.now();
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
    required this.runTimeout,
    required this.appDir,
  });

  final Directory cacheDir;
  final Directory outDir;
  final List<_Run> queue;
  final String platform;
  final String scenarios;
  final bool offline;
  final Duration latency;
  final Duration runTimeout;

  /// A `flutter build web --base-href /app/` output to serve at `/app/`, so
  /// browser runs load the app from the same origin as the tiles.
  final Directory? appDir;

  /// Upstream fetches give up rather than hold a run's request open
  /// forever: the app would wait on it, and so would every `_settle`.
  final _client = HttpClient()
    ..userAgent = _userAgent
    ..connectionTimeout = const Duration(seconds: 10)
    ..idleTimeout = const Duration(seconds: 15);
  static const _upstreamTimeout = Duration(seconds: 30);
  final _pending = <String, Future<_Fetched>>{};

  /// Runs outside the queue (the demo, ad-hoc launches) still get counters.
  final _adHoc = <String, _Run>{};

  _Run _run(String id) => queue.firstWhere((r) => r.id == id, orElse: () {
        return _adHoc.putIfAbsent(
            id, () => _Run(id: id, arm: 'ad-hoc', round: -1));
      });

  /// Marks [id] as alive, for [reap].
  void _contact(String? id) {
    if (id != null) _run(id).lastContact = DateTime.now();
  }

  Future<void> handle(HttpRequest req) async {
    final res = req.response;
    // The app and the control endpoints are never cached; proxied
    // OpenFreeMap resources override this in [_proxy].
    res.headers.set('Cache-Control', 'no-store');
    try {
      final path = req.uri.path;
      final m = RegExp(r'^/r/([^/]+)/ofm/(.+)$').firstMatch(path);
      final bare = RegExp(r'^/ofm/(.+)$').firstMatch(path);
      if (m != null || bare != null) {
        // The one cross-origin client is MapLibre GL JS in
        // tool/maplibre.html, opened from file:// by reference_shots.mjs,
        // and it only reads OpenFreeMap resources. The app itself is
        // served from /app/ on this origin, so the control endpoints below
        // get no CORS headers.
        res.headers
          ..set('Access-Control-Allow-Origin', '*')
          ..set('Access-Control-Allow-Methods', 'GET')
          ..set('Access-Control-Allow-Headers', '*');
        if (req.method == 'OPTIONS') return await _end(res, 204);
        if (m != null) return await _proxy(req, res, _run(m[1]!), m[2]!);
        return await _proxy(req, res, _run('-'), bare![1]!);
      }
      // No preflight is ever answered here, and an OPTIONS must not reach
      // a handler: `/_next` would hand out a run.
      if (req.method == 'OPTIONS') return await _end(res, 405);
      if (path == '/_next') return await _next(res);
      if (path == '/_net') return await _net(req, res);
      if (path == '/_result') return await _result(req, res);
      if (path == '/_shot') return await _shot(req, res);
      if (path == '/_done') return await _done(req, res);
      if (path == '/_status') return await _status(res);
      if (path == '/_log') {
        final run = req.uri.queryParameters['run'];
        _contact(run);
        stdout.writeln('[app] ${run ?? '-'}: ${await utf8.decodeStream(req)}');
        return await _end(res, 204);
      }
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
    run
      ..state = 'running'
      ..lastContact = DateTime.now();
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
    run.lastContact = DateTime.now();
    await _end(res, 200, {
      'requests': run.requests,
      'bytes': run.bytes,
      'inflight': run.inflight,
      'idleMs': DateTime.now().difference(run.lastActivity).inMilliseconds,
    });
  }

  Future<void> _result(HttpRequest req, HttpResponse res) async {
    final line = (await utf8.decodeStream(req)).trim();
    final json = jsonDecode(line);
    if (json is! Map<String, dynamic>) return _end(res, 400);
    final id = json['run'];
    if (id is String) {
      final run = _run(id);
      // A run given up by [reap] already has its error row; an app that
      // wakes up later must not add numbers to it.
      if (run.state == 'done') {
        stderr.writeln('dropped a result for ${run.id}, which is done');
        return _end(res, 409);
      }
      run.lastContact = DateTime.now();
    }
    await _append(line);
    stdout.writeln('  ✓ ${line.length > 160 ? line.substring(0, 160) : line}');
    await _end(res, 204);
  }

  Future<void> _append(String line) => File('${outDir.path}/results.jsonl')
      .writeAsString('$line\n', mode: FileMode.append, flush: true);

  /// Gives up every running run that nothing has been heard of for
  /// [runTimeout]: its app crashed or hung. Without this a native crash
  /// leaves the run `running` forever, and the run scripts wait on it.
  void reap() {
    final now = DateTime.now();
    for (final run in queue.where((r) => r.state == 'running')) {
      final silent = now.difference(run.lastContact);
      if (silent < runTimeout) continue;
      run.state = 'done';
      stdout.writeln('✗ ${run.id}: nothing heard for ${silent.inSeconds} s, '
          'given up');
      unawaited(_append(jsonEncode({
        'kind': 'error',
        'run': run.id,
        'arm': run.arm,
        'round': run.round,
        'platform': platform,
        'error': 'no request from the app for ${silent.inSeconds} s '
            '(crashed or hung); the lab server gave the run up',
      })));
    }
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
    run.lastActivity = run.lastContact = DateTime.now();
    try {
      // `styles/<name>-heatmap` is OpenFreeMap's `styles/<name>` with a
      // heatmap layer added (see [_withPoiHeatmap]).
      final heatmap = path.startsWith('styles/') && path.endsWith('-heatmap');
      final fetched = await _fetch(
          heatmap ? path.substring(0, path.length - '-heatmap'.length) : path);
      if (latency > Duration.zero) await Future<void>.delayed(latency);
      // Upstream's own status (a 404, a 429, a 5xx) or 504 for an offline
      // miss or a timeout, uncached by the client (`no-store`) and by
      // [_fetch], so a retry can still succeed.
      if (fetched.status != 200) return await _end(res, fetched.status);
      var body = fetched.bytes;
      if (fetched.contentType.contains('json')) {
        // Point every OpenFreeMap URL in style.json / TileJSON back here,
        // under this run's prefix, so nothing escapes to the internet.
        final host = req.headers.host ?? 'localhost';
        final port = req.connectionInfo?.localPort;
        final base = 'http://$host${port == null ? '' : ':$port'}'
            '/r/${run.id}/ofm/';
        body = utf8.encode(utf8.decode(body).replaceAll(_upstream, base));
        if (heatmap) body = _withPoiHeatmap(body);
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
        ..set('Content-Type', fetched.contentType)
        ..set('Cache-Control', 'public, max-age=86400');
      res.add(body);
      await res.close();
    } finally {
      run.inflight--;
      run.lastActivity = DateTime.now();
    }
  }

  /// [style] with a heatmap of the OpenMapTiles `poi` points added, for
  /// measuring a layer type OpenFreeMap's styles do not use, on the same
  /// tiles and for both renderers (`maplibre.html` reads it too). It goes
  /// above the last layer that is not a symbol layer — the place a
  /// screen-space heatmap is drawn by `flutter_map_vector_tiles` — so
  /// the two draw the same thing. The weight reads the feature and the
  /// radius and intensity the zoom, as typical heatmap styles do.
  static List<int> _withPoiHeatmap(List<int> style) {
    final json = jsonDecode(utf8.decode(style)) as Map<String, dynamic>;
    final layers = json['layers'] as List<dynamic>;
    var at = 0;
    for (var i = 0; i < layers.length; i++) {
      if ((layers[i] as Map)['type'] != 'symbol') at = i + 1;
    }
    layers.insert(at, {
      'id': 'lab-poi-heatmap',
      'type': 'heatmap',
      'source': 'openmaptiles',
      'source-layer': 'poi',
      'paint': {
        'heatmap-weight': [
          'interpolate',
          ['linear'],
          ['coalesce', ['get', 'rank'], 30],
          1,
          1,
          30,
          0.25,
        ],
        'heatmap-intensity': [
          'interpolate',
          ['linear'],
          ['zoom'],
          12,
          0.5,
          17,
          1.5,
        ],
        'heatmap-radius': [
          'interpolate',
          ['linear'],
          ['zoom'],
          12,
          10,
          17,
          40,
        ],
        'heatmap-opacity': 0.75,
      },
    });
    json['name'] = '${json['name']} + POI heatmap';
    return utf8.encode(jsonEncode(json));
  }

  /// Disk-cached upstream fetch, coalesced per path. Only a 200 is cached.
  Future<_Fetched> _fetch(String path) {
    final key = path.replaceAll(RegExp(r'[^\w.-]'), '_');
    // A block body on purpose: an arrow would return the removed future —
    // this one — and `whenComplete` would wait for itself forever.
    return _pending[key] ??= _fetchUncoalesced(path, key).whenComplete(() {
      _pending.remove(key);
    });
  }

  Future<_Fetched> _fetchUncoalesced(String path, String key) async {
    final body = File('${cacheDir.path}/$key');
    final meta = File('${cacheDir.path}/$key.type');
    if (body.existsSync() && meta.existsSync()) {
      return _Fetched(200, await body.readAsBytes(), await meta.readAsString());
    }
    if (offline) {
      stderr.writeln('offline miss: $path');
      return _Fetched.failed(504);
    }
    HttpClientRequest? request;
    try {
      request = await _client.getUrl(Uri.parse('$_upstream$path'));
      final response = await request.close().timeout(_upstreamTimeout);
      final bytes = await _readAll(response).timeout(_upstreamTimeout);
      if (response.statusCode != 200) {
        stderr.writeln('upstream ${response.statusCode}: $path');
        return _Fetched.failed(response.statusCode);
      }
      final type =
          response.headers.contentType?.mimeType ?? 'application/octet-stream';
      await body.writeAsBytes(bytes);
      await meta.writeAsString(type);
      return _Fetched(200, bytes, type);
    } on TimeoutException {
      request?.abort();
      stderr.writeln('upstream timeout: $path');
      return _Fetched.failed(504);
    } on IOException catch (e) {
      stderr.writeln('upstream unreachable: $path ($e)');
      return _Fetched.failed(502);
    }
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

class _Fetched {
  _Fetched(this.status, this.bytes, this.contentType);
  _Fetched.failed(this.status)
      : bytes = const [],
        contentType = '';

  final int status;
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
