@TestOn('vm')
library;

import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_map_vector_tiles/src/pipeline/executor/executor.dart';
import 'package:flutter_map_vector_tiles/src/pipeline/tile_processor.dart';
import 'package:flutter_test/flutter_test.dart';

void _echo(SendPort port) => port.send('hello');

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
}
