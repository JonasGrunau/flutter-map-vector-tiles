import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart' hide Theme;
import 'package:flutter/rendering.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_vector_tiles/flutter_map_vector_tiles.dart';
import 'package:flutter_map_vector_tiles/src/render/label_painter.dart';
import 'package:flutter_map_vector_tiles/src/render/symbol_layouter.dart';
import 'package:flutter_map_vector_tiles/src/render/tile_rasterizer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'fixtures/lifecycle_harness.dart';
import 'fixtures/mvt_builder.dart';

/// The pattern colour of the sprites the map starts with.
const oldPattern = Color(0xffff8000);

/// The pattern colour of the sprites swapped in for them.
const newPattern = Color(0xff00ffff);

/// Where the map looks, at every zoom.
const centre = LatLng(48.1725, 11.7375);

/// A sprite sheet whose one pattern, `p`, is a solid [color] square.
SpriteAtlas solidAtlas(Color color, String cacheKey) {
  final recorder = ui.PictureRecorder();
  Canvas(recorder)
      .drawRect(const Rect.fromLTWH(0, 0, 16, 16), Paint()..color = color);
  final picture = recorder.endRecording();
  final image = picture.toImageSync(16, 16);
  picture.dispose();
  return SpriteAtlas(
    image: image,
    sprites: const {
      'p': Sprite(x: 0, y: 0, width: 16, height: 16, pixelRatio: 1),
    },
    pixelRatio: 1,
    cacheKey: cacheKey,
  );
}

/// [stripes] full-height vertical stripes, one source layer `q<i>`
/// each, and a POI labelled "AAAA" at the centre.
Uint8List stripedTile(int stripes) {
  var tile = MvtTileBuilder();
  final width = extent ~/ stripes;
  for (var i = 0; i < stripes; i++) {
    tile = tile.layer('q$i', extent: extent).feature(type: 3, geometry: [
      cmd(1, 1), zig(i * width), zig(0), //
      cmd(2, 3), zig(width), zig(0), zig(0), zig(extent), zig(-width),
      zig(0),
      cmd(7, 1),
    ]).done();
  }
  return tile
      .layer('poi', extent: extent)
      .feature(
        type: 1,
        geometry: [cmd(1, 1), zig(extent ~/ 2), zig(extent ~/ 2)],
        properties: {'name': 'AAAA'},
      )
      .done()
      .build();
}

