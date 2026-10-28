import 'package:flutter/material.dart' hide Theme;
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_vector_tiles/flutter_map_vector_tiles.dart';
import 'package:flutter_map_vector_tiles/src/render/label_painter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'fixtures/lifecycle_harness.dart';
import 'fixtures/mvt_builder.dart';

/// One point label at the centre of every tile, all of one name, so a
/// label is told apart only by where it is — the case identity exists
/// for. (Its Ahem glyphs cover land pixels, which is why the waits below
/// never ask for a fully painted map.)
final _tile = MvtTileBuilder()
    .layer('land', extent: extent)
    .feature(type: 3, geometry: [
      cmd(1, 1), zig(0), zig(0), //
      cmd(2, 3), zig(extent), zig(0), zig(0), zig(extent), zig(-extent),
      zig(0),
      cmd(7, 1),
    ])
    .done()
    .layer('poi', extent: extent)
    .feature(
      type: 1,
      geometry: [cmd(1, 1), zig(extent ~/ 2), zig(extent ~/ 2)],
      properties: {'name': 'AAAA'},
    )
    .done()
    .build();

/// Data up to z14 only, so every deeper level overzooms the z14 tile:
/// the same labels at the same world positions, and each z14 centre is
/// the corner four z15 tiles share — a seam label all four lay out.
class _Z14Provider extends EverywhereProvider {
  _Z14Provider() : super(_tile);

  @override
  int get maximumZoom => 14;
}

Theme _theme() => const ThemeReader().read({
      'layers': [
        {
          'id': 'land',
          'type': 'fill',
          'source': 's',
          'source-layer': 'land',
          'paint': {'fill-color': '#ff0000'},
        },
        {
          'id': 'poi',
          'type': 'symbol',
          'source': 's',
          'source-layer': 'poi',
          'layout': {'text-field': '{name}', 'text-size': 20},
        },
      ],
    });

Widget _app(MapController controller, VectorTileProvider provider,
        {LabelMode labelMode = LabelMode.screen}) =>
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
              theme: _theme(),
              tileProviders: TileProviders({'s': provider}),
              tileOffset: TileOffset.none,
              tileFadeDuration: Duration.zero,
              labelFadeDuration: const Duration(milliseconds: 100),
              labelMode: labelMode,
              concurrency: 1,
              diskCacheMaximumSizeInBytes: 0,
            ),
          ],
        ),
      ),
    );

void main() {
  setUp(VectorTileLayer.clearMemoryCache);
  tearDown(() => LabelPainter.debugDrawnProbe = null);

  /// The label ids placed (drawn, and not as fade-out ghosts) over a few
  /// frames — an idle map paints nothing, so the camera is nudged by a
  /// hair to make it.
  Future<Set<int>> drawnIds(
      WidgetTester tester, MapController controller) async {
    final ids = <int>{};
    LabelPainter.debugDrawnProbe = (_, drawn) {
      for (final label in drawn) {
        if (!label.ghost) ids.add(label.id);
      }
    };
    final camera = controller.camera;
    for (var i = 0; i < 20; i++) {
      controller.move(camera.center, camera.zoom + (i.isEven ? 1e-6 : 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    LabelPainter.debugDrawnProbe = null;
    return ids;
  }

  testWidgets('a label keeps its id through zoom crossings', (tester) async {
    tester.view.physicalSize = const Size(600, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final provider = _Z14Provider();
    final controller = MapController();

    await tester.pumpWidget(_app(controller, provider));
    await settleLoads(tester, provider, painted: false);
    final atZ14 = await drawnIds(tester, controller);
    expect(atZ14, isNotEmpty);

    // Into overzoom: the z15 tiles replace the z14 ones under labels
    // that stay where they were, each one laid out by four seam twins.
    controller.move(controller.camera.center, 15.2);
    await settleLoads(tester, provider, painted: false);
    final atZ15 = await drawnIds(tester, controller);
    expect(atZ15, isNotEmpty);
    expect(atZ15.difference(atZ14), isEmpty,
        reason: 'every label still on screen kept the id it had at z14');

    // And back out.
    controller.move(controller.camera.center, 14);
    await settleLoads(tester, provider, painted: false);
    final back = await drawnIds(tester, controller);
    expect(back.intersection(atZ15), atZ15,
        reason: 'the labels seen at z15 keep their ids back at z14');

    final ids = VectorTileLayer.debugLabelIds();
    expect(ids.held, ids.offered, reason: 'nothing held that is not offered');
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('every id a tile takes is handed back', (tester) async {
    tester.view.physicalSize = const Size(600, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final provider = _Z14Provider();
    final controller = MapController();

    await tester.pumpWidget(_app(controller, provider));
    await settleLoads(tester, provider, painted: false);
    var sawLabels = false;
    // Pans that drop tiles off the grid, crossings that retain, park and
    // release a level.
    for (final (dx, zoom) in [
      (0.02, 14.0),
      (0.0, 15.3),
      (-0.01, 15.8),
      (0.0, 13.6),
      (0.03, 14.4),
    ]) {
      final c = controller.camera.center;
      controller.move(LatLng(c.latitude, c.longitude + dx), zoom);
      await settleLoads(tester, provider, painted: false);
      // Through the fade of whatever the move parked.
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      final ids = VectorTileLayer.debugLabelIds();
      expect(ids.held, ids.offered, reason: 'at z$zoom');
      sawLabels |= ids.offered > 0;
    }
    expect(sawLabels, isTrue);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('tile mode holds no ids; screen mode takes them up again',
      (tester) async {
    // In LabelMode.tile labels go into the tile images with no per-frame
    // pass, so nothing carries over a frame and nothing needs an id.
    tester.view.physicalSize = const Size(600, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final provider = _Z14Provider();
    final controller = MapController();

    await tester.pumpWidget(_app(controller, provider));
    await settleLoads(tester, provider, painted: false);
    expect(VectorTileLayer.debugLabelIds().held, greaterThan(0));

    await tester
        .pumpWidget(_app(controller, provider, labelMode: LabelMode.tile));
    await pumpUntil(
        tester, () async => VectorTileLayer.debugLabelIds().held == 0);
    expect(VectorTileLayer.debugLabelIds(), (held: 0, offered: 0),
        reason: 'tile-mode tiles publish no candidates and hold no ids');

    await tester.pumpWidget(_app(controller, provider));
    await pumpUntil(
        tester, () async => VectorTileLayer.debugLabelIds().held > 0);
    await settleLoads(tester, provider, painted: false);
    final ids = VectorTileLayer.debugLabelIds();
    expect(ids.held, ids.offered);
    final drawn = await drawnIds(tester, controller);
    expect(drawn, isNotEmpty, reason: 'screen labels are back');
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
