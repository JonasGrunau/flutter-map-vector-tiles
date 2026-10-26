import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide Theme;
import 'package:flutter/rendering.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_vector_tiles/flutter_map_vector_tiles.dart';
import 'package:flutter_map_vector_tiles/src/render/label_painter.dart';
import 'package:flutter_map_vector_tiles/src/render/symbol_layouter.dart';
import 'package:flutter_map_vector_tiles/src/render/tile_rasterizer.dart';
import 'package:flutter_map_vector_tiles/src/style/feature_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'fixtures/lifecycle_harness.dart' show boundaryKey, pumpUntil;
import 'fixtures/mvt_builder.dart';

/// The tile under the screen centre and its right-hand neighbour.
const _centre = TileKey(14, 8726, 5686);
const _right = TileKey(14, 8727, 5686);

/// Tile-extent units per logical pixel at the data zoom.
const _px = 16;

const _red = Color(0xffff0000);
const _green = Color(0xff00ff00);
const _yellow = Color(0xffffff00);

/// The 800×600 test screen's centre — the centre of [_centre].
const _mid = Offset(400, 300);

/// Where logical tile pixel (x, y) of [_centre] lands on screen.
Offset _onScreen(double x, double y) => _mid + Offset(x - 128, y - 128);

List<int> _ring(List<(int, int)> points) {
  final out = <int>[cmd(1, 1)];
  var (px, py) = (0, 0);
  for (var i = 0; i < points.length; i++) {
    final (x, y) = points[i];
    if (i == 1) out.add(cmd(2, points.length - 1));
    out
      ..add(zig(x * _px - px))
      ..add(zig(y * _px - py));
    (px, py) = (x * _px, y * _px);
  }
  return out..add(cmd(7, 1));
}

List<int> _box(int x0, int y0, int x1, int y1) =>
    _ring([(x0, y0), (x1, y0), (x1, y1), (x0, y1)]);

List<int> _line(int x0, int y0, int x1, int y1) => [
      cmd(1, 1), zig(x0 * _px), zig(y0 * _px), //
      cmd(2, 1), zig((x1 - x0) * _px), zig((y1 - y0) * _px),
    ];

List<int> _point(int x, int y) => [cmd(1, 1), zig(x * _px), zig(y * _px)];

/// The centre tile: a park (id 1) spilling over the right edge into the
/// buffer, an id-less patch at the seam, a road (id 2) across the top
/// and a café (id 3) with a label.
Uint8List _centreTile() => (MvtTileBuilder()
        .layer('land')
        .feature(
            type: 3,
            geometry: _box(16, 16, 272, 240),
            id: 1,
            properties: {'kind': 'grass', 'name': 'Park', 'osm': 'way/5'})
        .feature(
            type: 3,
            geometry: _box(240, 250, 272, 254),
            properties: {'kind': 'patch'})
        .done()
        .layer('road')
        .feature(
            type: 2,
            geometry: _line(0, 64, 256, 64),
            id: 2,
            properties: {'class': 'primary'})
        .done()
        .layer('poi')
        .feature(
            type: 1,
            geometry: _point(200, 200),
            id: 3,
            properties: {'name': 'Cafe'})
        .done())
    .build();

/// Its right neighbour: the rest of the park and of the patch.
Uint8List _rightTile() => (MvtTileBuilder().layer('land').feature(
            type: 3,
            geometry: _box(-16, 16, 100, 240),
            id: 1,
            properties: {
          'kind': 'grass',
          'name': 'Park',
          'osm': 'way/5'
        }).feature(
            type: 3,
            geometry: _box(-16, 250, 16, 254),
            properties: {'kind': 'patch'}).done())
        .build();

Theme _theme({bool stateLabels = false}) => const ThemeReader().read({
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
          'paint': {
            'fill-antialias': false,
            'fill-color': [
              'case',
              [
                'boolean',
                ['feature-state', 'selected'],
                false
              ],
              '#00ff00',
              [
                'match',
                ['get', 'kind'],
                'grass',
                '#ff0000',
                '#ff00ff',
              ],
            ],
          },
        },
        {
          'id': 'road',
          'type': 'line',
          'source': 's',
          'source-layer': 'road',
          'paint': {'line-color': '#ffff00', 'line-width': 6},
        },
        {
          'id': 'poi',
          'type': 'circle',
          'source': 's',
          'source-layer': 'poi',
          'paint': {'circle-color': '#00ffff', 'circle-radius': 6},
        },
        {
          'id': 'label',
          'type': 'symbol',
          'source': 's',
          'source-layer': 'poi',
          'layout': {'text-field': '{name}', 'text-size': 12},
          'paint': {
            'text-color': stateLabels
                ? [
                    'case',
                    [
                      'boolean',
                      ['feature-state', 'selected'],
                      false
                    ],
                    '#00ff00',
                    '#000000',
                  ]
                : '#000000',
          },
        },
      ],
    });

