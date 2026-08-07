import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart' hide Theme;
import 'package:flutter/rendering.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_vector_tiles/flutter_map_vector_tiles.dart';
import 'package:flutter_map_vector_tiles/src/cache/disk_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'fixtures/mvt_builder.dart';

const _extent = 4096;

/// Distinctive colours so a rendered pixel says exactly which stage of
/// the pipeline produced it.
const _land = Color(0xffff0000); // the tile's fill
const _background = Color(0xff0000ff); // the style background

/// One tile whose single polygon covers the whole tile.
Uint8List _fullTile() => MvtTileBuilder()
    .layer('land', extent: _extent)
    .feature(type: 3, geometry: [
      cmd(1, 1), zig(0), zig(0), //
      cmd(2, 3), zig(_extent), zig(0), zig(0), zig(_extent), zig(-_extent),
      zig(0),
      cmd(7, 1),
    ])
    .done()
    .build();

/// Serves the same tile for every coordinate, so tests never depend on
/// which tiles the grid happens to ask for.
class _EverywhereProvider extends VectorTileProvider {
  final Uint8List bytes;
  var loads = 0;

  _EverywhereProvider(this.bytes);

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

Theme _theme() => const ThemeReader().read({
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

const _boundaryKey = ValueKey('map-boundary');

Widget _app(
  MapController controller,
  VectorTileProvider provider, {
  Future<Directory> Function()? cacheFolder,
}) =>
    MaterialApp(
      home: RepaintBoundary(
        key: _boundaryKey,
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
              // Style zoom == display zoom keeps the test arithmetic plain.
              tileOffset: TileOffset.none,
              // Instant fades: fade progress is driven by the wall clock,
              // which `pump` does not advance.
              tileFadeDuration: Duration.zero,
              concurrency: 1,
              cacheFolder: cacheFolder,
              diskCacheMaximumSizeInBytes:
                  cacheFolder == null ? 0 : 1024 * 1024,
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
Future<Color> _centrePixel(WidgetTester tester) async {
  final boundary =
      tester.renderObject<RenderRepaintBoundary>(find.byKey(_boundaryKey));
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
Future<void> _settle(WidgetTester tester, {int rounds = 60}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    if (await _centrePixel(tester) == _land) return;
  }
}

/// Samples the centre pixel over [frames] pumped frames and returns
/// every distinct colour seen.
Future<Set<Color>> _sampleDuring(
  WidgetTester tester, {
  required int frames,
}) async {
  final seen = <Color>{};
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    seen.add(await _centrePixel(tester));
  }
  return seen;
}

void main() {
  // Decoded tiles and disk caches are shared process-wide and outlive the
  // layer on purpose, so without this each test would inherit the previous
  // test's warm cache — and the load counts below would all read zero.
  setUp(() {
    VectorTileLayer.clearMemoryCache();
    DiskCacheRegistry.reset();
  });

  // Every test fixes the surface size, so the tile grid is the same on
  // every machine.
  Future<void> withMap(
    WidgetTester tester,
    Future<void> Function(MapController controller, _EverywhereProvider p)
        body, {
    Future<Directory> Function()? cacheFolder,
  }) async {
    tester.view.physicalSize = const Size(600, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final provider = _EverywhereProvider(_fullTile());
    final controller = MapController();
    await tester
        .pumpWidget(_app(controller, provider, cacheFolder: cacheFolder));
    await _settle(tester);
    await body(controller, provider);
    // Tear the layer down so its decode isolates shut down with the test.
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  }

  testWidgets('the map paints its tile fill over the background',
      (tester) async {
    await withMap(tester, (controller, provider) async {
      expect(await _centrePixel(tester), _land,
          reason: 'tiles should have rendered over the background');
    });
  });

  testWidgets('a zoom level change never exposes the background',
      (tester) async {
    // The 0.4.1 flash: the previous level used to be dropped before the
    // new one had rasterized and faded in, dipping to the background
    // colour for a few frames.
    await withMap(tester, (controller, provider) async {
      controller.move(const LatLng(48.1725, 11.7375), 15);
      final seen = await _sampleDuring(tester, frames: 30);
      expect(seen, isNot(contains(_background)),
          reason: 'the old level must cover the new one until it is ready');
      expect(seen, {_land});
    });
  });

  testWidgets('zooming several levels at once never exposes the background',
      (tester) async {
    // A fast pinch outruns the decode pipeline entirely; provisional
    // imagery rendered from already-decoded ancestors has to cover it.
    await withMap(tester, (controller, provider) async {
      controller.move(const LatLng(48.1725, 11.7375), 17);
      final seen = await _sampleDuring(tester, frames: 30);
      expect(seen, {_land});
    });
  });

  testWidgets('zooming back out never exposes the background', (tester) async {
    await withMap(tester, (controller, provider) async {
      controller.move(const LatLng(48.1725, 11.7375), 12);
      final seen = await _sampleDuring(tester, frames: 30);
      expect(seen, {_land});
    });
  });

  testWidgets('panning onto new ground recovers to painted tiles',
      (tester) async {
    // Unlike a zoom change, panning at a fixed zoom has no previous
    // level to retain, and provisional imagery needs a decoded ancestor
    // in the memory cache — which never-visited ground has not got. A
    // brief flash of background is therefore expected here (MapLibre
    // behaves the same); what must not happen is staying blank.
    await withMap(tester, (controller, provider) async {
      controller.move(const LatLng(48.20, 11.80), 14);
      await _settle(tester);
      expect(await _centrePixel(tester), _land);
    });
  });

  testWidgets('returning to visited ground repaints without refetching',
      (tester) async {
    // The memory cache is what keeps a pan-away-and-back from hitting
    // the network again, so it must survive tiles leaving the viewport.
    await withMap(tester, (controller, provider) async {
      final afterFirstPaint = provider.loads;
      expect(afterFirstPaint, greaterThan(0));

      controller.move(const LatLng(48.60, 12.40), 14);
      await _settle(tester);
      final afterPanAway = provider.loads;
      expect(afterPanAway, greaterThan(afterFirstPaint),
          reason: 'new ground genuinely needs fetching');

      controller.move(const LatLng(48.1725, 11.7375), 14);
      await _settle(tester);

      expect(await _centrePixel(tester), _land);
      expect(provider.loads, afterPanAway,
          reason: 'the original tiles should come back from memory');
    });
  });

  testWidgets('a reopened map paints from cache without refetching',
      (tester) async {
    // Reopening the map screen builds a whole new layer, and everything it
    // needs was already fetched a moment ago. Two caches have to survive
    // that teardown for it to paint straight away — and the disk one has to
    // be *awaited*: tiles are requested on the first frame, while the cache
    // is still resolving its directory through a platform channel. Reading
    // it as a plain field there yields null and sends the opening screenful
    // to the network despite it sitting on disk.
    final dir = Directory.systemTemp.createTempSync('fmvt_reopen');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    tester.view.physicalSize = const Size(600, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final first = _EverywhereProvider(_fullTile());
    await tester.pumpWidget(
      _app(MapController(), first, cacheFolder: () async => dir),
    );
    await _settle(tester);
    expect(first.loads, greaterThan(0), reason: 'nothing was cached yet');

    await tester.pumpWidget(const SizedBox());
    await tester.pump();

    // Force the disk to be the only thing that can answer the second open,
    // and make it resolve late — the exact window the first frame's tiles
    // used to race past.
    VectorTileLayer.clearMemoryCache();
    DiskCacheRegistry.reset();
    final cacheReady = Completer<void>();
    final second = _EverywhereProvider(_fullTile());
    await tester.pumpWidget(_app(
      MapController(),
      second,
      cacheFolder: () async {
        await cacheReady.future;
        return dir;
      },
    ));
    await tester.pump();
    cacheReady.complete();
    await _settle(tester);

    expect(await _centrePixel(tester), _land);
    expect(second.loads, 0, reason: 'the screenful was already on disk');

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('decoded tiles outlive the layer that loaded them',
      (tester) async {
    // The memory half of the same story: with the tiles still decoded, a
    // reopen needs neither the network nor the disk.
    final provider = _EverywhereProvider(_fullTile());

    tester.view.physicalSize = const Size(600, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_app(MapController(), provider));
    await _settle(tester);
    final afterFirstOpen = provider.loads;
    expect(afterFirstOpen, greaterThan(0));

    await tester.pumpWidget(const SizedBox());
    await tester.pump();

    await tester.pumpWidget(_app(MapController(), provider));
    await _settle(tester);

    expect(await _centrePixel(tester), _land);
    expect(provider.loads, afterFirstOpen);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
