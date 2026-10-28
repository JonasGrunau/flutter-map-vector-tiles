@TestOn('vm')
library;

import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_map_vector_tiles/src/pipeline/executor/executor.dart';
import 'package:flutter_map_vector_tiles/src/pipeline/executor/isolate_executor.dart';
import 'package:flutter_map_vector_tiles/src/pipeline/prepared_tile.dart';
import 'package:flutter_map_vector_tiles/src/pipeline/tile_filters.dart';
import 'package:flutter_map_vector_tiles/src/pipeline/tile_processor.dart';
import 'package:flutter_map_vector_tiles/src/style/theme.dart';
import 'package:flutter_map_vector_tiles/src/style/theme_reader.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/mvt_builder.dart';

void _echo(SendPort port) => port.send('hello');

PrepareInput _input(int x) => PrepareInput(
    z: 1, x: x, y: 0, bytes: Uint8List(0), layerProperties: const {});

/// Two filters over a `poi` layer of points classed a, b, a, c.
final _theme = const ThemeReader().read({
  'layers': [
    for (final cls in ['a', 'b'])
      {
        'id': cls,
        'type': 'circle',
        'source': 's',
        'source-layer': 'poi',
        'filter': ['==', 'class', cls],
      },
  ],
});

final _poiBytes = (() {
  final layer = MvtTileBuilder().layer('poi');
  for (final cls in ['a', 'b', 'a', 'c']) {
    layer.feature(
      type: 1,
      geometry: [cmd(1, 1), zig(10), zig(10)],
      properties: {'class': cls},
    );
  }
  return layer.done().build();
})();

PrepareInput _filtered(int x) => PrepareInput(
      z: 0,
      x: x,
      y: 0,
      bytes: _poiBytes,
      layerProperties: const {
        'poi': {'class'}
      },
      filterIds: TileFilterPlan(_theme.layers, minimumZoom: 0, maximumZoom: 0)
          .idsAt(0),
    );

/// The worker's matches, by the layer they belong to.
Map<String, List<int>?> _matchesOf(PreparedTile? tile) => {
      for (final ThemeLayer(:id, :filterId) in _theme.layers)
        id: tile!.layers['poi']!.matches[filterId],
    };

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

  test('workers resolve zoom-free filters while preparing', () async {
    final executor = PlatformExecutor(concurrency: 2);
    addTearDown(executor.dispose);
    // More jobs than workers: each worker compiles from the sources it
    // was sent once, with its first job, and reuses them after.
    final tiles = await Future.wait(
        [for (var i = 0; i < 6; i++) executor.prepare(_filtered(i))]);
    for (final tile in tiles) {
      expect(_matchesOf(tile), {
        'a': [0, 2],
        'b': [1],
      });
    }
  });

  test('a replacement worker is sent the filter sources again', () async {
    final executor = PlatformExecutor(concurrency: 1);
    addTearDown(executor.dispose);
    expect(_matchesOf(await executor.prepare(_filtered(0)))['a'], [0, 2]);

    executor.debugKillWorkers();
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final tile = await executor
        .prepare(_filtered(1))
        .timeout(const Duration(seconds: 5));
    expect(
        _matchesOf(tile),
        {
          'a': [0, 2],
          'b': [1],
        },
        reason: 'the new isolate compiled nothing yet');
  });

  test('a malformed tile with filters to resolve fails as before', () async {
    final executor = PlatformExecutor(concurrency: 1);
    addTearDown(executor.dispose);
    final broken = PrepareInput(
      z: 0,
      x: 0,
      y: 0,
      bytes: Uint8List.fromList([0x1a, 0xff, 0xff, 0xff, 0x0f, 1, 2]),
      layerProperties: const {
        'poi': {'class'}
      },
      filterIds: _filtered(0).filterIds,
    );
    expect(await executor.prepare(broken), isNull);
    // The worker survived it, and still holds the compiled filters.
    expect(_matchesOf(await executor.prepare(_filtered(1)))['b'], [1]);
  });
}