LatLng _centreOf(TileKey key) {
  final n = math.pow(2, key.z).toDouble();
  final lon = (key.x + 0.5) / n * 360 - 180;
  final y = math.pi * (1 - 2 * (key.y + 0.5) / n);
  final lat = math.atan((math.exp(y) - math.exp(-y)) / 2) * 180 / math.pi;
  return LatLng(lat, lon);
}

void _sizeView(WidgetTester tester) {
  if (tester.view.physicalSize == const Size(800, 600) &&
      tester.view.devicePixelRatio == 1) {
    return;
  }
  tester.view.physicalSize = const Size(800, 600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> _pumpMap(
  WidgetTester tester, {
  required VectorTileLayerController? controller,
  MapController? mapController,
  Theme? theme,
  Map<String, PromoteId> promoteIds = const {},
  LabelMode labelMode = LabelMode.screen,
  bool retainAllProperties = false,
}) async {
  _sizeView(tester);
  final provider = MemoryVectorTileProvider(
    tiles: {_centre: _centreTile(), _right: _rightTile()},
    cacheKey: 'rendered-features-$labelMode-$retainAllProperties-'
        '${promoteIds.isNotEmpty}',
  );
  await tester.pumpWidget(MaterialApp(
    home: RepaintBoundary(
      key: boundaryKey,
      child: FlutterMap(
        mapController: mapController,
        options: MapOptions(
          initialCenter: _centreOf(_centre),
          initialZoom: 14,
        ),
        children: [
          VectorTileLayer(
            controller: controller,
            theme: theme ?? _theme(),
            tileProviders:
                TileProviders({'s': provider}, promoteIds: promoteIds),
            tileOffset: TileOffset.none,
            tileFadeDuration: Duration.zero,
            labelMode: labelMode,
            retainAllProperties: retainAllProperties,
            concurrency: 1,
            diskCacheMaximumSizeInBytes: 0,
          ),
        ],
      ),
    ),
  ));
}

/// Whether [_colorAt] is taking its snapshot — which the leak test
/// ignores, as `label_mode_test.dart` explains.
var _snapshotting = false;

/// Whether the snapshot of the map has [color] at [at].
Future<bool> _colorAt(WidgetTester tester, Offset at, Color color) async {
  final boundary =
      tester.renderObject<RenderRepaintBoundary>(find.byKey(boundaryKey));
  _snapshotting = true;
  final image = boundary.toImageSync();
  _snapshotting = false;
  final data = await tester.runAsync(() async => (await image.toByteData())!);
  final i = (at.dy.floor() * image.width + at.dx.floor()) * 4;
  _snapshotting = true;
  image.dispose();
  _snapshotting = false;
  return data!.getUint8(i) == (color.r * 255).round() &&
      data.getUint8(i + 1) == (color.g * 255).round() &&
      data.getUint8(i + 2) == (color.b * 255).round();
}

/// Pumps until the park, the road and — when [label] — the café's label
/// are all there to be found.
Future<void> _settle(WidgetTester tester, VectorTileLayerController controller,
    {bool label = true}) async {
  final ready = await pumpUntil(tester, () async {
    if (!await _colorAt(tester, _onScreen(128, 128), _red)) return false;
    if (!await _colorAt(tester, _onScreen(30, 64), _yellow)) return false;
    return !label ||
        controller
            .queryRenderedFeatures(_onScreen(200, 200))
            .any((f) => f.layerId == 'label');
  });
  expect(ready, isTrue, reason: 'the map never finished drawing');
}

/// Pumps until nothing has been rasterized or laid out for half a second.
Future<void> _quiet(WidgetTester tester) async {
  var last = (-1, -1);
  var since = DateTime.now();
  await pumpUntil(tester, () async {
    final now =
        (TileRasterizer.debugRasterizeCount, SymbolLayouter.debugLayoutCount);
    if (now != last) {
      last = now;
      since = DateTime.now();
    }
    return DateTime.now().difference(since) >=
        const Duration(milliseconds: 500);
  });
}

List<String> _names(List<RenderedFeature> features) =>
    [for (final f in features) '${f.layerId}:${f.id}'];

void main() {
  tearDown(VectorTileLayer.clearMemoryCache);

  testWidgets('a point query returns what is drawn there, topmost first',
      (tester) async {
    final controller = VectorTileLayerController();
    await _pumpMap(tester, controller: controller);
    expect(controller.isAttached, isTrue);
    await _settle(tester, controller);

    // On the road, over the park.
    final road = controller.queryRenderedFeatures(_onScreen(30, 66));
    expect(_names(road), ['road:2', 'land:1']);
    expect(road.first.source, 's');
    expect(road.first.sourceLayer, 'road');
    expect(road.first.geometryType, 'LineString');
    expect(road.last.geometryType, 'Polygon');
    // Only what the style reads survived decoding.
    expect(road.last.properties, {'kind': 'grass'});
    expect(road.last.state, isEmpty);
    // Just past the 6 px road.
    expect(_names(controller.queryRenderedFeatures(_onScreen(30, 67.5))),
        ['land:1']);
    // The café: its label above everything, then the circle.
    expect(_names(controller.queryRenderedFeatures(_onScreen(200, 200))),
        ['label:3', 'poi:3', 'land:1']);
    // Restricted to some layers.
    expect(
        _names(controller.queryRenderedFeatures(_onScreen(200, 200),
            layerIds: ['poi', 'road'])),
        ['poi:3']);
    // The background has no features.
    expect(controller.queryRenderedFeatures(_onScreen(8, 8)), isEmpty);

    await tester.pumpWidget(const SizedBox());
    expect(controller.isAttached, isFalse);
    expect(controller.queryRenderedFeatures(_mid), isEmpty);
  });

  testWidgets('a rectangle across a seam finds a feature with an id once',
      (tester) async {
    final controller = VectorTileLayerController();
    await _pumpMap(tester, controller: controller);
    await _settle(tester, controller, label: false);
    // Straddles the seam between the two tiles at x = 528: the park is
    // in both, as is the id-less patch below it.
    final hits = controller.queryRenderedFeaturesInRect(Rect.fromLTRB(
        _mid.dx + 120, _mid.dy + 100, _mid.dx + 140, _mid.dy + 125));
    // Within one tile, the later feature first; across tiles, no order.
    expect(_names(hits), unorderedEquals(['land:1', 'land:null', 'land:null']));
    expect([
      for (final f in hits)
        if (f.id == null) f.properties['kind']
    ], [
      'patch',
      'patch'
    ]);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a rotated map is queried where it is drawn', (tester) async {
    final controller = VectorTileLayerController();
    final mapController = MapController();
    await _pumpMap(tester,
        controller: controller, mapController: mapController);
    await _settle(tester, controller, label: false);
    mapController.rotate(90);
    // The road, 64 px above the centre, turns with the map — to wherever
    // the painter puts it, which the pixel there confirms.
    final rotation = mapController.camera.rotationRad;
    final onRoad = _mid +
        Offset(-(-64.0) * math.sin(rotation) + -50 * math.cos(rotation),
            -50 * math.sin(rotation) + -64.0 * math.cos(rotation));
    expect(await pumpUntil(tester, () => _colorAt(tester, onRoad, _yellow)),
        isTrue);
    expect(
        _names(controller.queryRenderedFeatures(onRoad)), ['road:2', 'land:1']);
    // Where the road was before the rotation, there is only park now.
    expect(_names(controller.queryRenderedFeatures(_onScreen(78, 64))),
        ['land:1']);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('retainAllProperties keeps what the style does not read',
      (tester) async {
    final controller = VectorTileLayerController();
    await _pumpMap(tester, controller: controller, retainAllProperties: true);
    await _settle(tester, controller, label: false);
    final park = controller.queryRenderedFeatures(_mid).last;
    expect(park.properties, {'kind': 'grass', 'name': 'Park', 'osm': 'way/5'});
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('labels drawn into the tiles are found too', (tester) async {
    final controller = VectorTileLayerController();
    await _pumpMap(tester, controller: controller, labelMode: LabelMode.tile);
    await _settle(tester, controller);
    expect(_names(controller.queryRenderedFeatures(_onScreen(200, 200))),
        ['label:3', 'poi:3', 'land:1']);
    // Off the label and the circle.
    expect(_names(controller.queryRenderedFeatures(_onScreen(200, 230))),
        ['land:1']);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'a tile-mode tile cached without a controller is drawn again for one',
      (tester) async {
    await _pumpMap(tester, controller: null, labelMode: LabelMode.tile);
    expect(
        await pumpUntil(
            tester, () => _colorAt(tester, _onScreen(128, 128), _red)),
        isTrue);
    await _quiet(tester);
    await tester.pumpWidget(const SizedBox());
    // Reopened over the same style: the finished tiles are cached, but
    // their labels were never recorded for a query.
    final controller = VectorTileLayerController();
    await _pumpMap(tester, controller: controller, labelMode: LabelMode.tile);
    await _settle(tester, controller);
    expect(_names(controller.queryRenderedFeatures(_onScreen(200, 200))),
        ['label:3', 'poi:3', 'land:1']);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'feature state re-renders only the tiles that draw the feature, '
      'and keeps their labels', (tester) async {
    final controller = VectorTileLayerController();
    await _pumpMap(tester, controller: controller);
    await _settle(tester, controller);
    await _quiet(tester);

    final rasterized = TileRasterizer.debugRasterizeCount;
    final laidOut = SymbolLayouter.debugLayoutCount;
    controller.setFeatureState(
        source: 's', sourceLayer: 'land', id: 1, state: {'selected': true});
    expect(
        await pumpUntil(tester, () => _colorAt(tester, _mid, _green)), isTrue);
    await _quiet(tester);
    // The park is in two tiles; nothing else is drawn again, and no
    // label is laid out again.
    expect(TileRasterizer.debugRasterizeCount - rasterized, 2);
    expect(SymbolLayouter.debugLayoutCount, laidOut);
    expect(_names(controller.queryRenderedFeatures(_onScreen(200, 200))),
        ['label:3', 'poi:3', 'land:1'],
        reason: 'the labels stay');
    expect(controller.queryRenderedFeatures(_mid).single.state,
        {'selected': true});
    // The road is untouched by state, the patch has no id.
    expect(await _colorAt(tester, _onScreen(30, 64), _yellow), isTrue);

    // Setting what is already set does nothing.
    final before = TileRasterizer.debugRasterizeCount;
    controller.setFeatureState(
        source: 's', sourceLayer: 'land', id: '1', state: {'selected': true});
    await _quiet(tester);
    expect(TileRasterizer.debugRasterizeCount, before);

    // State nothing reads re-renders nothing either.
    controller.setFeatureState(
        source: 's', sourceLayer: 'road', id: 2, state: {'selected': true});
    await _quiet(tester);
    expect(TileRasterizer.debugRasterizeCount, before);

    controller.removeFeatureState(source: 's', sourceLayer: 'land', id: 1);
    expect(await pumpUntil(tester, () => _colorAt(tester, _mid, _red)), isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a tile drawn with state is never served from the cache',
      (tester) async {
    final controller = VectorTileLayerController();
    final mapController = MapController();
    await _pumpMap(tester,
        controller: controller, mapController: mapController);
    await _settle(tester, controller, label: false);

    controller.setFeatureState(
        source: 's', sourceLayer: 'land', id: 1, state: {'selected': true});
    expect(
        await pumpUntil(tester, () => _colorAt(tester, _mid, _green)), isTrue);
    // Away — the tiles are disposed — and back: the state still shows,
    // though the cache holds the tile as first drawn, without it.
    mapController.move(const LatLng(10, 10), 14);
    await _quiet(tester);
    mapController.move(_centreOf(_centre), 14);
    expect(
        await pumpUntil(tester, () => _colorAt(tester, _mid, _green)), isTrue);
    // Cleared while away: back, the tile drawn with state must not be
    // what comes out of the cache.
    mapController.move(const LatLng(10, 10), 14);
    await _quiet(tester);
    controller.removeFeatureState(source: 's', sourceLayer: 'land');
    mapController.move(_centreOf(_centre), 14);
    expect(await pumpUntil(tester, () => _colorAt(tester, _mid, _red)), isTrue);
    await _quiet(tester);
    expect(await _colorAt(tester, _mid, _red), isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a promoted id is what queries return and state keys on',
      (tester) async {
    final controller = VectorTileLayerController();
    await _pumpMap(tester, controller: controller, promoteIds: {
      's': const PromoteId.bySourceLayer({'land': 'osm'})
    });
    await _settle(tester, controller, label: false);
    final park = controller.queryRenderedFeatures(_mid).single;
    expect(park.id, 'way/5');
    controller.setFeatureState(
        source: 's',
        sourceLayer: 'land',
        id: 'way/5',
        state: {'selected': true});
    expect(
        await pumpUntil(tester, () => _colorAt(tester, _mid, _green)), isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a controller handed over brings its own state', (tester) async {
    final first = VectorTileLayerController();
    final second = VectorTileLayerController()
      ..setFeatureState(
          source: 's', sourceLayer: 'land', id: 1, state: {'selected': true});
    await _pumpMap(tester, controller: first);
    await _settle(tester, first, label: false);
    await _pumpMap(tester, controller: second);
    expect(first.isAttached, isFalse);
    expect(second.isAttached, isTrue);
    expect(
        await pumpUntil(tester, () => _colorAt(tester, _mid, _green)), isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('state changes leak no image or picture', (tester) async {
    // Sized first: resizing the view replaces the root layer, disposing
    // a picture created before the count starts.
    _sizeView(tester);
    var images = 0, pictures = 0;
    void track(ObjectEvent event) {
      if (_snapshotting) return;
      final delta = switch (event) {
        ObjectCreated() => 1,
        ObjectDisposed() => -1,
        _ => 0,
      };
      if (event.object is ui.Image) images += delta;
      if (event.object is ui.Picture) pictures += delta;
    }

    FlutterMemoryAllocations.instance.addListener(track);
    addTearDown(() => FlutterMemoryAllocations.instance.removeListener(track));
    final controller = VectorTileLayerController();
    await _pumpMap(tester, controller: controller);
    Future<bool> green() => _colorAt(tester, _mid, _green);

    await pumpUntil(
        tester,
        () async => controller
            .queryRenderedFeatures(_onScreen(200, 200))
            .any((f) => f.layerId == 'label'));
    for (var i = 0; i < 3; i++) {
      controller.setFeatureState(
          source: 's', sourceLayer: 'land', id: 1, state: {'selected': true});
      await pumpUntil(tester, green);
      controller.removeFeatureState(source: 's', sourceLayer: 'land', id: 1);
      await pumpUntil(tester, () async => !await green());
    }
    // One change left in flight as the map goes.
    controller.setFeatureState(
        source: 's', sourceLayer: 'land', id: 1, state: {'selected': true});
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
    VectorTileLayer.clearMemoryCache();
    expect(images, 0, reason: 'images created but never disposed');
    expect(pictures, 0, reason: 'pictures created but never disposed');
  });

  test('a label style reading feature state follows it at a steady zoom', () {
    final layer =
        _theme(stateLabels: true).layers.whereType<SymbolThemeLayer>().single;
    final instance = SymbolInstance(
      layer: layer,
      layerIndex: 4,
      anchor: const Offset(128, 128),
      angle: 0,
      alongLine: false,
      text: 'Cafe',
      iconName: null,
      sortKey: 0,
      properties: const {'name': 'Cafe'},
      geometryType: 'Point',
      featureId: 3,
    );
    final states = FeatureStates();
    final painter = LabelPainter()..featureStates = states;
    addTearDown(painter.dispose);
    void paint() {
      final recorder = ui.PictureRecorder();
      painter.paint(
        canvas: Canvas(recorder),
        screenSize: const Size(256, 256),
        styleZoom: 14,
        symbols: [
          PlacedSymbol(
            instance: instance,
            screenAnchor: const Offset(128, 128),
            screenAngle: 0,
          ),
        ],
        placementGeneration: 0,
      );
      recorder.endRecording().dispose();
    }

    paint();
    expect(instance.textStyleMemo!.fillArgb, 0xff000000);
    states.set('s', 'poi', 3, {'selected': true});
    paint();
    expect(instance.textStyleMemo!.fillArgb, 0xff00ff00);
    // Another feature's state leaves it alone.
    states.set('s', 'poi', 4, {'selected': true});
    paint();
    expect(instance.textStyleMemo!.fillArgb, 0xff00ff00);
    states.remove('s', 'poi', id: 3);
    paint();
    expect(instance.textStyleMemo!.fillArgb, 0xff000000);
  });
}
