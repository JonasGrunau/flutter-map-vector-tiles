@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:flutter_map_vector_tiles/src/render/heatmap_density.dart';
import 'package:flutter_map_vector_tiles/src/render/heatmap_worker_isolate.dart';
import 'package:flutter_test/flutter_test.dart';

/// The native heatmap worker's isolate: what a job does when the
/// isolate is there, and when it is not.

HeatmapJob _job() => HeatmapJob(
      coverLeft: 0,
      coverTop: 0,
      coverWidth: 64,
      coverHeight: 64,
      devicePixelRatio: 1,
      peakScale: HeatmapGrid.peakFactor,
      ramp: Uint32List(256)..fillRange(0, 256, 0xffffffff),
      tiles: [
        HeatmapTileInput(
          left: 0,
          top: 0,
          scale: 1,
          xy: Float32List.fromList([32, 32]),
          weight: 1,
          radius: 10,
        ),
      ],
    );

void main() {
  test('jobs render on the isolate', () async {
    final worker = PlatformHeatmapWorker();
    addTearDown(worker.dispose);
    for (var i = 0; i < 2; i++) {
      final result =
          await worker.render(_job()).timeout(const Duration(seconds: 10));
      expect(result, isNotNull);
    }
  });

  test('an isolate that dies before its handshake leaves jobs inline',
      () async {
    // Regression: the exit was listened to only after the handshake, so
    // an isolate dying before it left every job waiting forever.
    PlatformHeatmapWorker.debugExitBeforeHandshake = true;
    addTearDown(() => PlatformHeatmapWorker.debugExitBeforeHandshake = false);
    final worker = PlatformHeatmapWorker();
    addTearDown(worker.dispose);
    for (var i = 0; i < 2; i++) {
      final result =
          await worker.render(_job()).timeout(const Duration(seconds: 10));
      expect(result, isNotNull, reason: 'rendered on the event loop');
    }
  });
}
