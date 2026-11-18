@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart' hide Theme;
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_vector_tiles/flutter_map_vector_tiles.dart';
import 'package:flutter_map_vector_tiles/src/cache/disk_cache.dart';
import 'package:flutter_map_vector_tiles/src/render/extrusion_painter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'fixtures/lifecycle_harness.dart';
import 'fixtures/mvt_builder.dart';

// 3D buildings across a map closed and opened again: tiles coming back
// from the result cache next to tiles laid out anew, and tiles served
// stale from disk and then refreshed.

/// A white `fill-extrusion` layer over blue, read afresh on every call —
/// what an app that reads its style when the map page opens gets on
/// every open.
Theme _buildingsTheme() => const ThemeReader().read({
      'id': 'buildings',
      'layers': [
        {
          'id': 'bg',
          'type': 'background',
          'paint': {'background-color': '#0000ff'},
        },
        {
          'id': 'b3d',
          'type': 'fill-extrusion',
          'source': 's',
          'source-layer': 'building',
          'paint': {
            'fill-extrusion-color': '#ffffff',
            'fill-extrusion-height': ['get', 'height'],
          },
        },
      ],
    });

// Display zoom 16, `TileOffset.none`, data tiles only up to z15: the
// four display tiles (16, 32768..32769, 32768..32769) all overzoom the
// one data tile [_data]. It holds one building near its centre.
const _data = TileKey(15, 16384, 16384);

class _OneDataTile extends CountingProvider {
  @override
  String get cacheKey => 'extrusion-cache-reopen';

  @override
  int get maximumZoom => 15;

  @override
  Future<TileResponse> load(TileKey tile,
      {CancellationToken? cancellation}) async {
    note(tile);
    final layer = MvtTileBuilder().layer('building', extent: 4096);
    if (tile == _data) {
      layer.feature(type: 3, id: 7, properties: {
        'height': 200,
      }, geometry: [
        cmd(1, 1), zig(2848), zig(2448), //
        cmd(2, 3), zig(480), zig(0), zig(0), zig(480), zig(-480), zig(0),
        cmd(7, 1),
      ]);
    }
    return TileResponseData(layer.done().build());
  }
}

double _sinh(double x) => (math.exp(x) - math.exp(-x)) / 2;

/// A display tile up and left of [_data]'s top-left corner: the grid
/// there, buffer ring included, reaches only [_data]'s top-left display
/// tile.
final _corner = LatLng(
  math.atan(_sinh(2 * math.pi / 65536)) * 180 / math.pi,
  -360 / 65536,
);

/// [_data]'s centre.
final _centre = LatLng(
  -math.atan(_sinh(2 * math.pi / 65536)) * 180 / math.pi,
  360 / 65536,
);

Widget _reopenApp(VectorTileProvider provider, Theme theme, LatLng center) =>
    MaterialApp(
      home: RepaintBoundary(
        key: boundaryKey,
        child: FlutterMap(
          options: MapOptions(initialCenter: center, initialZoom: 16),
          children: [
            VectorTileLayer(
              theme: theme,
              tileProviders: TileProviders({'s': provider}),
              tileOffset: TileOffset.none,
              tileFadeDuration: Duration.zero,
              concurrency: 1,
              diskCacheMaximumSizeInBytes: 0,
              extrusionMode: ExtrusionMode.perspective,
            ),
          ],
        ),
      ),
    );

/// Opens a map over [theme] at [center], lets the grid go quiet, and
/// returns the most vertices the extrusion painter built in a frame.
Future<int> _open(WidgetTester tester, _OneDataTile provider, Theme theme,
    LatLng center) async {
  ExtrusionPainter.debugFrameVertices = [];
  await tester.pumpWidget(_reopenApp(provider, theme, center));
  await settleLoads(tester, provider, painted: false);
  // A few more frames for the last publishes to reach the painter.
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
  }
  final frames = ExtrusionPainter.debugFrameVertices!;
  ExtrusionPainter.debugFrameVertices = null;
  return frames.isEmpty ? 0 : frames.reduce(math.max);
}

/// Opens a map over part of [_data]'s display tiles, closes it, and
/// opens it again over all four — with the style read again when
/// [rereadStyle]. Returns the most vertices a frame of the second map
/// built.
Future<int> _reopen(WidgetTester tester, {required bool rereadStyle}) async {
  tester.view.physicalSize = const Size(512, 512);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final provider = _OneDataTile();
  final first = _buildingsTheme();
  await _open(tester, provider, first, _corner);
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
  // The display tile the first map finished comes from the result
  // cache; the other three are laid out anew.
  final vertices = await _open(
      tester, provider, rereadStyle ? _buildingsTheme() : first, _centre);
  await tester.pumpWidget(const SizedBox());
  return vertices;
}

/// A full-tile polygon in [layer], with [properties].
MvtTileBuilder _full(MvtTileBuilder b, String layer,
        [Map<String, Object?> properties = const {}]) =>
    b
        .layer(layer, extent: extent)
        .feature(type: 3, properties: properties, geometry: [
      cmd(1, 1), zig(0), zig(0), //
      cmd(2, 3), zig(extent), zig(0), zig(0), zig(extent), zig(-extent),
      zig(0),
      cmd(7, 1),
    ]).done();

/// Before the refresh: yellow ground under the 3D layer, a green fill
/// over it.
Uint8List _before() => _full(_full(MvtTileBuilder(), 'ground'), 'top').build();

/// After the refresh, nothing: the background alone, so the tile has no
/// image over its buildings.
Uint8List _afterEmpty() =>
    MvtTileBuilder().layer('other', extent: extent).done().build();

