import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_vector_tiles/flutter_map_vector_tiles.dart';
import 'package:flutter_map_vector_tiles/src/render/label_painter.dart';
import 'package:flutter_map_vector_tiles/src/render/tile_rasterizer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'fixtures/lifecycle_harness.dart';
import 'label_mode_test.dart'
    show hasColor, labelColor, labelModeApp, labelTheme, labelledTile;

/// What Flutter web sends once the fallback fonts it fetched for text
/// none of its fonts covered have arrived: until then that text was
/// laid out in `.notdef` boxes, and stays that way unless shaped again.
/// (`test/scripts/font_arrival_test.dart` shows the boxes going, with
/// real fonts.)
Future<void> fontsChange(WidgetTester tester) =>
    tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'flutter/system',
      const JSONMessageCodec().encodeMessage({'type': 'fontsChange'}),
      (_) {},
    );

void main() {
  setUp(VectorTileLayer.clearMemoryCache);
  _tileModeTests();

  for (final mode in LabelMode.values) {
    testWidgets(
        '${mode.name} mode: a font change shapes the labels again on the '
        'web, and nowhere else', (tester) async {
      tester.view.physicalSize = const Size(600, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final provider = EverywhereProvider(labelledTile());
      await tester.pumpWidget(labelModeApp(
          MapController(), TileProviders({'s': provider}), labelTheme(),
          labelMode: mode));
      expect(
          await pumpUntil(tester, () => hasColor(tester, labelColor)), isTrue);
      await settleLoads(tester, provider, painted: false);

      final shaped = LabelPainter.debugParagraphShapes;
      final rasterized = TileRasterizer.debugRasterizeCount;
      await fontsChange(tester);
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      if (kIsWeb) {
        expect(LabelPainter.debugParagraphShapes, greaterThan(shaped),
            reason: 'the labels shaped before the change are shaped again');
        if (mode == LabelMode.tile) {
          expect(TileRasterizer.debugRasterizeCount, greaterThan(rasterized),
              reason: 'the tiles their labels are drawn into are redrawn');
        }
      } else {
        // The fallback fonts are the installed ones, found during
        // layout; a font loaded later is the app's own, by name.
        expect(LabelPainter.debugParagraphShapes, shaped);
        expect(TileRasterizer.debugRasterizeCount, rasterized);
      }
      expect(await hasColor(tester, labelColor), isTrue,
          reason: 'the labels are still on the map');

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  }

  testWidgets(
      'screen mode: once the pump is through, no label draws in the old '
      'fonts, at the zoom the camera is at or one it comes back to',
      (tester) async {
    tester.view.physicalSize = const Size(600, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final controller = MapController();
    final provider = EverywhereProvider(labelledTile());
    await tester.pumpWidget(labelModeApp(
        controller, TileProviders({'s': provider}), _zoomedLabelTheme(),
        labelMode: LabelMode.screen));
    expect(await pumpUntil(tester, () => hasColor(tester, labelColor)), isTrue);
    await settleLoads(tester, provider, painted: false);

    Future<void> moveTo(double zoom, {double east = 0}) async {
      final center = controller.camera.center;
      controller.move(LatLng(center.latitude, center.longitude + east), zoom);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await settleLoads(tester, provider, painted: false);
    }

    // The label is looked up at each eighth of a zoom level the camera
    // stops at; the fonts change while it is at the second.
    await moveTo(14.5);
    await moveTo(14.75);
    final inFrames = LabelPainter.debugFrameShapes;
    await fontsChange(tester);
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    final lookups = LabelPainter.debugOldFontLookups;
    await moveTo(14.75, east: 0.0005);
    expect(LabelPainter.debugOldFontLookups, lookups,
        reason: 'shaped again at the camera zoom, not only the tile zoom');
    expect(LabelPainter.debugFrameShapes, inFrames,
        reason: 'by the pump, not by a frame');
    await moveTo(14.5);
    expect(LabelPainter.debugOldFontLookups, lookups,
        reason: 'the shaping of a zoom the camera left is dropped');
    expect(await hasColor(tester, labelColor), isTrue,
        reason: 'the labels are still on the map');

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets(
      'screen mode: a trim between a font change and the pump shapes '
      'nothing, and the pump still shapes the labels again', (tester) async {
    tester.view.physicalSize = const Size(600, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final provider = EverywhereProvider(labelledTile());
    await tester.pumpWidget(labelModeApp(
        MapController(), TileProviders({'s': provider}), labelTheme(),
        labelMode: LabelMode.screen));
    expect(await pumpUntil(tester, () => hasColor(tester, labelColor)), isTrue);
    await settleLoads(tester, provider, painted: false);

    await fontsChange(tester);
    final shaped = LabelPainter.debugParagraphShapes;
    VectorTileLayer.clearMemoryCache();
    expect(LabelPainter.debugParagraphShapes, shaped,
        reason: 'the trim has no budget to shape them in');
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    if (kIsWeb) {
      expect(LabelPainter.debugParagraphShapes, greaterThan(shaped),
          reason: 'the pump does, within its budget');
    }
    expect(await hasColor(tester, labelColor), isTrue,
        reason: 'the labels are still on the map');

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}

/// Tile mode's tests below: [labelledTile] on the tiles whose x + y is
/// even, [fullTile] (land, no label) on the rest.
class _CheckerProvider extends CountingProvider {
  final labelled = labelledTile(), unlabelled = fullTile();

  @override
  String get cacheKey => 'checker';

  @override
  Future<TileResponse> load(TileKey tile,
      {CancellationToken? cancellation}) async {
    note(tile);
    return TileResponseData((tile.x + tile.y).isEven ? labelled : unlabelled);
  }
}

void _tileModeTests() {
  Future<void> open(WidgetTester tester, CountingProvider provider,
      TileProviders providers, Theme theme) async {
    await tester.pumpWidget(labelModeApp(MapController(), providers, theme,
        labelMode: LabelMode.tile));
    expect(await pumpUntil(tester, () => hasColor(tester, labelColor)), isTrue);
    await settleLoads(tester, provider, painted: false);
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  void sized(WidgetTester tester) {
    tester.view.physicalSize = const Size(600, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  testWidgets(
      'tile mode: a map opened again after a font change draws its '
      'cached tiles again, on the web', (tester) async {
    sized(tester);
    final provider = EverywhereProvider(labelledTile());
    final providers = TileProviders({'s': provider});
    final theme = labelTheme();
    await open(tester, provider, providers, theme);
    await close(tester);

    // The fallback fonts arrive with no map open to hear it.
    await fontsChange(tester);
    final rasterized = TileRasterizer.debugRasterizeCount;
    await open(tester, provider, providers, theme);
    await settle(tester);
    if (kIsWeb) {
      expect(TileRasterizer.debugRasterizeCount, greaterThan(rasterized),
          reason: 'cached with their labels in boxes, so drawn again');
    } else {
      expect(TileRasterizer.debugRasterizeCount, rasterized,
          reason: 'served from the cache');
    }
    await close(tester);
  });

  testWidgets(
      'tile mode: a map opened from the cache draws its tiles again '
      'when the fonts change, on the web', (tester) async {
    sized(tester);
    final provider = EverywhereProvider(labelledTile());
    final providers = TileProviders({'s': provider});
    final theme = labelTheme();
    await open(tester, provider, providers, theme);
    await close(tester);
    final rasterized = TileRasterizer.debugRasterizeCount;
    await open(tester, provider, providers, theme);
    expect(TileRasterizer.debugRasterizeCount, rasterized,
        reason: 'served from the cache, so its painter shaped nothing');

    await fontsChange(tester);
    await settle(tester);
    if (kIsWeb) {
      expect(TileRasterizer.debugRasterizeCount, greaterThan(rasterized),
          reason: 'drawn again all the same');
    } else {
      expect(TileRasterizer.debugRasterizeCount, rasterized);
    }
    expect(await hasColor(tester, labelColor), isTrue);
    await close(tester);
  });

  testWidgets(
      'tile mode: a font change draws again only the tiles whose labels '
      'the platform shaped', (tester) async {
    sized(tester);
    final provider = _CheckerProvider();
    final rasterizedBefore = TileRasterizer.debugRasterizeCount;
    await open(tester, provider, TileProviders({'s': provider}), labelTheme());
    final rasterized = TileRasterizer.debugRasterizeCount;
    final tiles = rasterized - rasterizedBefore;

    await fontsChange(tester);
    await settle(tester);
    final redrawn = TileRasterizer.debugRasterizeCount - rasterized;
    if (kIsWeb) {
      expect(redrawn, greaterThan(0), reason: 'the labelled tiles');
      expect(redrawn, lessThan(tiles), reason: 'not the unlabelled ones');
    } else {
      expect(redrawn, 0);
    }
    await close(tester);
  });
}

/// [labelTheme]'s label at a size that follows the zoom, under a halo:
/// the halo's share of the size, part of the text's cache key, changes
/// from one eighth of a zoom level to the next.
Theme _zoomedLabelTheme() => const ThemeReader().read({
      'layers': [
        {
          'id': 'bg',
          'type': 'background',
          'paint': {'background-color': '#0000ff'},
        },
        {
          'id': 'poi',
          'type': 'symbol',
          'source': 's',
          'source-layer': 'poi',
          'layout': {
            'text-field': '{name}',
            'text-size': [
              'interpolate',
              ['linear'],
              ['zoom'],
              12,
              10,
              16,
              40,
            ],
          },
          'paint': {
            'text-color': '#00ff00',
            'text-halo-color': '#ffffff',
            'text-halo-width': 2,
          },
        },
      ],
    });
