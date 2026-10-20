import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
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

/// Label text renders with the test framework's Ahem font — solid
/// blocks of the text colour — so a lime pixel proves a painted label
/// and the shape of a lime run says which way the text runs.
const labelColor = Color(0xff00ff00);

/// One tile: land over the whole tile, and a POI labelled "AAAA" at its
/// centre — 160×40 px of solid text at `text-size` 40, well inside the
/// 256 px tile.
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

Theme labelTheme({bool allowOverlap = false}) => const ThemeReader().read({
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
          'layout': {
            'text-field': '{name}',
            'text-size': 40,
            'text-allow-overlap': allowOverlap,
          },
          'paint': {'text-color': '#00ff00'},
        },
      ],
    });

/// [labelTheme] with a third layer that draws: the land's outline.
Theme threeLayerTheme() => const ThemeReader().read({
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
          'id': 'coast',
          'type': 'line',
          'source': 's',
          'source-layer': 'land',
          'paint': {'line-color': '#ffffff'},
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

/// Pass the same [theme] and [providers] to every rebuild of one map:
/// either one replaced rebuilds the layer's stores and tiles from
/// scratch, which would bypass the in-place updates under test.
Widget labelModeApp(
  MapController controller,
  TileProviders providers,
  Theme theme, {
  required LabelMode labelMode,
  bool showLabels = true,
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
              theme: theme,
              tileProviders: providers,
              tileOffset: TileOffset.none,
              tileFadeDuration: Duration.zero,
              concurrency: 1,
              diskCacheMaximumSizeInBytes: 0,
              showLabels: showLabels,
              labelMode: labelMode,
            ),
          ],
        ),
      ),
    );

/// Whether [snapshot] is taking its image. The leak test ignores what
/// is created and disposed meanwhile: that is the test's own doing, and
/// on web the engine keeps a picture of each snapshot for itself.
var snapshotting = false;

/// The rendered map's pixels, read in one snapshot.
Future<(ByteData, int, int)> snapshot(WidgetTester tester) async {
  final boundary =
      tester.renderObject<RenderRepaintBoundary>(find.byKey(boundaryKey));
  snapshotting = true;
  final image = boundary.toImageSync();
  snapshotting = false;
  final data = await tester.runAsync(() async => (await image.toByteData())!);
  final size = (image.width, image.height);
  snapshotting = true;
  image.dispose();
  snapshotting = false;
  return (data!, size.$1, size.$2);
}

bool _isColor(ByteData data, int i, Color color) =>
    data.getUint8(i) == (color.r * 255).round() &&
    data.getUint8(i + 1) == (color.g * 255).round() &&
    data.getUint8(i + 2) == (color.b * 255).round() &&
    data.getUint8(i + 3) == 0xff;

/// Whether any rendered pixel has exactly [color].
Future<bool> hasColor(WidgetTester tester, Color color) async {
  final (data, _, _) = await snapshot(tester);
  for (var i = 0; i < data.lengthInBytes; i += 4) {
    if (_isColor(data, i, color)) return true;
  }
  return false;
}

/// [settleLoads] for a map with labels on it: its "fully painted" probe
/// expects land on a lattice of pixels, and a label may sit on one.
Future<void> settleLabelled(
    WidgetTester tester, CountingProvider provider) async {
  await settleLoads(tester, provider, painted: false);
  expect(await pumpUntil(tester, () => hasColor(tester, land)), isTrue);
}

/// The longest horizontal and vertical runs of label pixels: a 160×40 px
/// text block reads as (160, 40) upright and (40, 160) on its side.
///
/// A run bridges gaps of up to [_maxGap] pixels: drawn straight onto the
/// screen at a fractional offset, as the screen pass does, CanvasKit
/// leaves an antialiased hairline between two glyphs.
Future<({int horizontal, int vertical})> labelRuns(WidgetTester tester) async {
  final (data, w, h) = await snapshot(tester);
  bool lime(int x, int y) => _isColor(data, (y * w + x) * 4, labelColor);
  int longest(int lines, int length, bool Function(int line, int i) at) {
    var best = 0;
    for (var line = 0; line < lines; line++) {
      int? start;
      var gap = 0;
      for (var i = 0; i < length; i++) {
        if (at(line, i)) {
          start ??= i;
          gap = 0;
          if (i - start + 1 > best) best = i - start + 1;
        } else if (start != null && ++gap > _maxGap) {
          start = null;
        }
      }
    }
    return best;
  }

  return (
    horizontal: longest(h, w, (y, x) => lime(x, y)),
    vertical: longest(w, h, (x, y) => lime(x, y)),
  );
}