/// After the refresh, the fill over the 3D layer red and the ground
/// gone: the tile still has an image over its buildings.
Uint8List _afterRed() => _full(MvtTileBuilder(), 'top', {'c': 1}).build();

class _Refreshing extends CountingProvider {
  _Refreshing(this.bytes, {this.gate});

  final Uint8List bytes;
  final Future<void>? gate;

  @override
  String get cacheKey => 'extrusion-cache-refresh';

  @override
  Future<TileResponse> load(TileKey tile,
      {CancellationToken? cancellation}) async {
    note(tile);
    if (gate != null) await gate;
    return TileResponseData(bytes);
  }
}

Theme _overTheme() => const ThemeReader().read({
      'layers': [
        {
          'id': 'bg',
          'type': 'background',
          'paint': {'background-color': '#0000ff'},
        },
        {
          'id': 'ground',
          'type': 'fill',
          'source': 's',
          'source-layer': 'ground',
          'paint': {'fill-color': '#ffff00'},
        },
        {
          'id': 'b3d',
          'type': 'fill-extrusion',
          'source': 's',
          'source-layer': 'building',
          'paint': {'fill-extrusion-color': '#ffffff'},
        },
        {
          'id': 'top',
          'type': 'fill',
          'source': 's',
          'source-layer': 'top',
          'paint': {
            'fill-color': [
              'case',
              [
                '==',
                ['get', 'c'],
                1
              ],
              '#ff0000',
              '#00ff00'
            ],
          },
        },
      ],
    });

Widget _refreshApp(VectorTileProvider provider, String dir) => MaterialApp(
      home: RepaintBoundary(
        key: boundaryKey,
        child: FlutterMap(
          options: const MapOptions(
            initialCenter: LatLng(48.1725, 11.7375),
            initialZoom: 14,
          ),
          children: [
            VectorTileLayer(
              theme: _overTheme(),
              tileProviders: TileProviders({'s': provider}),
              tileOffset: TileOffset.none,
              tileFadeDuration: const Duration(seconds: 2),
              concurrency: 1,
              cachePath: () async => dir,
              diskCacheMaximumSizeInBytes: 1024 * 1024,
              // Everything on disk is expired at once: a reopened map
              // serves it stale and revalidates in the background.
              diskCacheTtl: Duration.zero,
              extrusionMode: ExtrusionMode.perspective,
            ),
          ],
        ),
      ),
    );

bool _isGreen(Color c) => c.r < 0.1 && c.g > 0.95 && c.b < 0.1;

/// Paints [_before], reopens the map on the expired disk cache with a
/// provider that answers [after] once released, and returns the centre
/// pixel on the first frame after it changed from green.
Future<Color> _firstFrameAfterRefresh(
    WidgetTester tester, Uint8List after) async {
  final dir = Directory.systemTemp.createTempSync('fmvt_extrusion_cache');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  tester.view.physicalSize = const Size(600, 600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final first = _Refreshing(_before());
  await tester.pumpWidget(_refreshApp(first, dir.path));
  await settleLoads(tester, first, painted: false);
  expect(
      await pumpUntil(tester, () async => _isGreen(await centrePixel(tester))),
      isTrue,
      reason: 'the tiles never painted');
  expect(
      await pumpUntil(tester, () async {
        final n = dir
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.bin'))
            .length;
        return n == first.served.length;
      }),
      isTrue,
      reason: 'the tiles never reached the disk cache');
  await tester.pumpWidget(const SizedBox());
  await tester.pump();

  VectorTileLayer.clearMemoryCache();
  DiskCacheRegistry.reset();
  final gate = Completer<void>();
  final second = _Refreshing(after, gate: gate.future);
  await tester.pumpWidget(_refreshApp(second, dir.path));
  // The stale entries paint, green, their own fade-in finished.
  expect(
      await pumpUntil(tester, () async => _isGreen(await centrePixel(tester))),
      isTrue,
      reason: 'the stale entries never painted');
  // The revalidations are parked on the gate; let them through.
  gate.complete();
  late Color changed;
  expect(
      await pumpUntil(tester, () async {
        changed = await centrePixel(tester);
        return !_isGreen(changed);
      }),
      isTrue,
      reason: 'the refresh never landed');
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
  return changed;
}

void main() {
  setUp(() {
    VectorTileLayer.clearMemoryCache();
    DiskCacheRegistry.reset();
  });

  testWidgets(
      'reopened over a style read again, a map draws each building once',
      (tester) async {
    addTearDown(() => ExtrusionPainter.debugFrameVertices = null);
    final sameTheme = await _reopen(tester, rereadStyle: false);
    expect(sameTheme, greaterThan(0));
    VectorTileLayer.clearMemoryCache();
    // The cached display tile brings layouts bound to the first
    // reading's layer objects, the new ones over the same data tile
    // layouts bound to the second's: still the one building.
    final reread = await _reopen(tester, rereadStyle: true);
    expect(reread, sameTheme);
  });

  testWidgets("a revalidated tile's new over image fades in over the old",
      (tester) async {
    final c = await _firstFrameAfterRefresh(tester, _afterRed());
    // The old green at full beneath, the red fading in: mostly green.
    expect(c.g, greaterThan(0.5), reason: 'pixel $c');
  });

  testWidgets(
      'an over image a revalidated tile no longer has fades out, not pops',
      (tester) async {
    final c = await _firstFrameAfterRefresh(tester, _afterEmpty());
    // As for the base image: at the start of the fade the old over
    // image, green, still covers the tile. Gone at once, it would show
    // the old base, yellow, beneath.
    expect(c.g > 0.5 && c.r < 0.5, isTrue,
        reason: 'first frame after the refresh: $c');
  });
}
