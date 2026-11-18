import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart' hide Theme;
import 'package:flutter/rendering.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_vector_tiles/flutter_map_vector_tiles.dart';
import 'package:flutter_map_vector_tiles/src/render/extrusion_painter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'fixtures/lifecycle_harness.dart';
import 'fixtures/mvt_builder.dart';

// Zoom 16 around (0, 0) with `TileOffset.none`: tile (16, 32768, 32768)
// has its top-left corner at the screen centre, 16 extent units to the
// pixel. 0.4191 px a metre on the equator; the camera 1.5 · 512 = 768 px
// up. A 200 m roof is lifted 83.8 px, which scales it by 1.1226 about
// the screen centre.
const _zoom = 16.0;
const _key = TileKey(16, 32768, 32768);

/// The tile below [_key], under the same parent.
const _below = TileKey(16, 32768, 32769);
const _size = 512;
const _mid = _size ~/ 2;

/// One building, 100..130 px right of the centre and 50..80 px below
/// it, `height` 200: its roof lands at 112..146 × 56..90.
///
/// With [road], also a road (id 9) running from the screen centre 200
/// px right, 85 px below it: across the roof where it leans past the
/// footprint, and across open ground on either side.
Uint8List _buildingTile({bool road = false}) {
  final builder = MvtTileBuilder()
      .layer('building', extent: extent)
      .feature(type: 3, id: 7, properties: {
    'height': 200,
  }, geometry: [
    cmd(1, 1), zig(1600), zig(800), //
    cmd(2, 3), zig(480), zig(0), zig(0), zig(480), zig(-480), zig(0),
    cmd(7, 1),
  ]).done();
  if (road) {
    builder.layer('road', extent: extent).feature(type: 2, id: 9, geometry: [
      cmd(1, 1), zig(0), zig(1360), //
      cmd(2, 1), zig(3200), zig(0),
    ]).done();
  }
  return builder.build();
}

class _OneTile extends CountingProvider {
  _OneTile({this.road = false});

  final bool road;

  @override
  String get cacheKey =>
      road ? 'extrusion-one-tile-road' : 'extrusion-one-tile';

  @override
  Future<TileResponse> load(TileKey tile,
      {CancellationToken? cancellation}) async {
    note(tile);
    return tile == _key
        ? TileResponseData(_buildingTile(road: road))
        : TileResponseData(
            MvtTileBuilder().layer('building', extent: extent).done().build());
  }
}

/// [_buildingTile]'s building as the tile at [level] holds it — z15's
/// at half the coordinates — without an id, and with a `level` telling
/// the two copies apart.
Uint8List _levelTile(int level) {
  final s = level == 16 ? 1 : 2;
  return MvtTileBuilder()
      .layer('building', extent: extent)
      .feature(type: 3, properties: {
        'height': 200,
        'level': 'z$level',
      }, geometry: [
        cmd(1, 1), zig(1600 ~/ s), zig(800 ~/ s), //
        cmd(2, 3), zig(480 ~/ s), zig(0), zig(0), zig(480 ~/ s),
        zig(-480 ~/ s), zig(0),
        cmd(7, 1),
      ])
      .done()
      .build();
}

/// The building on [_key] and on its parent; every other tile empty,
/// and the z16 ones left of the centre held until [release].
class _ZoomingIn extends CountingProvider {
  _ZoomingIn({bool Function(TileKey tile)? holds})
      : holds = holds ?? ((tile) => tile.z == 16 && tile.x < _key.x);

  /// The tiles held until [release].
  final bool Function(TileKey tile) holds;

  final _held = Completer<void>();

  void release() {
    if (!_held.isCompleted) _held.complete();
  }

  @override
  String get cacheKey => 'extrusion-zooming-in';

  @override
  int get maximumZoom => 16;

  @override
  Future<TileResponse> load(TileKey tile,
      {CancellationToken? cancellation}) async {
    note(tile);
    if (tile == _key) return TileResponseData(_levelTile(16));
    if (tile == _key.parent) return TileResponseData(_levelTile(15));
    if (holds(tile)) await _held.future;
    return TileResponseData(
        MvtTileBuilder().layer('building', extent: extent).done().build());
  }
}

