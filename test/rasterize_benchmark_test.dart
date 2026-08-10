import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_map_vector_tiles/src/core/tile_key.dart';
import 'package:flutter_map_vector_tiles/src/pipeline/prepared_tile.dart';
import 'package:flutter_map_vector_tiles/src/render/display_tile_data.dart';
import 'package:flutter_map_vector_tiles/src/render/symbol_layouter.dart';
import 'package:flutter_map_vector_tiles/src/render/tile_rasterizer.dart';
import 'package:flutter_map_vector_tiles/src/style/theme.dart';
import 'package:flutter_map_vector_tiles/src/style/theme_reader.dart';
import 'package:flutter_test/flutter_test.dart';

/// Manual micro-benchmark for overzoom rasterization cost — run with
/// `flutter test test/rasterize_benchmark_test.dart --run-skipped`.
/// Not part of the gate: wall-clock assertions flake under load.

PreparedFeature _walk(Random rng, int vertices) {
  final part = Float32List(vertices * 2);
  var x = rng.nextDouble() * 4096, y = rng.nextDouble() * 4096;
  var minX = x, minY = y, maxX = x, maxY = y;
  for (var i = 0; i < vertices; i++) {
    part[i * 2] = x;
    part[i * 2 + 1] = y;
    if (x < minX) minX = x;
    if (x > maxX) maxX = x;
    if (y < minY) minY = y;
    if (y > maxY) maxY = y;
    x += (rng.nextDouble() - 0.5) * 400;
    y += (rng.nextDouble() - 0.5) * 400;
  }
  return PreparedFeature(
    id: null,
    type: PreparedGeomType.line,
    parts: [part],
    properties: {'class': 'c${rng.nextInt(12)}'},
    minX: minX,
    minY: minY,
    maxX: maxX,
    maxY: maxY,
  );
}

DisplayTileData _city(TileKey displayKey, TileKey dataKey) {
  final rng = Random(42);
  return DisplayTileData(
    displayKey: displayKey,
    sources: {
      's': PreparedTile(
        key: dataKey,
        layers: {
          'transportation': PreparedSourceLayer(extent: 4096, features: [
            for (var i = 0; i < 1500; i++) _walk(rng, 32),
          ]),
        },
        byteSize: 0,
      ),
    },
  );
}

Theme _cityTheme() => const ThemeReader().read({
      'layers': [
        // Road-class layers sharing one source-layer, as real styles do.
        for (var i = 0; i < 12; i++)
          {
            'id': 'road-$i',
            'type': 'line',
            'source': 's',
            'source-layer': 'transportation',
            'filter': [
              '==',
              'class',
              'c$i',
            ],
            'paint': {'line-color': '#ffffff', 'line-width': 2 + i % 4},
          },
        {
          'id': 'road-dashed',
          'type': 'line',
          'source': 's',
          'source-layer': 'transportation',
          'filter': ['==', 'class', 'c3'],
          'paint': {
            'line-color': '#88aaff',
            'line-width': 2,
            'line-dasharray': [3, 2],
          },
        },
      ],
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => TileRasterizer.debugDisableCulling = false);

  test('rasterize + symbol layout cost, native vs deep overzoom', () {
    final theme = _cityTheme();
    for (final (label, displayKey, dataKey, disableCulling) in [
      (
        'shift 0 (native zoom)',
        const TileKey(14, 8000, 8000),
        const TileKey(14, 8000, 8000),
        false
      ),
      (
        'shift 6 (z20 over z14)',
        const TileKey(20, 512011, 512011),
        const TileKey(14, 8000, 8000),
        false
      ),
      (
        'shift 6, culling disabled (pre-change baseline)',
        const TileKey(20, 512011, 512011),
        const TileKey(14, 8000, 8000),
        true
      ),
    ]) {
      TileRasterizer.debugDisableCulling = disableCulling;
      final data = _city(displayKey, dataKey);
      // Warm-up, then measure.
      TileRasterizer.rasterize(
              theme: theme, data: data, styleZoom: 14, devicePixelRatio: 1)
          ?.dispose();
      final sw = Stopwatch()..start();
      const rounds = 5;
      for (var i = 0; i < rounds; i++) {
        TileRasterizer.rasterize(
                theme: theme, data: data, styleZoom: 14, devicePixelRatio: 1)
            ?.dispose();
        SymbolLayouter.layout(theme: theme, data: data, styleZoom: 14);
      }
      sw.stop();
      // ignore: avoid_print
      print('$label: ${sw.elapsedMicroseconds ~/ rounds} us/tile');
    }
  }, skip: 'manual benchmark — run with --run-skipped');
}
