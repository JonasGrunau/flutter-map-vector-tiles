import 'dart:typed_data';

import 'package:flutter/material.dart' hide Theme;
import 'package:flutter/rendering.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_vector_tiles/flutter_map_vector_tiles.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'mvt_builder.dart';

const extent = 4096;

/// Distinctive colours so a rendered pixel says exactly which stage of
/// the pipeline produced it.
const land = Color(0xffff0000); // the tile's fill
const background = Color(0xff0000ff); // the style background

/// One tile whose single polygon covers the whole tile.
Uint8List fullTile() => MvtTileBuilder()
    .layer('land', extent: extent)
    .feature(type: 3, geometry: [
      cmd(1, 1), zig(0), zig(0), //
      cmd(2, 3), zig(extent), zig(0), zig(0), zig(extent), zig(-extent),
      zig(0),
      cmd(7, 1),
    ])
    .done()
    .build();

/// The bookkeeping every test provider shares: what the layer asked
/// for, when it last asked, and whether it ever asked twice.
///
/// Subclasses call [note] at the top of their `load`.
abstract class CountingProvider extends VectorTileProvider {
  var loads = 0;

  /// The distinct keys served, which is also the number of entries this
  /// provider is worth on disk — one file per key. Tests that depend on a
  /// warm disk wait for the cache to catch up with this.
  final served = <TileKey>{};

  /// Wall-clock time of the most recent load, which is how [settleLoads]
  /// tells that the grid has gone quiet.
  DateTime lastLoadAt = DateTime.now();

  /// The longest this provider has ever gone between two loads. Reported
  /// when a wait for quiet gives up, so a quiet window that was simply
  /// too short is recognisable as one.
  Duration longestGap = Duration.zero;

  /// Keys fetched a second time.
  ///
  /// This, not [loads], is what a "must reuse what it already has" test
  /// should assert on. A grid goes on filling in its buffer ring long
  /// after the tile under the centre has painted, so a [loads] snapshot
  /// taken between two phases of a test attributes those late arrivals
  /// to the wrong phase — the busier the machine, the more of them.
  /// Re-fetching a key is unambiguous whenever it happens.
  var reloads = 0;

  @override
  int get maximumZoom => 20;
  @override
  int get minimumZoom => 0;

  void note(TileKey tile) {
    loads++;
    final now = DateTime.now();
    final gap = now.difference(lastLoadAt);
    if (gap > longestGap) longestGap = gap;
    lastLoadAt = now;
    if (!served.add(tile)) reloads++;
  }
}

/// Serves the same tile for every coordinate, so tests never depend on
/// which tiles the grid happens to ask for.
class EverywhereProvider extends CountingProvider {
  final Uint8List bytes;

  EverywhereProvider(this.bytes);

  @override
  String get cacheKey => 'everywhere';

  @override
  Future<TileResponse> load(TileKey tile,
      {CancellationToken? cancellation}) async {
    note(tile);
    return TileResponseData(bytes);
  }
}

Theme landTheme() => const ThemeReader().read({
      'layers': [
        {
          'id': 'bg',
          'type': 'background',
          'paint': {'background-color': '#0000ff'},
        },
        {
          'id': 'land',
          'type': 'fill',
          'source': 's',
          'source-layer': 'land',
          'paint': {'fill-color': '#ff0000'},
        },
      ],
    });

const boundaryKey = ValueKey('map-boundary');

Widget app(
  MapController controller,
  VectorTileProvider provider, {
  Future<String> Function()? cachePath,
}) =>
    MaterialApp(
      home: RepaintBoundary(
        key: boundaryKey,
        child: FlutterMap(
          mapController: controller,
          options: const MapOptions(
            initialCenter: LatLng(48.1725, 11.7375),
            initialZoom: 14,
          ),
          children: [
            VectorTileLayer(
              theme: landTheme(),
              tileProviders: TileProviders({'s': provider}),
              // Style zoom == display zoom keeps the test arithmetic plain.
              tileOffset: TileOffset.none,
              // Instant fades: fade progress is driven by the wall clock,
              // which `pump` does not advance.
              tileFadeDuration: Duration.zero,
              concurrency: 1,
              cachePath: cachePath,
              diskCacheMaximumSizeInBytes: cachePath == null ? 0 : 1024 * 1024,
            ),
          ],
        ),
      ),
    );

typedef _Pixel = ({int r, int g, int b, int a});

