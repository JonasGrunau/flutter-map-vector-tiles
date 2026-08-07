import 'dart:typed_data';

import 'package:flutter_map_vector_tiles/src/core/cancellation.dart';
import 'package:flutter_map_vector_tiles/src/core/tile_key.dart';
import 'package:flutter_map_vector_tiles/src/grid/tile_store.dart';
import 'package:flutter_map_vector_tiles/src/pipeline/executor/executor.dart';
import 'package:flutter_map_vector_tiles/src/provider/memory_vector_tile_provider.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/mvt_builder.dart';

Uint8List _tileBytes() => MvtTileBuilder()
    .layer('water')
    .feature(type: 3, geometry: [
      cmd(1, 1), zig(0), zig(0), //
      cmd(2, 3), zig(100), zig(0), zig(0), zig(100), zig(-100), zig(0),
      cmd(7, 1),
    ], properties: {
      'class': 'lake',
      'name': 'Ammersee'
    })
    .done()
    .layer('unused_layer')
    .feature(type: 1, geometry: [cmd(1, 1), zig(5), zig(5)])
    .done()
    .build();

void main() {
  late TilePrepareExecutor executor;

  setUp(() => executor = TilePrepareExecutor(concurrency: 1));
  tearDown(() => executor.dispose());

  TileStore store({int maxZoom = 14}) => TileStore(
        provider: MemoryVectorTileProvider(
          tiles: {const TileKey(2, 1, 1): _tileBytes()},
          maximumZoom: maxZoom,
        ),
        executor: executor,
        layerProperties: {
          'water': {'class'},
        },
      );

  test('loads, decodes and trims a tile', () async {
    final s = store();
    final tile = await s.obtain(const TileKey(2, 1, 1));
    expect(tile, isNotNull);
    expect(tile!.layers.keys, ['water']); // unused layer dropped
    final feature = tile.layers['water']!.features.single;
    expect(feature.properties, {'class': 'lake'}); // name trimmed
    s.dispose();
  });

  test('missing tiles resolve as empty, not error', () async {
    final s = store();
    final tile = await s.obtain(const TileKey(2, 0, 0));
    expect(tile, isNotNull);
    expect(tile!.layers, isEmpty);
    s.dispose();
  });

  test('memory cache returns identical instance', () async {
    final s = store();
    final a = await s.obtain(const TileKey(2, 1, 1));
    final b = await s.obtain(const TileKey(2, 1, 1));
    expect(identical(a, b), true);
    expect(s.peek(const TileKey(2, 1, 1)), isNotNull);
    s.dispose();
  });

  test('cancellation resolves null silently', () async {
    final s = store();
    final token = CancellationToken()..cancel();
    final tile = await s.obtain(const TileKey(2, 1, 1), cancellation: token);
    expect(tile, null);
    s.dispose();
  });

  test('dataKeyFor clamps to provider maximum zoom', () {
    final s = store(maxZoom: 2);
    expect(s.dataKeyFor(const TileKey(5, 25, 25), 0), const TileKey(2, 3, 3));
    expect(s.dataKeyFor(const TileKey(2, 1, 1), 0), const TileKey(2, 1, 1));
    s.dispose();
  });

  test('dataKeyFor applies zoom offset and wraps x', () {
    final s = store();
    expect(s.dataKeyFor(const TileKey(5, 8, 8), -1), const TileKey(4, 4, 4));
    expect(s.dataKeyFor(const TileKey(2, -1, 1), 0), const TileKey(2, 3, 1));
    s.dispose();
  });

  test('peekWithAncestors finds a loaded parent', () async {
    final s = store();
    await s.obtain(const TileKey(2, 1, 1));
    final found = s.peekWithAncestors(const TileKey(4, 5, 5));
    expect(found, isNotNull);
    expect(found!.key, const TileKey(2, 1, 1));
    s.dispose();
  });
}