const _maxGap = 3;

/// Pumps until the render pump has gone quiet: nothing rasterized, laid
/// out or drawn into a tile for half a second. Loads going quiet is not
/// enough where a test depends on every finished tile having reached
/// the result cache — on a slow machine (and on web, with no isolates)
/// the pump can still be working through the last of them.
Future<void> settleRendering(WidgetTester tester) async {
  var last = (-1, -1, -1);
  var since = DateTime.now();
  final settled = await pumpUntil(tester, () async {
    final now = (
      TileRasterizer.debugRasterizeCount,
      SymbolLayouter.debugLayoutCount,
      LabelPainter.debugTilePaintMicros,
    );
    if (now != last) {
      last = now;
      since = DateTime.now();
    }
    return DateTime.now().difference(since) >=
        const Duration(milliseconds: 500);
  });
  expect(settled, isTrue, reason: 'the render pump never went quiet');
}

/// A candidate for the `poi` layer of [labelTheme] at [anchor], in
/// logical tile coordinates.
SymbolInstance poi(Theme theme, Offset anchor, {String text = 'AAAA'}) =>
    SymbolInstance(
      layer: theme.layers[2] as SymbolThemeLayer,
      layerIndex: 2,
      anchor: anchor,
      angle: 0,
      alongLine: false,
      text: text,
      iconName: null,
      sortKey: 0,
      properties: const {'name': 'AAAA'},
      geometryType: 'Point',
      featureId: null,
    );

/// Runs [LabelPainter.paintTile] over [symbols] into a throwaway
/// recording and returns the texts it drew.
List<String> paintTile(LabelPainter painter, List<SymbolInstance> symbols) {
  final recorder = ui.PictureRecorder();
  final drawn = painter.paintTile(
    canvas: Canvas(recorder),
    symbols: symbols,
    styleZoom: 14,
  );
  recorder.endRecording().dispose();
  return [for (final symbol in drawn) symbol.instance.text];
}

