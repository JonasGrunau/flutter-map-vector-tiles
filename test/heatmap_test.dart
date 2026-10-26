import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:flutter_map_vector_tiles/flutter_map_vector_tiles.dart';
import 'package:flutter_map_vector_tiles/src/pipeline/prepared_tile.dart';
import 'package:flutter_map_vector_tiles/src/render/display_tile_data.dart';
import 'package:flutter_map_vector_tiles/src/render/heatmap_density.dart';
import 'package:flutter_map_vector_tiles/src/render/heatmap_layouter.dart';
import 'package:flutter_test/flutter_test.dart';

/// The spec's density of one point at distance [d] from it.
double kernel(double peak, double d, double radius) =>
    peak * math.exp(-4.5 * (d / radius) * (d / radius));

Theme heatmapTheme([Map<String, Object?> paint = const {}]) =>
    const ThemeReader().read({
      'layers': [
        {
          'id': 'heat',
          'type': 'heatmap',
          'source': 's',
          'source-layer': 'pts',
          'paint': paint,
        },
      ],
    });

PreparedFeature point(double x, double y, [Map<String, Object?>? props]) =>
    PreparedFeature(
      id: null,
      type: PreparedGeomType.point,
      parts: [
        Float32List.fromList([x, y])
      ],
      properties: props ?? const {},
      minX: x,
      minY: y,
      maxX: x,
      maxY: y,
    );

PreparedTile tileOf(TileKey key, List<PreparedFeature> features) =>
    PreparedTile(
      key: key,
      layers: {
        'pts': PreparedSourceLayer(extent: 4096, features: features),
      },
      byteSize: 0,
    );

