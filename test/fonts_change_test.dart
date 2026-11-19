import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_vector_tiles/flutter_map_vector_tiles.dart';
import 'package:flutter_map_vector_tiles/src/render/label_painter.dart';
import 'package:flutter_map_vector_tiles/src/render/tile_rasterizer.dart';
import 'package:flutter_test/flutter_test.dart';

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
}