void main() {
  setUp(VectorTileLayer.clearMemoryCache);

  group('LabelPainter.paintTile', () {
    test('draws the labels that fit inside the tile', () {
      final painter = LabelPainter();
      addTearDown(painter.dispose);
      final theme = labelTheme();
      expect(
          paintTile(painter, [poi(theme, const Offset(128, 128))]), ['AAAA']);
    });

    test('drops a label that would cross the tile edge', () {
      // 160 px of text centred 6 px from the right edge: the neighbour
      // tile never sees this candidate, so half of it would be cut off.
      final painter = LabelPainter();
      addTearDown(painter.dispose);
      final theme = labelTheme();
      final edge = poi(theme, const Offset(250, 128));
      expect(paintTile(painter, [edge]), isEmpty);

      // Control: the screen pass draws it — a label may run off the
      // screen there, since nothing else would draw the rest of it.
      final recorder = ui.PictureRecorder();
      final drawn = painter.paint(
        canvas: Canvas(recorder),
        screenSize: const Size.square(256),
        styleZoom: 14,
        symbols: [
          PlacedSymbol(
              instance: edge, screenAnchor: edge.anchor, screenAngle: 0),
        ],
        placementGeneration: 1,
      );
      recorder.endRecording().dispose();
      expect(drawn, hasLength(1));
    });

    test('drops an allow-overlap label at the tile edge too', () {
      // `text-allow-overlap` skips collision, but not the tile's bounds.
      final painter = LabelPainter();
      addTearDown(painter.dispose);
      final theme = labelTheme(allowOverlap: true);
      expect(
        paintTile(painter, [
          poi(theme, const Offset(128, 100)),
          poi(theme, const Offset(128, 110), text: 'AAAB'),
          poi(theme, const Offset(250, 200), text: 'AAAC'),
        ]),
        unorderedEquals(['AAAA', 'AAAB']),
      );
    });

    test('resolves collisions within the tile', () {
      final painter = LabelPainter();
      addTearDown(painter.dispose);
      final theme = labelTheme();
      expect(
        paintTile(painter, [
          poi(theme, const Offset(128, 100)),
          poi(theme, const Offset(128, 110), text: 'AAAB'),
        ]),
        hasLength(1),
      );
    });

    test('leaves the screen pass and its counters alone', () {
      final painter = LabelPainter();
      addTearDown(painter.dispose);
      final theme = labelTheme();
      final candidate = poi(theme, const Offset(128, 128));
      final paintMicros = LabelPainter.debugPaintMicros;
      final placingFrames = LabelPainter.debugPlacingFrames;
      final tileMicros = LabelPainter.debugTilePaintMicros;

      expect(paintTile(painter, [candidate]), hasLength(1));

      expect(
          painter.debugPlacement
              .lookup(candidate.continuityKey, candidate.anchor),
          isNull,
          reason: 'a tile pass keeps no placement memory');
      expect(painter.hasActiveFades, isFalse);
      expect(painter.placementPending, isFalse);
      expect(LabelPainter.debugPaintMicros, paintMicros);
      expect(LabelPainter.debugPlacingFrames, placingFrames);
      expect(LabelPainter.debugTilePaintMicros, greaterThan(tileMicros));
    });
  });

  group('LabelMode.tile', () {
    testWidgets('draws labels into the tiles and runs no per-frame pass',
        (tester) async {
      tester.view.physicalSize = const Size(600, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final paintMicros = LabelPainter.debugPaintMicros;
      final placingFrames = LabelPainter.debugPlacingFrames;
      final tileMicros = LabelPainter.debugTilePaintMicros;
      final provider = EverywhereProvider(labelledTile());
      final controller = MapController();
      final theme = labelTheme();
      final providers = TileProviders({'s': provider});
      await tester.pumpWidget(labelModeApp(controller, providers, theme,
          labelMode: LabelMode.tile));
      expect(
          await pumpUntil(tester, () => hasColor(tester, labelColor)), isTrue);
      await settleLabelled(tester, provider);

      // A moving map: still no label pass.
      for (var i = 1; i <= 5; i++) {
        controller.move(LatLng(48.1725 + i * 0.002, 11.7375), 14);
        await tester.pump(const Duration(milliseconds: 16));
      }
      await settleLabelled(tester, provider);
      expect(await hasColor(tester, labelColor), isTrue);
      expect(await hasColor(tester, land), isTrue);

      expect(LabelPainter.debugPaintMicros, paintMicros,
          reason: 'no frame ran the screen-space label pass');
      expect(LabelPainter.debugPlacingFrames, placingFrames);
      expect(LabelPainter.debugTilePaintMicros, greaterThan(tileMicros),
          reason: 'the labels were drawn by the tile pass');

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    for (final mode in LabelMode.values) {
      testWidgets('${mode.name} mode: labels under a 90° rotation',
          (tester) async {
        tester.view.physicalSize = const Size(600, 600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        final provider = EverywhereProvider(labelledTile());
        final controller = MapController();
        final theme = labelTheme();
        final providers = TileProviders({'s': provider});
        await tester.pumpWidget(
            labelModeApp(controller, providers, theme, labelMode: mode));
        await settleLabelled(tester, provider);
        await pumpUntil(tester, () => hasColor(tester, labelColor));
        final upright = await labelRuns(tester);
        expect(upright.horizontal, greaterThan(upright.vertical * 2),
            reason: 'unrotated, "AAAA" runs left to right');

        controller.rotate(90);
        await settleLabelled(tester, provider);
        await pumpUntil(tester, () => hasColor(tester, labelColor));
        final rotated = await labelRuns(tester);
        if (mode == LabelMode.tile) {
          expect(rotated.vertical, greaterThan(rotated.horizontal * 2),
              reason: 'text drawn into the tile turns with it');
        } else {
          expect(rotated.horizontal, greaterThan(rotated.vertical * 2),
              reason: 'screen-space text stays upright');
        }

        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      });
    }

    testWidgets('the finished-tile cache keeps the two modes apart',
        (tester) async {
      tester.view.physicalSize = const Size(600, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final provider = EverywhereProvider(labelledTile());
      final controller = MapController();
      final theme = labelTheme();
      final providers = TileProviders({'s': provider});
      await tester.pumpWidget(labelModeApp(controller, providers, theme,
          labelMode: LabelMode.screen));
      await settleLabelled(tester, provider);
      expect(
          await pumpUntil(tester, () => hasColor(tester, labelColor)), isTrue);

      // Switching to tile mode must render the tiles again: a cached
      // screen-mode tile has no labels in its image.
      final screenRasters = TileRasterizer.debugRasterizeCount;
      final paintMicros = LabelPainter.debugPaintMicros;
      await tester.pumpWidget(labelModeApp(controller, providers, theme,
          labelMode: LabelMode.tile));
      expect(
          await pumpUntil(tester, () => hasColor(tester, labelColor)), isTrue);
      await settleLabelled(tester, provider);
      await settleRendering(tester);
      expect(TileRasterizer.debugRasterizeCount, greaterThan(screenRasters),
          reason: 'a tile-mode tile is never served from the screen cache');
      expect(await hasColor(tester, land), isTrue,
          reason: 'the labelled tiles carry their geometry too');
      expect(LabelPainter.debugPaintMicros, paintMicros);

      // And back: the screen-mode tiles are still cached.
      final tileRasters = TileRasterizer.debugRasterizeCount;
      await tester.pumpWidget(labelModeApp(controller, providers, theme,
          labelMode: LabelMode.screen));
      expect(
          await pumpUntil(tester, () => hasColor(tester, labelColor)), isTrue);
      await settleLabelled(tester, provider);
      await settleRendering(tester);
      expect(TileRasterizer.debugRasterizeCount, tileRasters,
          reason: 'served from the screen-mode cache');
      expect(provider.reloads, 0);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('disabling showLabels renders the tiles again without labels',
        (tester) async {
      tester.view.physicalSize = const Size(600, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final provider = EverywhereProvider(labelledTile());
      final controller = MapController();
      final theme = labelTheme();
      final providers = TileProviders({'s': provider});
      await tester.pumpWidget(labelModeApp(controller, providers, theme,
          labelMode: LabelMode.tile));
      expect(
          await pumpUntil(tester, () => hasColor(tester, labelColor)), isTrue);
      await settleLabelled(tester, provider);

      await tester.pumpWidget(labelModeApp(controller, providers, theme,
          labelMode: LabelMode.tile, showLabels: false));
      expect(
          await pumpUntil(
              tester, () async => !await hasColor(tester, labelColor)),
          isTrue,
          reason: 'the labels are in the tile images, which must be '
              'replaced');
      expect(await hasColor(tester, land), isTrue);

      await tester.pumpWidget(labelModeApp(controller, providers, theme,
          labelMode: LabelMode.tile, showLabels: true));
      expect(
          await pumpUntil(tester, () => hasColor(tester, labelColor)), isTrue);
      expect(provider.reloads, 0,
          reason: 'both re-renders reuse the decoded tiles');

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    for (final (settled, sliced) in [
      (true, false),
      (false, false),
      (true, true),
      (false, true),
    ]) {
      testWidgets(
          'leaks no image or picture (disposed '
          '${settled ? 'after settling' : 'with work still queued'}'
          '${sliced ? ', one layer or label per frame' : ''})', (tester) async {
        if (sliced) {
          VectorTileLayer.debugPumpBudgetMicros = 0;
          addTearDown(() => VectorTileLayer.debugPumpBudgetMicros = null);
        }
        tester.view.physicalSize = const Size(600, 600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        // Image and picture creations minus disposals from here on.
        // Counted rather than matched by identity: on web an image
        // reports one creation for all its clones, and its disposal
        // once the last of them goes, through whichever handle that was.
        var images = 0, pictures = 0;
        void track(ObjectEvent event) {
          if (snapshotting) return;
          final delta = switch (event) {
            ObjectCreated() => 1,
            ObjectDisposed() => -1,
            _ => 0,
          };
          if (event.object is ui.Image) images += delta;
          if (event.object is ui.Picture) pictures += delta;
        }

        FlutterMemoryAllocations.instance.addListener(track);
        addTearDown(
            () => FlutterMemoryAllocations.instance.removeListener(track));

        final provider = EverywhereProvider(labelledTile());
        final controller = MapController();
        final theme = labelTheme();
        final providers = TileProviders({'s': provider});
        await tester.pumpWidget(labelModeApp(controller, providers, theme,
            labelMode: LabelMode.tile));
        if (settled) {
          await settleLabelled(tester, provider);
          // Off to where every tile is new, then back.
          controller.move(const LatLng(48.3, 11.9), 14);
          await settleLabelled(tester, provider);
          controller.move(const LatLng(48.1725, 11.7375), 14);
          await settleLabelled(tester, provider);
        } else {
          await tester.pump(const Duration(milliseconds: 16));
          await tester.pump(const Duration(milliseconds: 16));
        }

        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        // Late loads land on a disposed layer and must let go of what
        // they carry.
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 200)));
        await tester.pump();
        // Finished tiles outlive the layer on purpose, for a warm
        // reopen; this is what releases them.
        VectorTileLayer.clearMemoryCache();

        expect(images, 0, reason: 'images created but never disposed');
        expect(pictures, 0, reason: 'pictures created but never disposed');
      });
    }
  });

  group('with every layer and label in a frame of its own', () {
    setUp(() => VectorTileLayer.debugPumpBudgetMicros = 0);
    tearDown(() => VectorTileLayer.debugPumpBudgetMicros = null);

    for (final mode in LabelMode.values) {
      testWidgets('${mode.name} mode: the map comes out the same',
          (tester) async {
        tester.view.physicalSize = const Size(600, 600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        Future<({Uint8List pixels, int rasterized, int slices})>
            render() async {
          final rasterized = TileRasterizer.debugRasterizeCount;
          final slices = TileRasterizer.debugSliceCount;
          final provider = EverywhereProvider(labelledTile());
          await tester.pumpWidget(labelModeApp(
              MapController(), TileProviders({'s': provider}), labelTheme(),
              labelMode: mode));
          await settleLabelled(tester, provider);
          await settleRendering(tester);
          await tester.pump(const Duration(seconds: 1)); // fades done
          final (data, _, _) = await snapshot(tester);
          await tester.pumpWidget(const SizedBox());
          // The second render must not be served from the first one's
          // finished tiles.
          VectorTileLayer.clearMemoryCache();
          return (
            pixels: data.buffer.asUint8List(),
            rasterized: TileRasterizer.debugRasterizeCount - rasterized,
            slices: TileRasterizer.debugSliceCount - slices,
          );
        }

        final sliced = await render();
        VectorTileLayer.debugPumpBudgetMicros = null;
        final whole = await render();

        // Two layers draw: the background and the land.
        expect(sliced.rasterized, greaterThan(0));
        expect(sliced.slices, 2 * sliced.rasterized,
            reason: 'every recording took one frame per layer');
        expect(listEquals(sliced.pixels, whole.pixels), isTrue);
      });
    }

    testWidgets('a refresh finishes each recording before it starts the next',
        (tester) async {
      tester.view.physicalSize = const Size(600, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final provider = EverywhereProvider(labelledTile());
      final controller = MapController();
      final providers = TileProviders({'s': provider});
      final theme = threeLayerTheme();
      await tester.pumpWidget(labelModeApp(controller, providers, theme,
          labelMode: LabelMode.tile));
      await settleLabelled(tester, provider);
      await settleRendering(tester);

      // Re-renders every live tile at once. The tiles must come out one
      // after the other, not take turns a layer each.
      final rasterized = TileRasterizer.debugRasterizeCount;
      final slices = TileRasterizer.debugSliceCount;
      await tester.pumpWidget(labelModeApp(controller, providers, theme,
          labelMode: LabelMode.tile, showLabels: false));
      for (var frame = 0; frame < 200; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        final started = TileRasterizer.debugRasterizeCount - rasterized;
        final recorded = TileRasterizer.debugSliceCount - slices;
        expect(recorded, greaterThan(3 * (started - 1)),
            reason: 'a recording started before the one ahead finished');
        if (started >= 4 && recorded == 3 * started) break;
      }
      expect(TileRasterizer.debugRasterizeCount - rasterized,
          greaterThanOrEqualTo(4));
      await settleLabelled(tester, provider);
    });

    testWidgets("tile mode places a tile's labels in a frame of their own",
        (tester) async {
      tester.view.physicalSize = const Size(600, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final provider = EverywhereProvider(labelledTile());
      await tester.pumpWidget(labelModeApp(
          MapController(), TileProviders({'s': provider}), labelTheme(),
          labelMode: LabelMode.tile));
      // Every tile shapes its label ("AAAA", so only the first one
      // really shapes) and then places, draws and snapshots it. With a
      // budget of nothing, the shaping spends its frame: the rest must
      // wait for the next one rather than run on top.
      final start = LabelPainter.debugTilePaintCount;
      var shaped = LabelPainter.debugShapeMicros;
      var painted = start;
      var both = 0;
      expect(
          await pumpUntil(tester, () async {
            final nowShaped = LabelPainter.debugShapeMicros;
            final nowPainted = LabelPainter.debugTilePaintCount;
            if (nowShaped > shaped && nowPainted > painted) both++;
            shaped = nowShaped;
            painted = nowPainted;
            return painted - start >= 4;
          }),
          isTrue);
      expect(both, 0, reason: 'a frame shaped a label and placed a tile');
      await settleLabelled(tester, provider);
    });

    testWidgets('the first frame of a camera move pumps on the moving budget',
        (tester) async {
      tester.view.physicalSize = const Size(600, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      VectorTileLayer.debugPumpCameraStill = null;
      addTearDown(() => VectorTileLayer.debugPumpCameraStill = null);

      final controller = MapController();
      final provider = EverywhereProvider(labelledTile());
      await tester.pumpWidget(labelModeApp(
          controller, TileProviders({'s': provider}), labelTheme(),
          labelMode: LabelMode.screen));
      // Until the pump has work, which one unit per frame keeps it busy
      // with for many frames more.
      expect(
          await pumpUntil(
              tester, () async => VectorTileLayer.debugPumpCameraStill != null),
          isTrue);
      expect(VectorTileLayer.debugPumpCameraStill, isTrue,
          reason: 'the camera has not moved yet');

      // The pump runs ahead of the build that sees the new camera; the
      // move event is what tells it in time.
      controller.move(const LatLng(48.18, 11.75), 14);
      VectorTileLayer.debugPumpCameraStill = null;
      await tester.pump();
      expect(VectorTileLayer.debugPumpCameraStill, isFalse);
      // Left loading, the web executor's timers would outlive the test.
      await settleLabelled(tester, provider);
    });

    testWidgets('a memory trim mid-shaping still finishes every tile',
        (tester) async {
      tester.view.physicalSize = const Size(600, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final provider = EverywhereProvider(labelledTile());
      await tester.pumpWidget(labelModeApp(
          MapController(), TileProviders({'s': provider}), labelTheme(),
          labelMode: LabelMode.tile));
      // Trimmed as soon as a label is shaped: the tiles still queued
      // rewind their shaping, which the pump then redoes.
      final shaped = LabelPainter.debugShapeMicros;
      expect(
          await pumpUntil(
              tester, () async => LabelPainter.debugShapeMicros > shaped),
          isTrue);
      VectorTileLayer.clearMemoryCache();
      await settleLabelled(tester, provider);
      await settleRendering(tester);
      expect(await hasColor(tester, labelColor), isTrue);
    });

    testWidgets('a layer disposed mid-recording lets go of the slices',
        (tester) async {
      tester.view.physicalSize = const Size(600, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      var pictures = 0;
      void track(ObjectEvent event) {
        if (event.object is! ui.Picture || snapshotting) return;
        if (event is ObjectCreated) pictures++;
        if (event is ObjectDisposed) pictures--;
      }

      FlutterMemoryAllocations.instance.addListener(track);
      addTearDown(
          () => FlutterMemoryAllocations.instance.removeListener(track));

      // Three layers that draw: the frame `pumpWidget` still runs
      // before it unmounts the map records a second one, and the third
      // must still be to come when the layer goes.
      final provider = EverywhereProvider(labelledTile());
      final rasterized = TileRasterizer.debugRasterizeCount;
      final slices = TileRasterizer.debugSliceCount;
      await tester.pumpWidget(labelModeApp(
          MapController(), TileProviders({'s': provider}), threeLayerTheme(),
          labelMode: LabelMode.tile));
      // Until a tile has one layer recorded and two to come.
      expect(
          await pumpUntil(
              tester,
              () async =>
                  TileRasterizer.debugSliceCount - slices ==
                  3 * (TileRasterizer.debugRasterizeCount - rasterized) - 2),
          isTrue);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump();
      VectorTileLayer.clearMemoryCache();

      expect(pictures, 0, reason: 'pictures created but never disposed');
    });
  });
}