/// The building in white over blue, [height] its height; with [road]
/// `'above'` or `'below'`, a 4 px red road layer over or under the
/// building layer; with [hover], red while its feature state has
/// `hover`.
Theme _theme(
    {double opacity = 1,
    String? road,
    Object height = const ['get', 'height'],
    bool hover = false}) {
  const roadLayer = {
    'id': 'road',
    'type': 'line',
    'source': 's',
    'source-layer': 'road',
    'paint': {'line-color': '#ff0000', 'line-width': 4},
  };
  return const ThemeReader().read({
    'layers': [
      {
        'id': 'bg',
        'type': 'background',
        'paint': {'background-color': '#0000ff'},
      },
      if (road == 'below') roadLayer,
      {
        'id': 'b3d',
        'type': 'fill-extrusion',
        'source': 's',
        'source-layer': 'building',
        'paint': {
          'fill-extrusion-color': hover
              ? [
                  'case',
                  [
                    'boolean',
                    ['feature-state', 'hover'],
                    false
                  ],
                  '#ff0000',
                  '#ffffff',
                ]
              : '#ffffff',
          'fill-extrusion-height': height,
          'fill-extrusion-opacity': opacity,
        },
      },
      if (road == 'above') roadLayer,
    ],
  });
}

Widget _app(
  VectorTileProvider provider, {
  Theme? theme,
  ExtrusionMode extrusionMode = ExtrusionMode.perspective,
  LabelMode labelMode = LabelMode.screen,
  VectorTileLayerController? controller,
  MapController? mapController,
  double zoom = _zoom,
  double rotation = 0,
  int concurrency = 1,
  bool retainAllProperties = false,
}) =>
    MaterialApp(
      home: RepaintBoundary(
        key: boundaryKey,
        child: FlutterMap(
          mapController: mapController,
          options: MapOptions(
            initialCenter: const LatLng(0, 0),
            initialZoom: zoom,
            initialRotation: rotation,
          ),
          children: [
            VectorTileLayer(
              theme: theme ?? _theme(),
              tileProviders: TileProviders({'s': provider}),
              tileOffset: TileOffset.none,
              tileFadeDuration: Duration.zero,
              concurrency: concurrency,
              diskCacheMaximumSizeInBytes: 0,
              extrusionMode: extrusionMode,
              labelMode: labelMode,
              controller: controller,
              retainAllProperties: retainAllProperties,
            ),
          ],
        ),
      ),
    );

Future<Uint8List> _shot(WidgetTester tester) async {
  final boundary =
      tester.renderObject<RenderRepaintBoundary>(find.byKey(boundaryKey));
  final image = boundary.toImageSync();
  final data = await tester.runAsync(() => image.toByteData());
  image.dispose();
  return data!.buffer.asUint8List();
}

(int, int, int) _rgb(Uint8List px, int dx, int dy) {
  final i = ((_mid + dy) * _size + _mid + dx) * 4;
  return (px[i], px[i + 1], px[i + 2]);
}

bool _blue((int, int, int) c) => c.$1 < 30 && c.$2 < 30 && c.$3 > 220;
bool _red((int, int, int) c) => c.$1 > 220 && c.$2 < 30 && c.$3 < 30;
bool _white((int, int, int) c) => c.$1 > 245 && c.$2 > 245 && c.$3 > 245;

/// A shaded wall: grey, well below the roof's white.
bool _wall((int, int, int) c) =>
    c.$1 > 60 && c.$1 < 200 && c.$1 == c.$2 && c.$2 == c.$3;