void main() {
  group('style', () {
    test('a heatmap layer compiles with the spec defaults', () {
      final layer = heatmapTheme().layers.single as HeatmapThemeLayer;
      const ctx = EvalContext(zoom: 10);
      expect(layer.radius.eval(ctx), 30);
      expect(layer.weight.eval(ctx), 1);
      expect(layer.intensity.eval(ctx), 1);
      expect(layer.opacity.eval(ctx), 1);
      Color at(double density) =>
          layer.color.eval(EvalContext(zoom: 10, heatmapDensity: density));
      expect(at(0).a, 0, reason: 'transparent where there is no density');
      expect(at(1), const Color(0xffff0000));
      expect(at(0.5), const Color(0xff00ff00)); // lime
      expect(at(0.3), const Color(0xff00ffff)); // cyan
      expect(layer.weightReadsZoom, isFalse);
      expect(layer.radiusReadsZoom, isFalse);
    });

    test('heatmap-color is evaluated per density, never memoized by zoom', () {
      final layer = heatmapTheme({
        'heatmap-color': [
          'interpolate',
          ['linear'],
          ['heatmap-density'],
          0,
          'black',
          1,
          'white',
        ],
      }).layers.single as HeatmapThemeLayer;
      final low = layer.color.eval(const EvalContext(zoom: 5));
      final high =
          layer.color.eval(const EvalContext(zoom: 5, heatmapDensity: 1));
      expect(low, const Color(0xff000000));
      expect(high, const Color(0xffffffff));
    });

    test('weight and radius report whether they read the zoom', () {
      final layer = heatmapTheme({
        'heatmap-weight': ['get', 'mag'],
        'heatmap-radius': [
          'interpolate',
          ['linear'],
          ['zoom'],
          0,
          2,
          9,
          20,
        ],
      }).layers.single as HeatmapThemeLayer;
      expect(layer.weightReadsZoom, isFalse);
      expect(layer.radiusReadsZoom, isTrue);
      expect(layer.referencedProperties, {'mag'});
    });
  });

  group('density grid', () {
    test(
        'one point peaks at weight · intensity / √(2π) and falls off as '
        'the spec Gaussian', () {
      final grid = HeatmapGrid(41, 41, 1);
      // On the centre of cell (20, 20).
      grid.accumulate(
          Float32List.fromList([20.5]),
          Float32List.fromList([20.5]),
          Float32List.fromList([HeatmapGrid.peakFactor]),
          1,
          10);
      double at(int x, int y) => grid.values[y * 41 + x];
      expect(at(20, 20), closeTo(HeatmapGrid.peakFactor, 1e-6));
      for (final d in [1, 3, 5, 10]) {
        expect(at(20 + d, 20),
            closeTo(kernel(HeatmapGrid.peakFactor, d * 1.0, 10), 1e-6));
        expect(at(20, 20 - d),
            closeTo(kernel(HeatmapGrid.peakFactor, d * 1.0, 10), 1e-6));
      }
      // Beyond the reach, nothing.
      expect(at(20 + 16, 20), 0);
    });

    test('the separable blur matches the direct sum', () {
      final random = math.Random(7);
      const n = 3000; // enough points that accumulate picks the blur
      final xs = Float32List(n);
      final ys = Float32List(n);
      final peaks = Float32List(n);
      for (var i = 0; i < n; i++) {
        // Some outside the grid: their kernels still reach in.
        xs[i] = random.nextDouble() * 140 - 10;
        ys[i] = random.nextDouble() * 100 - 10;
        peaks[i] = random.nextDouble() * 0.05;
      }
      const cell = 2.0;
      const radius = 16.0;
      final blurred = HeatmapGrid(60, 40, cell)
        ..accumulate(xs, ys, peaks, n, radius);
      // The reference: every point's kernel summed at every cell centre.
      var worst = 0.0;
      var maxValue = 0.0;
      for (var y = 0; y < 40; y++) {
        for (var x = 0; x < 60; x++) {
          final cx = (x + 0.5) * cell;
          final cy = (y + 0.5) * cell;
          var sum = 0.0;
          for (var i = 0; i < n; i++) {
            final d = math.sqrt(
                (xs[i] - cx) * (xs[i] - cx) + (ys[i] - cy) * (ys[i] - cy));
            if (d <= HeatmapGrid.reachInRadii * radius) {
              sum += kernel(peaks[i], d, radius);
            }
          }
          maxValue = math.max(maxValue, sum);
          worst = math.max(worst, (blurred.values[y * 60 + x] - sum).abs());
        }
      }
      expect(maxValue, greaterThan(0.5));
      // The bilinear splat moves each point by under a cell; at σ =
      // 2.7 cells that shifts the sum by about a percent.
      expect(worst / maxValue, lessThan(0.02));
    });

    test('colorize interpolates the density, then looks the ramp up', () {
      final grid = HeatmapGrid(2, 1, 4);
      grid.values
        ..[0] = 0
        ..[1] = 1;
      // Ramp: index i → red channel i, opaque.
      final ramp =
          Uint32List.fromList([for (var i = 0; i < 256; i++) i | (0xff << 24)]);
      final pixels = grid.colorize(ramp, 4).buffer.asUint32List();
      expect(pixels.length, 8 * 4);
      final reds = [for (final p in pixels.take(8)) p & 0xff];
      // Held at the edges, rising between the cell centres (pixels 1.5
      // and 5.5).
      expect(reds.first, 0);
      expect(reds.last, 255);
      for (var i = 1; i < reds.length; i++) {
        expect(reds[i], greaterThanOrEqualTo(reds[i - 1]));
      }
      expect(reds[3], closeTo(255 * 0.375, 1)); // pixel 3.5: 2/4 of the way
    });

    test('rows with no density stay transparent under a transparent ramp', () {
      final grid = HeatmapGrid(3, 3, 1);
      final ramp = Uint32List(256)..[255] = 0xffffffff;
      final pixels = grid.colorize(ramp, 2);
      expect(pixels.every((b) => b == 0), isTrue);
    });

    test('packRgba premultiplies', () {
      final packed = HeatmapGrid.packRgba(1, 0.5, 0, 0.5);
      expect(packed & 0xff, 128);
      expect((packed >> 8) & 0xff, 64);
      expect((packed >> 16) & 0xff, 0);
      expect((packed >> 24) & 0xff, 128);
    });
  });

  group('layout', () {
    test('a point belongs to one display tile, seams and buffers included', () {
      final theme = heatmapTheme();
      final data = tileOf(const TileKey(10, 4, 4), [
        point(0, 0), // the corner: top-left display tile
        point(2048, 2048), // the centre: bottom-right display tile
        point(2047, 100), // left of the seam
        point(4096, 10), // the neighbour's — in the buffer
        point(-5, 10), // the other neighbour's
      ]);
      var total = 0;
      final seen = <String>[];
      for (var dy = 0; dy < 2; dy++) {
        for (var dx = 0; dx < 2; dx++) {
          final key = TileKey(11, 8 + dx, 8 + dy);
          final points = HeatmapLayouter.layout(
            theme: theme,
            data: DisplayTileData(displayKey: key, sources: {'s': data}),
            styleZoom: 11,
          ).single;
          total += points.length;
          for (var i = 0; i < points.length; i++) {
            seen.add('$dx$dy:${points.xy[i * 2]},${points.xy[i * 2 + 1]}');
          }
        }
      }
      expect(total, 3);
      expect(
          seen, containsAll(['00:0.0,0.0', '11:0.0,0.0', '00:255.875,12.5']));
    });

    test('lines and polygons are not heatmap points', () {
      final theme = heatmapTheme();
      final line = PreparedFeature(
        id: null,
        type: PreparedGeomType.line,
        parts: [
          Float32List.fromList([10, 10, 20, 20])
        ],
        properties: const {},
      );
      final points = HeatmapLayouter.layout(
        theme: theme,
        data: DisplayTileData(
          displayKey: const TileKey(3, 1, 1),
          sources: {
            's': tileOf(const TileKey(3, 1, 1), [line, point(50, 50)]),
          },
        ),
        styleZoom: 3,
      ).single;
      expect(points.length, 1);
    });

    test('a feature-only weight is evaluated at layout, a zoom one per pass',
        () {
      final byFeature = heatmapTheme({
        'heatmap-weight': ['get', 'w'],
      });
      final byZoom = heatmapTheme({
        'heatmap-weight': [
          '*',
          ['get', 'w'],
          ['zoom'],
        ],
      });
      final uniform = heatmapTheme({
        'heatmap-weight': [
          'interpolate',
          ['linear'],
          ['zoom'],
          0,
          0,
          10,
          1,
        ],
      });
      HeatmapPoints layout(Theme theme) => HeatmapLayouter.layout(
            theme: theme,
            data: DisplayTileData(
              displayKey: const TileKey(3, 1, 1),
              sources: {
                's': tileOf(const TileKey(3, 1, 1), [
                  point(1, 1, {'w': 2}),
                  point(2, 2, {'w': 3}),
                ]),
              },
            ),
            styleZoom: 3,
          ).single;
      expect(layout(byFeature).weightsAt(7), [2, 3]);
      expect(layout(byZoom).weightsAt(2), [4, 6]);
      expect(layout(byZoom).weightsAt(4), [8, 12]);
      expect(layout(uniform).weightsAt(4), isNull);
      expect(layout(uniform).uniformWeight, isTrue);
    });

    test('a layer outside the tile band is not laid out', () {
      final theme = const ThemeReader().read({
        'layers': [
          {
            'id': 'heat',
            'type': 'heatmap',
            'source': 's',
            'source-layer': 'pts',
            'maxzoom': 9,
          },
        ],
      });
      List<HeatmapPoints> at(double z) => HeatmapLayouter.layout(
            theme: theme,
            data: DisplayTileData(
              displayKey: const TileKey(3, 1, 1),
              sources: {
                's': tileOf(const TileKey(3, 1, 1), [point(1, 1)])
              },
            ),
            styleZoom: z,
          );
      expect(at(8), hasLength(1));
      expect(at(9), isEmpty);
    });
  });
}
