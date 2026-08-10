@TestOn('vm')
library;

import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_map_vector_tiles/src/pipeline/executor/executor.dart';
import 'package:flutter_map_vector_tiles/src/pipeline/executor/isolate_executor.dart';
import 'package:flutter_map_vector_tiles/src/pipeline/tile_processor.dart';
import 'package:flutter_test/flutter_test.dart';

void _echo(SendPort port) => port.send('hello');

PrepareInput _input(int x) => PrepareInput(
    z: 1, x: x, y: 0, bytes: Uint8List(0), layerProperties: const {});

void main() {
  test('raw Isolate.spawn works under flutter test', () async {
    final port = ReceivePort();
    await Isolate.spawn(_echo, port.sendPort);
    expect(await port.first, 'hello');
  });

  test('executor completes a job', () async {
    final executor = TilePrepareExecutor(concurrency: 1);
    final result = await executor.prepare(PrepareInput(
      z: 0,
      x: 0,
      y: 0,
      bytes: Uint8List(0),
      layerProperties: const {},
    ));
    expect(result, isNotNull);
    executor.dispose();
  });

  test('executor runs many jobs and cancels queued ones', () async {
    final executor = TilePrepareExecutor(concurrency: 2);
    final futures = List.generate(
      8,
      (i) => executor.prepare(
        PrepareInput(
            z: 1, x: 0, y: 0, bytes: Uint8List(0), layerProperties: const {}),
        priority: i,
      ),
    );
    final results = await Future.wait(futures);
    expect(results.whereType<Object>(), hasLength(8));
    executor.dispose();
  });

  test('failed spawns fall back to the event loop — and stay there', () async {
    PlatformExecutor.debugFailSpawns = true;
    addTearDown(() => PlatformExecutor.debugFailSpawns = false);
    final executor = PlatformExecutor(concurrency: 2);

    final first = await Future.wait(
        [executor.prepare(_input(0)), executor.prepare(_input(1))]);
    expect(first.whereType<Object>(), hasLength(2));

    // Regression: jobs enqueued after the first drain used to hang
    // forever — every pool slot was burned by a failed spawn, nothing
    // ran the queue, and the fallback was one-shot.
    final second =
        await executor.prepare(_input(2)).timeout(const Duration(seconds: 5));
    expect(second, isNotNull);
    executor.dispose();
  });

  test('a worker killed underneath the executor is replaced', () async {
    final executor = PlatformExecutor(concurrency: 1);
    expect(await executor.prepare(_input(0)), isNotNull); // pool warmed

    executor.debugKillWorkers();
    // Let the exit notification arrive and free the pool slot.
    await Future<void>.delayed(const Duration(milliseconds: 100));

    // Regression: a dead worker used to stay in the pool as permanently
    // busy (no onExit port), stranding its job and shrinking the pool.
    final result =
        await executor.prepare(_input(1)).timeout(const Duration(seconds: 5));
    expect(result, isNotNull,
        reason: 'a replacement worker must serve the queue');
    executor.dispose();
  });
}
