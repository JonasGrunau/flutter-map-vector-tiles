import 'dart:typed_data';

import 'package:flutter_map_vector_tiles/src/core/cancellation.dart';
import 'package:flutter_map_vector_tiles/src/pipeline/executor/direct_executor.dart';
import 'package:flutter_map_vector_tiles/src/pipeline/tile_processor.dart';
import 'package:flutter_test/flutter_test.dart';

/// The event-loop executor is the tile pipeline on web, where
/// `executor.dart` cannot resolve the isolate pool. These tests import it
/// directly so its contract is pinned on the VM and on chrome alike.
void main() {
  PrepareInput input({int z = 0}) => PrepareInput(
        z: z,
        x: 0,
        y: 0,
        bytes: Uint8List(0),
        layerProperties: const {},
      );

  test('completes a job', () async {
    final executor = PlatformExecutor(concurrency: 1);
    final result = await executor.prepare(input());
    expect(result, isNotNull);
    executor.dispose();
  });

  test('runs queued jobs in priority order, lower first', () async {
    final executor = PlatformExecutor(concurrency: 1);
    final order = <int>[];
    // The first job is dequeued immediately; the rest queue up during its
    // event-loop yield and must come out sorted by priority.
    final first = executor.prepare(input()).then((_) => order.add(0));
    final low =
        executor.prepare(input(), priority: 10).then((_) => order.add(10));
    final high =
        executor.prepare(input(), priority: 1).then((_) => order.add(1));
    await Future.wait([first, low, high]);
    expect(order, [0, 1, 10]);
    executor.dispose();
  });

  test('cancellation resolves null without throwing', () async {
    final executor = PlatformExecutor(concurrency: 1);
    final token = CancellationToken()..cancel();
    final result = await executor.prepare(input(), cancellation: token);
    expect(result, isNull);
    executor.dispose();
  });

  test('dispose resolves queued jobs with null', () async {
    final executor = PlatformExecutor(concurrency: 1);
    final futures =
        List.generate(4, (i) => executor.prepare(input(), priority: i));
    executor.dispose();
    final results = await Future.wait(futures);
    expect(results, everyElement(isNull));
  });
}
