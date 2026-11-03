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
const _size = 512;
const _mid = _size ~/ 2;

/// One building, 100..130 px right of the centre and 50..80 px below
/// it, `height` 200: its roof lands at 112..146 × 56..90.
Uint8List _buildingTile() => MvtTileBuilder()
    .layer('building', extent: extent)
    .feature(type: 3, id: 7, properties: {
      'height': 200,
    }, geometry: [
      cmd(1, 1), zig(1600), zig(800), //
      cmd(2, 3), zig(480), zig(0), zig(0), zig(480), zig(-480), zig(0),
      cmd(7, 1),
    ])
    .done()
    .build();

class _OneTile extends CountingProvider {
  @override
  String get cacheKey => 'extrusion-one-tile';

  @override
  Future<TileResponse> load(TileKey tile,
      {CancellationToken? cancellation}) async {
    note(tile);
    return tile == _key
        ? TileResponseData(_buildingTile())
        : TileResponseData(
            MvtTileBuilder().layer('building', extent: extent).done().build());
  }
}

Theme _theme({double opacity = 1}) => const ThemeReader().read({
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
            'fill-extrusion-opacity': opacity,
          },
        },
      ],
    });

Widget _app(
  VectorTileProvider provider, {
  Theme? theme,
  ExtrusionMode extrusions = ExtrusionMode.perspective,
  LabelMode labelMode = LabelMode.screen,
  VectorTileLayerController? controller,
  double rotation = 0,
}) =>
    MaterialApp(
      home: RepaintBoundary(
        key: boundaryKey,
        child: FlutterMap(
          options: MapOptions(
            initialCenter: const LatLng(0, 0),
            initialZoom: _zoom,
            initialRotation: rotation,
          ),
          children: [
            VectorTileLayer(
              theme: theme ?? _theme(),
              tileProviders: TileProviders({'s': provider}),
              tileOffset: TileOffset.none,
              tileFadeDuration: Duration.zero,
              concurrency: 1,
              diskCacheMaximumSizeInBytes: 0,
              extrusions: extrusions,
              labelMode: labelMode,
              controller: controller,
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

  testWidgets('flat: the footprint in the tile image, no lean', (tester) async {
    final px = await open(
        tester,
        _app(_OneTile(), extrusions: ExtrusionMode.flat),
        (px) => _white(_rgb(px, 105, 70)));
    expect(_white(_rgb(px, 105, 70)), isTrue);
    expect(_blue(_rgb(px, 140, 85)), isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('LabelMode.tile draws them flat', (tester) async {
    final px = await open(tester, _app(_OneTile(), labelMode: LabelMode.tile),
        (px) => _white(_rgb(px, 105, 70)));
    expect(_blue(_rgb(px, 140, 85)), isTrue);
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
}
