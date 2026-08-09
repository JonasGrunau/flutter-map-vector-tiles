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

/// Serves the same tile for every coordinate, so tests never depend on
/// which tiles the grid happens to ask for.
class EverywhereProvider extends VectorTileProvider {
  final Uint8List bytes;
  var loads = 0;

  EverywhereProvider(this.bytes);

  @override
  int get maximumZoom => 20;
  @override
  int get minimumZoom => 0;
  @override
  String get cacheKey => 'everywhere';

  @override
  Future<TileResponse> load(TileKey tile,
      {CancellationToken? cancellation}) async {
    loads++;
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

/// Colour at the centre of the rendered map.
///
/// `toByteData` is genuinely asynchronous, so the read has to happen
/// inside [WidgetTester.runAsync] — awaiting it in the fake-async zone
/// deadlocks.
Future<Color> centrePixel(WidgetTester tester) async {
  final boundary =
      tester.renderObject<RenderRepaintBoundary>(find.byKey(boundaryKey));
  final image = boundary.toImageSync();
  final colour = await tester.runAsync(() async {
    final data = await image.toByteData();
    final w = image.width, h = image.height;
    final i = ((h ~/ 2) * w + (w ~/ 2)) * 4;
    return Color.fromARGB(
      data!.getUint8(i + 3),
      data.getUint8(i),
      data.getUint8(i + 1),
      data.getUint8(i + 2),
    );
  });
  image.dispose();
  return colour!;
}

/// Pumps until the map has painted its tiles, letting the decode
/// isolates make real progress in between.
Future<void> settle(WidgetTester tester, {int rounds = 60}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    if (await centrePixel(tester) == land) return;
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