/// One `fill-pattern: p` layer per stripe of [stripedTile] — over a
/// background layer unless [background] is false — and the POI's label
/// when [labels] is set.
Theme stripedTheme(int stripes,
        {bool background = true, bool labels = false}) =>
    const ThemeReader().read({
      'layers': [
        if (background)
          {
            'id': 'bg',
            'type': 'background',
            'paint': {'background-color': '#0000ff'},
          },
        for (var i = 0; i < stripes; i++)
          {
            'id': 'q$i',
            'type': 'fill',
            'source': 's',
            'source-layer': 'q$i',
            'paint': {'fill-pattern': 'p'},
          },
        if (labels)
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

/// Serves [bytes] for every tile, holding back the zooms in [gates]
/// until their completer completes.
class GatedProvider extends CountingProvider {
  final Uint8List bytes;
  final gates = <int, Completer<void>>{};

  GatedProvider(this.bytes);

  @override
  String get cacheKey => 'gated';

  @override
  Future<TileResponse> load(TileKey tile,
      {CancellationToken? cancellation}) async {
    note(tile);
    await gates[tile.z]?.future;
    return TileResponseData(bytes);
  }

  /// Lets every held-back load through.
  void openAll() {
    for (final gate in gates.values) {
      if (!gate.isCompleted) gate.complete();
    }
  }
}

/// The render pump's work counters: recordings started, layers
/// recorded, symbol layouts and tile-mode label passes.
typedef Progress = ({int rasterized, int slices, int layouts, int tilePaints});

/// [Progress] so far, or since [start].
Progress progress([Progress? start]) => (
      rasterized: TileRasterizer.debugRasterizeCount - (start?.rasterized ?? 0),
      slices: TileRasterizer.debugSliceCount - (start?.slices ?? 0),
      layouts: SymbolLayouter.debugLayoutCount - (start?.layouts ?? 0),
      tilePaints: LabelPainter.debugTilePaintCount - (start?.tilePaints ?? 0),
    );

/// Pumps until [provider] has been asked for nothing and the render
/// pump has done nothing for half a second.
Future<void> settleRendering(
    WidgetTester tester, CountingProvider provider) async {
  const quiet = Duration(milliseconds: 500);
  Progress? last;
  var since = DateTime.now();
  final settled = await pumpUntil(tester, () async {
    final now = progress();
    if (now != last) {
      last = now;
      since = DateTime.now();
    }
    return DateTime.now().difference(since) >= quiet &&
        DateTime.now().difference(provider.lastLoadAt) >= quiet;
  });
  expect(settled, isTrue, reason: 'rendering never settled');
}

/// How many rendered pixels are exactly [color].
Future<int> pixelsOf(WidgetTester tester, Color color) async {
  final boundary =
      tester.renderObject<RenderRepaintBoundary>(find.byKey(boundaryKey));
  final image = boundary.toImageSync();
  final data = await tester.runAsync(() async => (await image.toByteData())!);
  image.dispose();
  final rgba = [color.r, color.g, color.b, color.a]
      .map((c) => (c * 255).round())
      .toList();
  var count = 0;
  for (var i = 0; i < data!.lengthInBytes; i += 4) {
    if (data.getUint8(i) == rgba[0] &&
        data.getUint8(i + 1) == rgba[1] &&
        data.getUint8(i + 2) == rgba[2] &&
        data.getUint8(i + 3) == rgba[3]) {
      count++;
    }
  }
  return count;
}

/// Renders [theme] at z13 with the old sprites, moves to z14 while its
/// data is held back (so z14 shows provisional imagery from z13), then
/// lets the data in until [midway] holds: a final z14 job is part done.
/// Zooms on to z15, whose data is held back too, so the z14 level stays
/// retained with that job queued, and swaps in the new sprites — before
/// the zoom instead when [swapFirst], with z14 still live. Once the
/// queued work has run, returns to z14 and counts the old pattern's
/// pixels there.
Future<int> oldPatternAfterSwap(
  WidgetTester tester, {
  required Theme theme,
  required int stripes,
  required bool Function(Progress since) midway,
  LabelMode mode = LabelMode.screen,
  bool swapFirst = false,
}) async {
  tester.view.physicalSize = const Size(600, 600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  VectorTileLayer.clearMemoryCache();
  addTearDown(VectorTileLayer.clearMemoryCache);
  addTearDown(() => VectorTileLayer.debugPumpBudgetMicros = null);
  final oldSprites = solidAtlas(oldPattern, 'old');
  final newSprites = solidAtlas(newPattern, 'new');
  addTearDown(oldSprites.dispose);
  addTearDown(newSprites.dispose);
  final provider = GatedProvider(stripedTile(stripes));
  addTearDown(provider.openAll);
  final providers = TileProviders({'s': provider});
  final controller = MapController();

  // The same theme and providers on every rebuild: replacing either
  // rebuilds the layer from scratch, which would clear the queue.
  Widget map(SpriteAtlas sprites) => MaterialApp(
        home: RepaintBoundary(
          key: boundaryKey,
          child: FlutterMap(
            mapController: controller,
            options: const MapOptions(initialCenter: centre, initialZoom: 13),
            children: [
              VectorTileLayer(
                theme: theme,
                tileProviders: providers,
                sprites: sprites,
                tileOffset: TileOffset.none,
                tileFadeDuration: Duration.zero,
                concurrency: 1,
                diskCacheMaximumSizeInBytes: 0,
                labelMode: mode,
              ),
            ],
          ),
        ),
      );

  await tester.pumpWidget(map(oldSprites));
  await settleRendering(tester, provider);
  provider.gates[14] = Completer<void>();
  provider.gates[15] = Completer<void>();
  controller.move(centre, 14);
  await settleRendering(tester, provider);

  // One layer or label per frame, so a job can be caught part done.
  VectorTileLayer.debugPumpBudgetMicros = 0;
  final start = progress();
  provider.gates[14]!.complete();
  expect(await pumpUntil(tester, () async => midway(progress(start))), isTrue,
      reason: 'no z14 job was ever caught part done');

  if (swapFirst) await tester.pumpWidget(map(newSprites));
  controller.move(centre, 15);
  await tester.pump();
  expect(VectorTileLayer.debugRetainedTileCount, greaterThan(0));
  if (!swapFirst) await tester.pumpWidget(map(newSprites));
  VectorTileLayer.debugPumpBudgetMicros = null;
  await settleRendering(tester, provider);
  expect(VectorTileLayer.debugRetainedTileCount, greaterThan(0),
      reason: 'z14 must still be retained while its queued work runs');

  provider.openAll();
  await settleRendering(tester, provider);
  controller.move(centre, 14);
  await settleRendering(tester, provider);
  final stale = await pixelsOf(tester, oldPattern);
  expect(await pixelsOf(tester, newPattern), greaterThan(0));
  await tester.pumpWidget(const SizedBox());
  return stale;
}

void main() {
  group('a sprites change during a zoom crossing', () {
    testWidgets(
        'a recording half done with the old sprites is not finished '
        'with the new ones', (tester) async {
      // Background and four stripes: five layers to record.
      final stale = await oldPatternAfterSwap(
        tester,
        theme: stripedTheme(4),
        stripes: 4,
        midway: (p) => p.rasterized >= 1 && p.slices == 5 * p.rasterized - 3,
      );
      expect(stale, 0, reason: 'old pattern served under the new sprites');
    });

    testWidgets(
        'a tile-mode label job holding geometry drawn with the old '
        'sprites does not publish it', (tester) async {
      final stale = await oldPatternAfterSwap(
        tester,
        theme: stripedTheme(4, labels: true),
        stripes: 4,
        mode: LabelMode.tile,
        midway: (p) =>
            p.rasterized >= 1 &&
            p.slices == 5 * p.rasterized - 1 &&
            p.tilePaints == 0,
      );
      expect(stale, 0, reason: 'old pattern served under the new sprites');
    });

    testWidgets(
        'a symbols job does not cache an image rasterized before the '
        'change', (tester) async {
      // One layer to record, so no recording spans the change: the
      // raster lands before it, the symbols job runs after it.
      final stale = await oldPatternAfterSwap(
        tester,
        theme: stripedTheme(1, background: false, labels: true),
        stripes: 1,
        midway: (p) =>
            p.rasterized >= 3 && p.slices == p.rasterized && p.layouts == 0,
      );
      expect(stale, 0, reason: 'old pattern served under the new sprites');
    });

    testWidgets('control: sprites swapped while the level is still live',
        (tester) async {
      final stale = await oldPatternAfterSwap(
        tester,
        theme: stripedTheme(4),
        stripes: 4,
        swapFirst: true,
        midway: (p) => p.rasterized >= 1 && p.slices == 5 * p.rasterized - 3,
      );
      expect(stale, 0);
    });
  });
}
