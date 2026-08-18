@TestOn('vm')
library;

import 'package:flutter/material.dart' hide Theme;
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_vector_tiles/flutter_map_vector_tiles.dart';
import 'package:flutter_map_vector_tiles/src/render/tile_rasterizer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'fixtures/lifecycle_harness.dart';

/// iOS revokes GPU access for the whole process while an app is
/// backgrounded, and Impeller fills a `toImageSync` texture whose Metal
/// work was rejected with solid magenta rather than failing. Nothing
/// above the rasterizer can tell such an image from a real tile, so it
/// paints and — because finished results are cached process-wide — is
/// served for the rest of the process. The layer's defence is twofold:
/// do not rasterize while the app is away, and treat everything
/// rasterized before a backgrounding as suspect once it comes back.
///
/// This covers a *workaround*, not a permanent design commitment: the
/// engine already parks async snapshots when the GPU is disabled and
/// simply does not do so for the sync path. See the block above
/// `_foregrounded` in `vector_tile_layer.dart` for the upstream detail
/// and for when this file can be deleted along with the workaround.
void main() {
  setUp(VectorTileLayer.clearMemoryCache);

  /// The transition chain iOS actually delivers on the way out; the
  /// framework walks every intermediate state rather than jumping.
  Future<void> background(WidgetTester tester) async {
    for (final state in const [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pump();
  }

  Future<void> foreground(WidgetTester tester) async {
    for (final state in const [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pump();
  }

  Future<void> openMap(WidgetTester tester, CountingProvider provider) async {
    tester.view.physicalSize = const Size(600, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app(MapController(), provider));
    await settleLoads(tester, provider);
  }

  testWidgets('nothing rasterizes while the app is leaving', (tester) async {
    // `inactive` is the whole reason this gate exists. The scheduler
    // keeps frames enabled through it, so the pump goes on running while
    // iOS is taking the app away — and from `hidden` on there are no
    // frames to gate at all (which is also why the pumps below would do
    // nothing if this test backgrounded the app the whole way).
    final provider = EverywhereProvider(fullTile());
    final controller = MapController();
    tester.view.physicalSize = const Size(600, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app(controller, provider));
    await settleLoads(tester, provider);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    final rasters = TileRasterizer.debugRasterizeCount;
    final loads = provider.loads;

    // A screenful of tiles the layer has never seen. They load — the
    // stores and the decode isolates know nothing about the lifecycle —
    // but not one of them may reach `toImageSync`.
    controller.move(const LatLng(52.5163, 13.3777), 14);
    await pumpUntil(tester, () async => provider.loads > loads);
    await pumpUntil(tester, () async => false,
        timeout: const Duration(seconds: 2));

    expect(provider.loads, greaterThan(loads),
        reason: 'loading must carry on while the app is on its way out');
    expect(TileRasterizer.debugRasterizeCount, rasters,
        reason: 'a raster made now would come back magenta');

    // And the parked work is not lost: it rasterizes on the way back in.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(await settle(tester), isTrue);
    expect(TileRasterizer.debugRasterizeCount, greaterThan(rasters));
  });

  testWidgets('resuming re-rasterizes what was on screen', (tester) async {
    final provider = EverywhereProvider(fullTile());
    await openMap(tester, provider);

    final rasters = TileRasterizer.debugRasterizeCount;
    final loads = provider.loads;
    await background(tester);
    await foreground(tester);

    expect(
      await pumpUntil(
          tester, () async => TileRasterizer.debugRasterizeCount > rasters),
      isTrue,
      reason: 'the imagery standing on screen was made before the app went '
          'away, so it has to be replaced',
    );
    expect(await centrePixel(tester), land);
    // Recovery is a re-rasterize, not a reload: the decoded geometry
    // never left the Dart heap.
    expect(provider.loads, loads);
  });

  testWidgets('a layer mounted after the return distrusts the cache too',
      (tester) async {
    // Reopening a map normally paints straight out of the finished-result
    // cache without rasterizing anything — that is what the cache is for.
    // But the layer that filled it can be gone by the time the app comes
    // back: a map screen rebuilt on the way in is a brand-new layer that
    // lived through no backgrounding of its own, and it must not be
    // handed textures nobody was left mounted to condemn.
    final provider = EverywhereProvider(fullTile());
    await openMap(tester, provider);

    await background(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    final rasters = TileRasterizer.debugRasterizeCount;
    await foreground(tester);

    await tester.pumpWidget(app(MapController(), provider));
    expect(
      await pumpUntil(
          tester, () async => TileRasterizer.debugRasterizeCount > rasters),
      isTrue,
      reason: 'a cache holding possibly-magenta textures must not be reused',
    );
    expect(await centrePixel(tester), land);
  });

  testWidgets('a passing dialog costs nothing', (tester) async {
    final provider = EverywhereProvider(fullTile());
    await openMap(tester, provider);

    // iOS revokes the context in `applicationDidEnterBackground`, which
    // a permission dialog or a control-centre swipe never reaches — they
    // stop at `inactive`. Re-rasterizing a screenful for one of those
    // would be pure waste, several times a session.
    final rasters = TileRasterizer.debugRasterizeCount;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await pumpUntil(tester, () async => false,
        timeout: const Duration(seconds: 2));

    expect(TileRasterizer.debugRasterizeCount, rasters);
    expect(await centrePixel(tester), land);
  });
}