void main() {
  setUp(VectorTileLayer.clearMemoryCache);

  Future<Uint8List> open(
      WidgetTester tester, Widget app, bool Function(Uint8List) ready) async {
    tester.view.physicalSize = const Size(512, 512);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app);
    expect(
        await pumpUntil(tester, () async => ready(await _shot(tester))), isTrue,
        reason: 'the building never appeared');
    return _shot(tester);
  }

  testWidgets('a building leans away from the centre, its near wall showing',
      (tester) async {
    final px =
        await open(tester, _app(_OneTile()), (px) => _white(_rgb(px, 140, 85)));
    // The roof, past the footprint.
    expect(_white(_rgb(px, 140, 85)), isTrue);
    expect(_white(_rgb(px, 120, 70)), isTrue);
    // The wall facing the centre, between foot and roof edge...
    expect(_wall(_rgb(px, 105, 70)), isTrue, reason: '${_rgb(px, 105, 70)}');
    // ...and the one above it, turned away from the light: darker.
    expect(_wall(_rgb(px, 120, 53)), isTrue, reason: '${_rgb(px, 120, 53)}');
    expect(_rgb(px, 120, 53).$1, lessThan(_rgb(px, 105, 70).$1));
    // Ground on the centre's side of the foot, and past the roof.
    expect(_blue(_rgb(px, 95, 70)), isTrue);
    expect(_blue(_rgb(px, 120, 47)), isTrue);
    expect(_blue(_rgb(px, 150, 70)), isTrue);
    expect(ExtrusionPainter.debugFrames, greaterThan(0));
    await tester.pumpWidget(const SizedBox());
  });

  for (final (name, height) in <(String, Object)>[
    // A property the building does not have, as for most of OSM's.
    ('without a height', const ['get', 'render_height']),
    (
      'rising only from zoom 17',
      const [
        'interpolate',
        ['linear'],
        ['zoom'],
        17,
        0,
        18,
        200
      ]
    ),
  ]) {
    testWidgets('a building of height 0 draws its roof on the ground: $name',
        (tester) async {
      // As in MapLibre, which draws the roof whatever its height.
      final px = await open(
          tester,
          _app(_OneTile(), theme: _theme(height: height)),
          (px) => _white(_rgb(px, 115, 65)));
      // The footprint, and no lean: ground just past it either side.
      expect(_white(_rgb(px, 105, 55)), isTrue);
      expect(_white(_rgb(px, 125, 75)), isTrue);
      expect(_blue(_rgb(px, 95, 65)), isTrue);
      expect(_blue(_rgb(px, 140, 85)), isTrue);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('flat: the footprint in the tile image, no lean', (tester) async {
    final px = await open(
        tester,
        _app(_OneTile(), extrusionMode: ExtrusionMode.flat),
        (px) => _white(_rgb(px, 105, 70)));
    expect(_white(_rgb(px, 105, 70)), isTrue);
    expect(_blue(_rgb(px, 140, 85)), isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  test('3D buildings are opt-in: a layer left at its defaults draws flat', () {
    // An update must not change how an app's existing style looks.
    expect(
        VectorTileLayer(
          theme: _theme(),
          tileProviders: TileProviders({'s': _OneTile()}),
        ).extrusionMode,
        ExtrusionMode.flat);
  });

  testWidgets('LabelMode.tile draws them flat', (tester) async {
    final px = await open(tester, _app(_OneTile(), labelMode: LabelMode.tile),
        (px) => _white(_rgb(px, 105, 70)));
    expect(_blue(_rgb(px, 140, 85)), isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('drawn flat, a building keeps no property only its height reads',
      (tester) async {
    final controller = VectorTileLayerController();
    await open(
        tester,
        _app(_OneTile(),
            extrusionMode: ExtrusionMode.flat, controller: controller),
        (px) => _white(_rgb(px, 115, 65)));
    final building = controller
        .queryRenderedFeatures(const Offset(_mid + 115.5, _mid + 65.5))
        .single;
    expect(building.id, 7);
    expect(building.properties, isNot(contains('height')));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('in 3D, a building keeps the properties its height reads',
      (tester) async {
    final controller = VectorTileLayerController();
    await open(tester, _app(_OneTile(), controller: controller),
        (px) => _white(_rgb(px, 140, 85)));
    final building = controller
        .queryRenderedFeatures(const Offset(_mid + 140.5, _mid + 85.5))
        .single;
    expect(building.id, 7);
    expect(building.properties['height'], 200);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('opacity composites the building once, not face by face',
      (tester) async {
    final px = await open(tester, _app(_OneTile(), theme: _theme(opacity: 0.5)),
        (px) => _rgb(px, 140, 85).$1 > 100);
    // Half white over blue, the roof and the wall beneath it alike.
    final roof = _rgb(px, 120, 70);
    expect(roof.$1, closeTo(128, 3));
    expect(roof.$3, closeTo(255, 3));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the lean is radial: it turns with the screen, not the map',
      (tester) async {
    // A quarter turn clockwise puts the building below-left of the
    // centre on screen; its roof still leans away from the centre.
    final px = await open(tester, _app(_OneTile(), rotation: 90),
        (px) => _white(_rgb(px, -85, 140)));
    expect(_white(_rgb(px, -85, 140)), isTrue);
    expect(_blue(_rgb(px, -45, 99)), isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a layer above the 3D one draws over the buildings',
      (tester) async {
    // As in MapLibre: everything the style puts above its first 3D
    // layer is drawn over the buildings, roofs included.
    final controller = VectorTileLayerController();
    final px = await open(
        tester,
        _app(_OneTile(road: true),
            theme: _theme(road: 'above'), controller: controller),
        (px) => _white(_rgb(px, 120, 70)) && _red(_rgb(px, 140, 85)));
    expect(_red(_rgb(px, 140, 85)), isTrue, reason: 'over the roof');
    expect(_red(_rgb(px, 60, 85)), isTrue, reason: 'over the ground');
    expect(_white(_rgb(px, 140, 75)), isTrue, reason: 'the roof beside it');
    // And a query names it first, the building it lies on after it.
    expect([
      for (final f in controller
          .queryRenderedFeatures(const Offset(_mid + 140.5, _mid + 85.5)))
        f.id,
    ], [
      9,
      7
    ]);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a layer below the 3D one goes under the buildings',
      (tester) async {
    final controller = VectorTileLayerController();
    final px = await open(
        tester,
        _app(_OneTile(road: true),
            theme: _theme(road: 'below'), controller: controller),
        (px) => _white(_rgb(px, 140, 85)) && _red(_rgb(px, 60, 85)));
    expect(_white(_rgb(px, 140, 85)), isTrue, reason: 'covered by the roof');
    expect(_red(_rgb(px, 60, 85)), isTrue, reason: 'on the ground');
    expect([
      for (final f in controller
          .queryRenderedFeatures(const Offset(_mid + 140.5, _mid + 85.5)))
        f.id,
    ], [
      7,
      9
    ]);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a tap finds the building where it is drawn', (tester) async {
    final controller = VectorTileLayerController();
    await open(tester, _app(_OneTile(), controller: controller),
        (px) => _white(_rgb(px, 140, 85)));
    List<Object?> idsAt(int dx, int dy) => [
          for (final f in controller
              .queryRenderedFeatures(Offset(_mid + dx + 0.5, _mid + dy + 0.5)))
            f.id,
        ];
    expect(idsAt(140, 85), [7], reason: 'the roof, beyond the footprint');
    expect(idsAt(105, 70), [7], reason: 'the near wall');
    expect(idsAt(95, 70), isEmpty);
    expect(idsAt(150, 70), isEmpty);
    // A rectangle reaching the wall from the ground finds it too.
    expect(
        controller
            .queryRenderedFeaturesInRect(
                const Rect.fromLTWH(_mid + 90.0, _mid + 60.0, 12, 4))
            .map((f) => f.id),
        [7]);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'during a zoom-in a tap finds the building once, not its copy on the '
      'level beneath', (tester) async {
    final provider = _ZoomingIn();
    addTearDown(provider.release);
    final controller = VectorTileLayerController();
    final mapController = MapController();
    // At z15 the building's roof covers 53..68 × 27..42.
    await open(
        tester,
        _app(provider,
            zoom: 15,
            controller: controller,
            mapController: mapController,
            // Room for the tiles that arrive past the held ones.
            concurrency: 3,
            retainAllProperties: true),
        (px) => _white(_rgb(px, 57, 32)));
    List<String> levelsAt(Offset p) => [
          for (final f in controller.queryRenderedFeatures(p))
            '${f.properties['level']}',
        ];
    expect(
        await pumpUntil(
            tester,
            () async =>
                levelsAt(const Offset(_mid + 57.5, _mid + 32.5)).isNotEmpty),
        isTrue,
        reason: 'the z15 building never became queryable');
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    // A plain zoom-in: the z16 tiles left of the centre are still
    // loading, so the z15 level stays on beneath; the building's z16
    // tile and its sibling below have arrived, so no current tile draws
    // from the z15 one in their place.
    mapController.move(const LatLng(0, 0), 16);

    // Through the roof at z16.
    const tap = Offset(_mid + 115.5, _mid + 65.5);
    expect(
        await pumpUntil(
            tester,
            () async =>
                VectorTileLayer.debugRetainedTileCount > 0 &&
                levelsAt(tap).contains('z16'),
            timeout: const Duration(seconds: 10)),
        isTrue,
        reason: 'the z16 building never arrived while z15 was retained: '
            'retained ${VectorTileLayer.debugRetainedTileCount}, '
            'at the tap ${levelsAt(tap)}');
    // The z15 copy lies in a cell the arrived z16 tile covers: the
    // painter's skip mask leaves it out, so a query must too.
    expect(levelsAt(tap), ['z16']);
    provider.release();
    await tester.pumpWidget(const SizedBox());
    // The loads let through finish after the map is gone; on the web
    // their preparation yields through a timer, which must run before
    // the test ends.
    await tester.pump(const Duration(milliseconds: 16));
  });

  testWidgets(
      'during a zoom-in a tile drawn from its parent leaves out what its '
      'arrived siblings draw', (tester) async {
    // The tile below the building's is held: until it arrives it is
    // drawn from their common parent, whose copy of the building lies
    // in the cell of the building's own tile, which has arrived.
    final provider = _ZoomingIn(holds: (tile) => tile == _below);
    addTearDown(provider.release);
    final controller = VectorTileLayerController();
    final mapController = MapController();
    await open(
        tester,
        _app(provider,
            zoom: 15,
            controller: controller,
            mapController: mapController,
            concurrency: 3,
            retainAllProperties: true),
        (px) => _white(_rgb(px, 57, 32)));
    List<String> levelsAt(Offset p) => [
          for (final f in controller.queryRenderedFeatures(p))
            '${f.properties['level']}',
        ];
    mapController.move(const LatLng(0, 0), 16);
    const tap = Offset(_mid + 115.5, _mid + 65.5);
    expect(
        await pumpUntil(tester, () async => levelsAt(tap).contains('z16'),
            timeout: const Duration(seconds: 10)),
        isTrue,
        reason: 'the z16 building never arrived: at the tap ${levelsAt(tap)}');
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(levelsAt(tap), ['z16']);
    provider.release();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 16));
  });

  testWidgets(
      'a feature-state change lays out again only the tiles holding the '
      'feature', (tester) async {
    final controller = VectorTileLayerController();
    await open(
        tester,
        _app(_OneTile(), theme: _theme(hover: true), controller: controller),
        (px) => _white(_rgb(px, 140, 85)));
    // Until a stretch of frames sorts nothing.
    var last = -1;
    var still = 0;
    expect(
        await pumpUntil(tester, () async {
          final now = ExtrusionPainter.debugRebuilds;
          still = now == last ? still + 1 : 0;
          last = now;
          return still >= 20;
        }),
        isTrue,
        reason: 'the buildings never stopped sorting');
    final sorts = ExtrusionPainter.debugRebuilds;
    for (var i = 0; i < 20; i++) {
      controller.setFeatureState(
          source: 's',
          sourceLayer: 'building',
          id: 99999, // on no tile at all
          state: {'hover': i.isEven});
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(ExtrusionPainter.debugRebuilds, sorts,
        reason: 'a state no building reads moved nothing on screen');
    // The building's own state does reach it.
    controller.setFeatureState(
        source: 's', sourceLayer: 'building', id: 7, state: {'hover': true});
    expect(
        await pumpUntil(
            tester, () async => _red(_rgb(await _shot(tester), 140, 85))),
        isTrue,
        reason: 'the hovered roof never turned red');
    await tester.pumpWidget(const SizedBox());
  });
}
