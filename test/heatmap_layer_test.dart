import 'dart:typed_data';

import 'package:flutter/material.dart' hide Theme;
import 'package:flutter/rendering.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_vector_tiles/flutter_map_vector_tiles.dart';
import 'package:flutter_map_vector_tiles/src/render/heatmap_painter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'fixtures/lifecycle_harness.dart';
import 'fixtures/mvt_builder.dart';

/// Points at the given tile-extent positions, one feature each.
Uint8List pointTile(List<(int, int)> points) {
  final builder = MvtTileBuilder().layer('pts', extent: extent);
  for (final (x, y) in points) {
    builder.feature(type: 1, geometry: [cmd(1, 1), zig(x), zig(y)]);
  }
  return builder.done().build();
}

/// Serves [bytes] for one tile key and an empty tile everywhere else.
class OneTileProvider extends CountingProvider {
  final TileKey key;
  final Uint8List bytes;

  OneTileProvider(this.key, this.bytes);

  @override
  String get cacheKey => 'one-tile';

  @override
  Future<TileResponse> load(TileKey tile,
      {CancellationToken? cancellation}) async {
    note(tile);
    return TileResponseData(tile == key ? bytes : pointTile(const []));
  }
}

Theme heatTheme({double opacity = 1}) => const ThemeReader().read({
      'layers': [
        {
          'id': 'bg',
          'type': 'background',
          'paint': {'background-color': '#0000ff'},
        },
        {
          'id': 'heat',
          'type': 'heatmap',
          'source': 's',
          'source-layer': 'pts',
          'paint': {
            'heatmap-radius': 40,
            'heatmap-intensity': 10,
            // Black below 0.5, white above: a hard edge where the
            // density crosses one half.
            'heatmap-color': [
              'step',
              ['heatmap-density'],
              'rgba(0, 0, 0, 0)',
              0.5,
              '#ffffff',
            ],
          },
        },
      ],
    });

Widget heatApp(
  MapController controller,
  VectorTileProvider provider, {
  LatLng center = const LatLng(0, 0),
}) =>
    MaterialApp(
      home: RepaintBoundary(
        key: boundaryKey,
        child: FlutterMap(
          mapController: controller,
          options: MapOptions(initialCenter: center, initialZoom: 4),
          children: [
            VectorTileLayer(
              theme: heatTheme(),
              tileProviders: TileProviders({'s': provider}),
              tileOffset: TileOffset.none,
              tileFadeDuration: Duration.zero,
              concurrency: 1,
              diskCacheMaximumSizeInBytes: 0,
            ),
          ],
        ),
      ),
    );

Future<Uint8List> snapshot(WidgetTester tester) async {
  final boundary =
      tester.renderObject<RenderRepaintBoundary>(find.byKey(boundaryKey));
  final image = boundary.toImageSync();
  final data = await tester.runAsync(() => image.toByteData());
  image.dispose();
  return data!.buffer.asUint8List();
}

void main() {
  setUp(VectorTileLayer.clearMemoryCache);

  testWidgets('a cluster of points draws its density over the map',
      (tester) async {
    tester.view.physicalSize = const Size(512, 512);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // Zoom 4 around (0, 0): tile (4, 8, 8) has its top-left corner at
    // the screen centre. Its points sit 32 px right of and below that.
    final provider = OneTileProvider(const TileKey(4, 8, 8),
        pointTile([for (var i = 0; i < 4; i++) (512, 512)]));
    final controller = MapController();
    await tester.pumpWidget(heatApp(controller, provider));

    bool white(Uint8List px, int x, int y) {
      final i = (y * 512 + x) * 4;
      return px[i] > 200 && px[i + 1] > 200 && px[i + 2] > 200;
    }

    bool blue(Uint8List px, int x, int y) {
      final i = (y * 512 + x) * 4;
      return px[i] < 50 && px[i + 1] < 50 && px[i + 2] > 200;
    }

    final ready = await pumpUntil(
        tester, () async => white(await snapshot(tester), 256 + 32, 256 + 32));
    expect(ready, isTrue, reason: 'the heatmap never appeared');
    final px = await snapshot(tester);
    // 4 points · intensity 10 · 0.399 = 16 at the cluster, falling to
    // the 0.5 step at 16·exp(−4.5·(d/40)²) = 0.5: d = 35.1 px — the
    // radius is in logical pixels, with σ = radius/3.
    expect(white(px, 256 + 32 + 10, 256 + 32), isTrue);
    expect(white(px, 256 + 32 + 32, 256 + 32), isTrue);
    expect(white(px, 256 + 32, 256 + 32 - 32), isTrue);
    expect(blue(px, 256 + 32 + 39, 256 + 32), isTrue);
    expect(blue(px, 256 + 32, 256 + 32 + 39), isTrue);
    // …and the background where no kernel reaches.
    expect(blue(px, 20, 20), isTrue);
    expect(blue(px, 256 + 32 + 70, 256 + 32), isTrue);
    expect(HeatmapPainter.debugPassCount, greaterThan(0));
  });

  testWidgets('a kernel reaches across a tile seam', (tester) async {
    tester.view.physicalSize = const Size(512, 512);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // On the left edge of tile (4, 8, 8), which starts at the screen
    // centre: the density must spill into tile (4, 7, 8) on its left.
    final provider = OneTileProvider(const TileKey(4, 8, 8),
        pointTile([for (var i = 0; i < 4; i++) (0, 1024)]));
    final controller = MapController();
    await tester.pumpWidget(heatApp(controller, provider));

    bool white(Uint8List px, int x, int y) {
      final i = (y * 512 + x) * 4;
      return px[i] > 200 && px[i + 1] > 200 && px[i + 2] > 200;
    }

    final ready = await pumpUntil(
        tester, () async => white(await snapshot(tester), 256 + 2, 256 + 64));
    expect(ready, isTrue);
    final px = await snapshot(tester);
    // As far left of the seam as right of it.
    expect(white(px, 256 - 12, 256 + 64), isTrue);
    expect(white(px, 256 + 12, 256 + 64), isTrue);
  });
}
