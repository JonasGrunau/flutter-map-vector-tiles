import 'dart:typed_data';

import 'package:flutter/material.dart' hide Theme;
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_vector_tiles/flutter_map_vector_tiles.dart';
import 'package:flutter_map_vector_tiles/src/grid/tile_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/lifecycle_harness.dart';

/// Fails every load until [failing] is cleared — a network outage.
class OutageProvider extends VectorTileProvider {
  final Uint8List bytes;
  var failing = true;
  var loads = 0;

  OutageProvider(this.bytes);

  @override
  int get maximumZoom => 20;
  @override
  int get minimumZoom => 0;
  @override
  String get cacheKey => 'outage';

  @override
  Future<TileResponse> load(TileKey tile,
      {CancellationToken? cancellation}) async {
    loads++;
    if (failing) return TileResponseError(Exception('offline'));
    return TileResponseData(bytes);
  }
}

void main() {
  setUp(() {
    VectorTileLayer.clearMemoryCache();
    // The failure throttle gates retries on the real wall clock, which a
    // widget test cannot advance — collapse it so the layer's retry
    // timer (fake clock) is the only gate.
    TileStore.errorRetryDelay = Duration.zero;
  });
  tearDown(() {
    TileStore.errorRetryDelay = const Duration(seconds: 15);
  });

  testWidgets('tiles recover after a transient outage', (tester) async {
    // Regression: a tile whose source load failed transiently used to
    // finalize without that source and nothing ever re-asked — the tile
    // stayed blank until an integer-zoom change or a pan out and back.
    tester.view.physicalSize = const Size(600, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final provider = OutageProvider(fullTile());
    await tester.pumpWidget(app(MapController(), provider));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
    }
    expect(await centrePixel(tester), background,
        reason: 'every load failed — tiles finalize without the source');
    final failedLoads = provider.loads;
    expect(failedLoads, greaterThan(0));

    provider.failing = false;
    await tester.pump(const Duration(seconds: 2)); // retry timers fire
    await settle(tester);

    expect(await centrePixel(tester), land,
        reason: 'the scheduled retry must recover the tiles');
    expect(provider.loads, greaterThan(failedLoads));

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('retries stop once the budget is exhausted', (tester) async {
    tester.view.physicalSize = const Size(600, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final provider = OutageProvider(fullTile());
    await tester.pumpWidget(app(MapController(), provider));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
    }

    // Let every scheduled retry fire and fail (budget is 4 per tile).
    for (var round = 0; round < 6; round++) {
      await tester.pump(const Duration(seconds: 2));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
    }
    final afterBudget = provider.loads;

    // No timer may fire any more.
    await tester.pump(const Duration(seconds: 30));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    expect(provider.loads, afterBudget,
        reason: 'the retry budget bounds load attempts while offline');

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
