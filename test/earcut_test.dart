import 'dart:math' as math;

import 'package:flutter_map_vector_tiles/src/render/earcut.dart';
import 'package:flutter_test/flutter_test.dart';

/// The triangles' total area, which a correct triangulation makes the
/// polygon's: the exterior's area less its holes'.
double _area(List<double> data, List<int> triangles) {
  var sum = 0.0;
  for (var i = 0; i < triangles.length; i += 3) {
    final a = triangles[i] * 2, b = triangles[i + 1] * 2;
    final c = triangles[i + 2] * 2;
    sum += ((data[b] - data[a]) * (data[c + 1] - data[a + 1]) -
                (data[c] - data[a]) * (data[b + 1] - data[a + 1]))
            .abs() /
        2;
  }
  return sum;
}

List<int> _cut(List<double> data, [List<int> holes = const []]) {
  final out = <int>[];
  final count = earcut(data, holes, out);
  expect(count, out.length);
  return out;
}

void main() {
  test('a square is two triangles covering it', () {
    final data = <double>[0, 0, 10, 0, 10, 10, 0, 10];
    final triangles = _cut(data);
    expect(triangles.length, 6);
    expect(_area(data, triangles), 100);
  });

  test('either winding cuts the same area', () {
    final cw = <double>[0, 0, 10, 0, 10, 10, 0, 10];
    final ccw = <double>[0, 0, 0, 10, 10, 10, 10, 0];
    expect(_area(cw, _cut(cw)), _area(ccw, _cut(ccw)));
  });

  test('a concave L keeps its notch empty', () {
    final data = <double>[0, 0, 20, 0, 20, 10, 10, 10, 10, 20, 0, 20];
    final triangles = _cut(data);
    expect(triangles.length, 12);
    expect(_area(data, triangles), 300);
  });

  test('a hole is left uncovered', () {
    final data = <double>[
      0, 0, 30, 0, 30, 30, 0, 30, //
      10, 10, 10, 20, 20, 20, 20, 10,
    ];
    final triangles = _cut(data, [4]);
    expect(_area(data, triangles), closeTo(900 - 100, 1e-9));
    // Every vertex of the hole is used: it was bridged into the ring.
    for (var i = 4; i < 8; i++) {
      expect(triangles, contains(i));
    }
  });

  test('two holes, the z-order hash past 80 vertices', () {
    // A 100-gon with two square holes: the ear tests go through the
    // z-order hash.
    final data = <double>[];
    for (var i = 0; i < 100; i++) {
      final a = -2 * math.pi * i / 100;
      data
        ..add(50 + 50 * math.cos(a))
        ..add(50 + 50 * math.sin(a));
    }
    final holes = <int>[100];
    data.addAll([20, 40, 20, 60, 40, 60, 40, 40]);
    holes.add(104);
    data.addAll([60, 40, 60, 60, 80, 60, 80, 40]);
    final triangles = _cut(data, holes);
    var ring = 0.0;
    for (var i = 0; i < 100; i++) {
      final j = (i + 1) % 100;
      ring += data[2 * i] * data[2 * j + 1] - data[2 * j] * data[2 * i + 1];
    }
    expect(_area(data, triangles), closeTo(ring.abs() / 2 - 800, 1e-6));
  });

  test('degenerate rings cut nothing and do not throw', () {
    expect(_cut(<double>[0, 0, 10, 0, 20, 0]), isEmpty); // collinear
    expect(_cut(<double>[0, 0, 10, 0]), isEmpty); // two points
    expect(_cut(<double>[5, 5, 5, 5, 5, 5, 5, 5]), isEmpty); // one point
  });

  test('a self-touching ring still covers its area', () {
    // Two squares meeting at one vertex, as one ring.
    final data = <double>[
      0,
      0,
      10,
      0,
      10,
      10,
      20,
      10,
      20,
      20,
      10,
      20,
      10,
      10,
      0,
      10
    ];
    expect(_area(data, _cut(data)), closeTo(200, 1e-9));
  });

  test('appends to what the list already holds', () {
    final out = <int>[7, 7, 7];
    final count = earcut(<double>[0, 0, 10, 0, 10, 10], const [], out);
    expect(count, 3);
    expect(out.length, 6);
    expect(out.take(3), [7, 7, 7]);
  });
}
