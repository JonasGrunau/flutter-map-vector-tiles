import 'package:flutter/material.dart' hide Theme;
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_vector_tiles/flutter_map_vector_tiles.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'fixtures/lifecycle_harness.dart';

void main() {
  // Decoded tiles are shared process-wide and outlive the layer on
  // purpose, so without this each test would inherit the previous test's
  // warm cache — and the load counts below would all read zero. These
  // tests run without a disk cache (see `app`); the disk-backed
  // lifecycle lives in tile_lifecycle_cache_test.dart.
  setUp(VectorTileLayer.clearMemoryCache);

  // Every test fixes the surface size, so the tile grid is the same on
  // every machine.
  Future<void> withMap(
    WidgetTester tester,
    Future<void> Function(MapController controller, EverywhereProvider p) body,
  ) async {
    tester.view.physicalSize = const Size(600, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final provider = EverywhereProvider(fullTile());
    final controller = MapController();
    await tester.pumpWidget(app(controller, provider));
    await settle(tester);
    await body(controller, provider);
    // Tear the layer down so its decode isolates shut down with the test.
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  }

  testWidgets('the map paints its tile fill over the background',
      (tester) async {
    await withMap(tester, (controller, provider) async {
      expect(await centrePixel(tester), land,
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
      final seen = await sampleDuring(tester, frames: 30);
      expect(seen, isNot(contains(background)),
          reason: 'the old level must cover the new one until it is ready');
      expect(seen, {land});
    });
  });

  testWidgets('zooming several levels at once never exposes the background',
      (tester) async {
    // A fast pinch outruns the decode pipeline entirely; provisional
    // imagery rendered from already-decoded ancestors has to cover it.
    await withMap(tester, (controller, provider) async {
      controller.move(const LatLng(48.1725, 11.7375), 17);
      final seen = await sampleDuring(tester, frames: 30);
      expect(seen, {land});
    });
  });

  testWidgets('zooming back out never exposes the background', (tester) async {
    await withMap(tester, (controller, provider) async {
      controller.move(const LatLng(48.1725, 11.7375), 12);
      final seen = await sampleDuring(tester, frames: 30);
      expect(seen, {land});
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
      await settle(tester);
      expect(await centrePixel(tester), land);
    });
  });

  testWidgets('returning to visited ground repaints without refetching',
      (tester) async {
    // The memory cache is what keeps a pan-away-and-back from hitting
    // the network again, so it must survive tiles leaving the viewport.
    await withMap(tester, (controller, provider) async {
      // The whole grid, not just the centre tile: a tile still in flight
      // when the pan starts is cancelled and fetched again on the way
      // back, which is not the refetch this test is looking for.
      await settleLoads(tester, provider);
      final afterFirstPaint = provider.loads;
      expect(afterFirstPaint, greaterThan(0));

      controller.move(const LatLng(48.60, 12.40), 14);
      await settle(tester);
      expect(provider.loads, greaterThan(afterFirstPaint),
          reason: 'new ground genuinely needs fetching');

      controller.move(const LatLng(48.1725, 11.7375), 14);
      await settle(tester);

      expect(await centrePixel(tester), land);
      // Not a `loads` snapshot taken before the move: the ground panned
      // away from is still filling in its buffer ring, and those loads
      // would be counted against the return trip.
      expect(provider.reloads, 0,
          reason: 'the original tiles should come back from memory');
    });
  });

  testWidgets('decoded tiles outlive the layer that loaded them',
      (tester) async {
    // With the tiles still decoded, a reopen needs neither the network
    // nor the disk.
    final provider = EverywhereProvider(fullTile());

    tester.view.physicalSize = const Size(600, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(app(MapController(), provider));
    // The whole grid, not just the centre tile: a tile still in flight
    // when the layer goes away never reached the decoded cache, so the
    // reopen fetches it again for a reason this test is not about.
    await settleLoads(tester, provider);
    final afterFirstOpen = provider.loads;
    expect(afterFirstOpen, greaterThan(0));

    await tester.pumpWidget(const SizedBox());
    await tester.pump();

    await tester.pumpWidget(app(MapController(), provider));
    await settle(tester);

    expect(await centrePixel(tester), land);
    expect(provider.loads, afterFirstOpen);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