/// Components at fractional positions of the rendered map, all read from
/// a single snapshot.
///
/// `toByteData` is genuinely asynchronous, so the read has to happen
/// inside [WidgetTester.runAsync] — awaiting it in the fake-async zone
/// deadlocks.
Future<List<_Pixel>> _pixels(
  WidgetTester tester,
  List<(double, double)> at,
) async {
  final boundary =
      tester.renderObject<RenderRepaintBoundary>(find.byKey(boundaryKey));
  final image = boundary.toImageSync();
  final read = await tester.runAsync(() async {
    final data = (await image.toByteData())!;
    final w = image.width, h = image.height;
    final pixels = <_Pixel>[];
    for (final (fx, fy) in at) {
      final x = (w * fx).floor().clamp(0, w - 1);
      final y = (h * fy).floor().clamp(0, h - 1);
      final i = (y * w + x) * 4;
      pixels.add((
        r: data.getUint8(i),
        g: data.getUint8(i + 1),
        b: data.getUint8(i + 2),
        a: data.getUint8(i + 3),
      ));
    }
    return pixels;
  });
  image.dispose();
  return read!;
}

/// Colour at the centre of the rendered map.
Future<Color> centrePixel(WidgetTester tester) async {
  final p = (await _pixels(tester, const [(0.5, 0.5)])).single;
  return Color.fromARGB(p.a, p.r, p.g, p.b);
}

/// Whether the *whole* screenful has painted its tiles, not just the
/// middle of it — the difference between one tile having arrived and the
/// grid being complete.
///
/// Sampled on a lattice inset from the edges, and against "no longer the
/// blue background" rather than an exact [land] match: a hairline seam
/// between two tile rasters can blend, and a blend of two painted tiles
/// still means both painted.
Future<bool> fullyPainted(WidgetTester tester) async {
  const fractions = [0.1, 0.3, 0.5, 0.7, 0.9];
  final pixels = await _pixels(tester, [
    for (final fy in fractions)
      for (final fx in fractions) (fx, fy),
  ]);
  return pixels.every((p) => p.r > p.b);
}

/// Pumps frames — letting the decode isolates and disk IO make real
/// progress in between — until [ready] holds. Returns whether it did.
///
/// The budget is wall-clock rather than a frame count on purpose. The
/// work being waited on runs outside the fake clock, so a fixed number
/// of pumps is a *shorter* deadline the busier the machine is, which is
/// exactly how these tests used to flake under a parallel suite.
///
/// Always pumps before the first check: callers reach here right after
/// asking for something (a [MapController.move], a rebuild) that has not
/// been through a frame yet, and checking first would answer about the
/// screen they were trying to leave.
Future<bool> pumpUntil(
  WidgetTester tester,
  Future<bool> Function() ready, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (true) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    if (await ready()) return true;
    if (!DateTime.now().isBefore(deadline)) return false;
  }
}

/// Pumps until the map has painted the tile under its centre.
Future<bool> settle(WidgetTester tester) =>
    pumpUntil(tester, () async => (await centrePixel(tester)) == land);

/// Pumps until the whole grid has painted *and* [provider] has gone
/// [quiet] without a new request — the layer has fetched everything this
/// screenful needs, buffer ring included.
///
/// [settle] is not enough before a phase that compares what the *next*
/// phase fetches: it returns as soon as the tile under the centre
/// paints, leaving the rest of the grid in flight. A tile still in
/// flight when the layer rebuilds is legitimately requested again, which
/// then reads as the rebuild having refetched an already-loaded tile —
/// on a loaded machine, for a dozen tiles at once.
///
/// Quiet is wall-clock rather than a number of frames because the gap it
/// has to outlast is one tile's decode, which stretches with the
/// machine's load exactly as a frame budget does not.
/// Set [painted] false when the tiles are not expected to paint at all —
/// during a simulated outage nothing but the background ever appears.
Future<void> settleLoads(
  WidgetTester tester,
  CountingProvider provider, {
  Duration quiet = const Duration(seconds: 1),
  bool painted = true,
}) async {
  final settled = await pumpUntil(
    tester,
    () async =>
        DateTime.now().difference(provider.lastLoadAt) >= quiet &&
        (!painted || await fullyPainted(tester)),
    timeout: const Duration(seconds: 60),
  );
  if (!settled) {
    fail('the grid never went quiet: ${provider.loads} loads, longest gap '
        'between two of them ${provider.longestGap.inMilliseconds}ms, '
        'against a ${quiet.inMilliseconds}ms quiet window');
  }
}

/// Samples the centre pixel over [frames] pumped frames and returns
/// every distinct colour seen.
Future<Set<Color>> sampleDuring(
  WidgetTester tester, {
  required int frames,
}) async {
  final seen = <Color>{};
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    seen.add(await centrePixel(tester));
  }
  return seen;
}
