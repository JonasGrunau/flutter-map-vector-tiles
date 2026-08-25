import 'package:flutter/material.dart' hide Theme;
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_vector_tiles/flutter_map_vector_tiles.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'fixtures/lifecycle_harness.dart';

/// The tile fade exists to mask fresh content popping in — it must not
/// run where it has nothing to cross-fade over, and the retained level
/// it cross-fades against must not outlive its usefulness.
void main() {
  setUp(() {
    VectorTileLayer.clearMemoryCache();
    VectorTileLayer.debugRetainedTileCount = 0;
  });

  testWidgets(
      'a cache-served screenful with nothing beneath paints at full '
      'opacity at once', (tester) async {
    // The zoom-out ring artefact, in its purest form: imagery served
    // straight from the finished-tile cache used to fade in over the
    // bare background — a background-coloured shimmer for content that
    // was ready all along. With nothing beneath it to cross-fade over,
    // it must simply appear.
    tester.view.physicalSize = const Size(600, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    // Warm the finished-tile cache with an instant-fade layer.
    final first = EverywhereProvider(fullTile());
    await tester.pumpWidget(app(MapController(), first));
    await settleLoads(tester, first);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();

    // Reopen with a fade so long it could never complete inside this
    // test: if the cached tiles fade at all, the centre stays a blend
    // of tile and background and the wait below times out.
    final second = EverywhereProvider(fullTile());
    await tester.pumpWidget(app(
      MapController(),
      second,
      tileFadeDuration: const Duration(minutes: 10),
    ));
    expect(
      await pumpUntil(tester, () async => (await centrePixel(tester)) == land,
          timeout: const Duration(seconds: 10)),
      isTrue,
      reason: 'cache-served tiles with nothing beneath them must paint at '
          'full opacity immediately instead of fading over the background',
    );

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets(
      'the retained level is released once the new one is ready, without '
      'another gesture', (tester) async {
    // The prune used to run only from `build`, and a build needs a
    // camera change: a crossing whose gesture had ended kept the whole
    // outgoing level — tile objects, symbol lists, image handles — in
    // memory (and painted it beneath the map) until the *next* gesture.
    // Readiness completing on a publish or a fade tick must release it.
    tester.view.physicalSize = const Size(600, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final provider = EverywhereProvider(fullTile());
    final controller = MapController();
    await tester.pumpWidget(app(
      controller,
      provider,
      tileFadeDuration: const Duration(milliseconds: 100),
    ));
    await settleLoads(tester, provider);

    // One zoom crossing, then not a single further camera change.
    controller.move(const LatLng(48.1725, 11.7375), 15);
    var sawRetained = false;
    final released = await pumpUntil(tester, () async {
      final count = VectorTileLayer.debugRetainedTileCount;
      if (count > 0) sawRetained = true;
      return sawRetained && count == 0;
    });
    expect(sawRetained, isTrue,
        reason: 'the crossing should have retained the outgoing level');
    expect(released, isTrue,
        reason: 'the retained level must be released once the new level '
            'is rendered and faded in — with no further gesture to '
            'trigger a rebuild');

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
