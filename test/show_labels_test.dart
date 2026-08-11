import 'dart:typed_data';

import 'package:flutter/material.dart' hide Theme;
import 'package:flutter/rendering.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_vector_tiles/flutter_map_vector_tiles.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'fixtures/lifecycle_harness.dart';
import 'fixtures/mvt_builder.dart';

/// Label text renders with the test framework's Ahem font — solid
/// blocks of the text colour — so any lime pixel proves a painted label.
const labelColor = Color(0xff00ff00);

Uint8List labelledTile() => MvtTileBuilder()
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

Theme labelTheme() => const ThemeReader().read({
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
        {
          'id': 'poi',
          'type': 'symbol',
          'source': 's',
          'source-layer': 'poi',
          'layout': {'text-field': '{name}', 'text-size': 40},
          'paint': {'text-color': '#00ff00'},
        },
      ],
    });

Widget labelApp(
  MapController controller,
  VectorTileProvider provider, {
  required bool showLabels,
  Duration labelFadeDuration = const Duration(milliseconds: 150),
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
              theme: labelTheme(),
              tileProviders: TileProviders({'s': provider}),
              tileOffset: TileOffset.none,
              tileFadeDuration: Duration.zero,
              labelFadeDuration: labelFadeDuration,
              concurrency: 1,
              diskCacheMaximumSizeInBytes: 0,
              showLabels: showLabels,
            ),
          ],
        ),
      ),
    );

/// Whether any rendered pixel has exactly [color].
Future<bool> hasColor(WidgetTester tester, Color color) async {
  final boundary =
      tester.renderObject<RenderRepaintBoundary>(find.byKey(boundaryKey));
  final image = boundary.toImageSync();
  final found = await tester.runAsync(() async {
    final data = (await image.toByteData())!;
    final r = (color.r * 255).round();
    final g = (color.g * 255).round();
    final b = (color.b * 255).round();
    for (var i = 0; i < data.lengthInBytes; i += 4) {
      if (data.getUint8(i) == r &&
          data.getUint8(i + 1) == g &&
          data.getUint8(i + 2) == b &&
          data.getUint8(i + 3) == 0xff) {
        return true;
      }
    }
    return false;
  });
  image.dispose();
  return found!;
}

void main() {
  setUp(VectorTileLayer.clearMemoryCache);

  testWidgets('enabling showLabels lays out labels on live tiles',
      (tester) async {
    // Regression: didUpdateWidget ignored showLabels, and symbols are
    // baked at rasterize time — toggling false→true used to show zero
    // labels on every already-loaded tile until it was recreated.
    tester.view.physicalSize = const Size(600, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final provider = EverywhereProvider(labelledTile());
    final controller = MapController();

    await tester.pumpWidget(labelApp(controller, provider, showLabels: false));
    await settle(tester);
    expect(await hasColor(tester, labelColor), isFalse,
        reason: 'labels are disabled');
    final loadsBefore = provider.loads;
    expect(loadsBefore, greaterThan(0));

    await tester.pumpWidget(labelApp(controller, provider, showLabels: true));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
      if (await hasColor(tester, labelColor)) break;
    }
    expect(await hasColor(tester, labelColor), isTrue,
        reason: 'live tiles must re-lay-out their symbols');
    expect(provider.loads, loadsBefore,
        reason: 'the re-layout must reuse already-decoded tiles');

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('disabling showLabels hides labels immediately', (tester) async {
    tester.view.physicalSize = const Size(600, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final provider = EverywhereProvider(labelledTile());
    final controller = MapController();

    await tester.pumpWidget(labelApp(controller, provider, showLabels: true));
    await settle(tester);
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
      if (await hasColor(tester, labelColor)) break;
    }
    expect(await hasColor(tester, labelColor), isTrue);

    await tester.pumpWidget(labelApp(controller, provider, showLabels: false));
    await tester.pump();
    expect(await hasColor(tester, labelColor), isFalse,
        reason: 'the label pass is skipped as soon as the flag is off');

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('a sub-millisecond label fade still paints', (tester) async {
    // End-to-end cover for durations shorter than the millisecond the
    // fade arithmetic was once measured in. `fade_test.dart` pins that
    // arithmetic directly, which is where the regression lives: fade
    // progress reads the wall clock, so a widget test cannot control
    // how much real time passes between labels landing and the frame
    // that draws them.
    tester.view.physicalSize = const Size(600, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(labelApp(
      MapController(),
      EverywhereProvider(labelledTile()),
      showLabels: true,
      labelFadeDuration: const Duration(microseconds: 500),
    ));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
      if (await hasColor(tester, labelColor)) break;
    }
    expect(tester.takeException(), isNull);
    expect(await hasColor(tester, labelColor), isTrue);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
