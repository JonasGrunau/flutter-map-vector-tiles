import 'dart:typed_data';

import 'package:flutter_map_vector_tiles/src/render/geometry_clipper.dart';
import 'package:flutter_test/flutter_test.dart';

const _rect = ClipRect(0, 0, 100, 100);

Float32List _run(List<double> coords) => Float32List.fromList(coords);

/// Shoelace area in y-down coordinates, same convention as the decoder:
/// positive for clockwise-on-screen rings.
double _shoelace(Float32List ring) {
  var sum = 0.0;
  final n = ring.length;
  for (var i = 0; i + 3 < n; i += 2) {
    sum += (ring[i] - ring[i + 2]) * (ring[i + 1] + ring[i + 3]);
  }
  sum += (ring[n - 2] - ring[0]) * (ring[n - 1] + ring[1]);
  return sum / 2;
}

void main() {
  group('clipPolyline', () {
    test('a polyline fully inside passes through unchanged', () {
      final clipped = clipPolyline(_run([10, 10, 90, 10, 90, 90]), _rect);
      expect(clipped.runs, hasLength(1));
      expect(clipped.runs.single, _run([10, 10, 90, 10, 90, 90]));
      expect(clipped.startDistances.single, 0);
    });

    test('a polyline fully outside yields nothing', () {
      expect(clipPolyline(_run([-50, 10, -10, 10]), _rect).runs, isEmpty);
      expect(clipPolyline(_run([10, 110, 90, 110]), _rect).runs, isEmpty);
      // Diagonal corner miss: the bbox overlaps the window, the
      // geometry does not.
      expect(clipPolyline(_run([80, 130, 130, 80]), _rect).runs, isEmpty);
    });

    test(
        'a crossing line is trimmed to the window with its entry '
        'distance', () {
      final clipped = clipPolyline(_run([-10, 50, 110, 50]), _rect);
      expect(clipped.runs.single, _run([0, 50, 100, 50]));
      // The original run travelled 10 units before entering.
      expect(clipped.startDistances.single, closeTo(10, 1e-9));
    });

    test('zigzag exit and re-entry produces one sub-run per visit', () {
      final clipped = clipPolyline(
        _run([-10, 20, 30, 20, 30, -30, 70, -30, 70, 20]),
        _rect,
      );
      expect(clipped.runs, hasLength(2));
      expect(clipped.runs[0], _run([0, 20, 30, 20, 30, 0]));
      expect(clipped.startDistances[0], closeTo(10, 1e-9));
      expect(clipped.runs[1], _run([70, 0, 70, 20]));
      // 40 (first segment) + 50 (down) + 40 (across) + 30 into the
      // climbing segment before crossing y=0.
      expect(clipped.startDistances[1], closeTo(160, 1e-9));
    });

    test('a segment collinear with a window edge is kept', () {
      final clipped = clipPolyline(_run([10, 0, 90, 0]), _rect);
      expect(clipped.runs.single, _run([10, 0, 90, 0]));
    });

    test('endpoints exactly on the boundary are kept', () {
      final clipped = clipPolyline(_run([0, 50, 100, 50]), _rect);
      expect(clipped.runs.single, _run([0, 50, 100, 50]));
      expect(clipped.startDistances.single, 0);
    });

    test('runs with fewer than 2 points yield nothing', () {
      expect(clipPolyline(_run([5, 5]), _rect).runs, isEmpty);
      expect(clipPolyline(_run([]), _rect).runs, isEmpty);
    });

    test('zero-length segments are skipped without splitting the run', () {
      final clipped = clipPolyline(_run([10, 50, 10, 50, 90, 50]), _rect);
      expect(clipped.runs.single, _run([10, 50, 90, 50]));
      expect(clipped.startDistances.single, 0);
    });

    test('close processes the implicit closing segment', () {
      final clipped =
          clipPolyline(_run([10, 10, 90, 10, 90, 90]), _rect, close: true);
      // Fully inside: one run, closed by materializing last->first.
      expect(clipped.runs.single, _run([10, 10, 90, 10, 90, 90, 10, 10]));
      expect(clipped.closed.single, isTrue,
          reason: 'an intact ring must be stroked as a closed contour, or '
              'its start vertex gets two caps instead of a join');
    });

    test('close rejoins a contour that runs through the ring start', () {
      // Triangle with two vertices outside; only the first edge and the
      // closing edge cross the window. They meet at vertex 0, so they
      // are halves of one contour — emitted separately, the stroke
      // would butt two caps where the ring has a corner.
      final clipped =
          clipPolyline(_run([50, 50, 150, 50, 50, 150]), _rect, close: true);
      // Closing segment (50,150)->(50,50) re-enters at y=100, carries on
      // through vertex 0 and out along the first edge.
      expect(clipped.runs.single, _run([50, 100, 50, 50, 100, 50]));
      // Measured from the ring start, this contour begins 50 before it,
      // so dashes and patterns stay in phase across the join.
      expect(clipped.startDistances.single, closeTo(-50, 1e-6));
      expect(clipped.closed.single, isFalse, reason: 'an open contour');
    });

    test('close does not join across a ring start that is outside', () {
      // Diamond with all four vertices outside: each edge cuts a corner
      // off the window. Vertex 0 is outside too, so no sub-run reaches
      // it and nothing may be joined across it.
      final clipped = clipPolyline(
          _run([-20, 50, 50, -20, 120, 50, 50, 120]), _rect,
          close: true);
      expect(clipped.runs, hasLength(4));
      expect(clipped.closed, everyElement(isFalse));
      expect(clipped.startDistances.first, greaterThan(0),
          reason: 'the first contour starts partway along the first edge');
    });
  });

  group('clipRing', () {
    test('a ring fully inside passes through unchanged', () {
      final clipped = clipRing(_run([10, 10, 90, 10, 50, 90]), _rect);
      expect(clipped, _run([10, 10, 90, 10, 50, 90]));
    });

    test(
        'a ring enclosing the window degenerates to the window, '
        'keeping orientation', () {
      final exterior = _run([-50, -50, 150, -50, 150, 150, -50, 150]);
      final clipped = clipRing(exterior, _rect)!;
      expect(_shoelace(clipped).abs(), closeTo(100 * 100, 1e-3));
      expect(_shoelace(clipped).sign, _shoelace(exterior).sign,
          reason: 'winding must be preserved for nonZero fills');
    });

    test('an enclosing hole keeps its opposite winding', () {
      final hole = _run([-50, 150, 150, 150, 150, -50, -50, -50]);
      final clipped = clipRing(hole, _rect)!;
      expect(_shoelace(clipped).abs(), closeTo(100 * 100, 1e-3));
      expect(_shoelace(clipped).sign, _shoelace(hole).sign);
    });

    test('a partially overlapping square is clipped to the overlap', () {
      final ring = _run([50, 50, 150, 50, 150, 150, 50, 150]);
      final clipped = clipRing(ring, _rect)!;
      expect(_shoelace(clipped).abs(), closeTo(50 * 50, 1e-3));
      expect(_shoelace(clipped).sign, _shoelace(ring).sign);
    });

    test('bbox-overlapping but disjoint geometry clips to nothing', () {
      // The triangle's bbox overlaps the window corner; its edges pass
      // outside it. Either null or a zero-area border sliver is fine —
      // the border lies outside the visible canvas clip.
      final clipped = clipRing(_run([80, 130, 130, 80, 140, 140]), _rect);
      if (clipped != null) {
        expect(_shoelace(clipped).abs(), lessThan(1e-3));
      }
    });

    test('degenerate rings return null', () {
      expect(clipRing(_run([10, 10, 90, 10]), _rect), isNull);
      expect(clipRing(_run([-50, 10, -40, 10, -45, 20]), _rect), isNull);
    });
  });
}
