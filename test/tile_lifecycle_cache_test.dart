@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart' hide Theme;
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_vector_tiles/flutter_map_vector_tiles.dart';
import 'package:flutter_map_vector_tiles/src/cache/disk_cache.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/lifecycle_harness.dart';

void main() {
  // Decoded tiles and disk caches are shared process-wide and outlive the
  // layer on purpose, so without this each test would inherit the previous
  // test's warm cache — and the load counts below would all read zero.
  setUp(() {
    VectorTileLayer.clearMemoryCache();
    DiskCacheRegistry.reset();
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

    final first = EverywhereProvider(fullTile());
    await tester.pumpWidget(
      app(MapController(), first, cachePath: () async => dir.path),
    );
    await settle(tester);
    expect(first.loads, greaterThan(0), reason: 'nothing was cached yet');

    await tester.pumpWidget(const SizedBox());
    await tester.pump();

    // Force the disk to be the only thing that can answer the second open,
    // and make it resolve late — the exact window the first frame's tiles
    // used to race past.
    VectorTileLayer.clearMemoryCache();
    DiskCacheRegistry.reset();
    final cacheReady = Completer<void>();
    final second = EverywhereProvider(fullTile());
    await tester.pumpWidget(app(
      MapController(),
      second,
      cachePath: () async {
        await cacheReady.future;
        return dir.path;
      },
    ));
    await tester.pump();
    cacheReady.complete();
    await settle(tester);

    expect(await centrePixel(tester), land);
    expect(second.loads, 0, reason: 'the screenful was already on disk');

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
