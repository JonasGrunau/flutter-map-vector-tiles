import 'dart:math' as math;
import 'dart:typed_data';

/// Clipping of tile-extent geometry to a display tile's sub-window.
///
/// At overzoom a display tile shows a tiny window of its data tile, but
/// paths were historically built over the data tile's full extent —
/// making dash extraction, pattern stamping and stroke tessellation grow
/// with the overzoom factor. These helpers bound that work by the window
/// size. Everything operates in tile-extent coordinates, independent of
/// the canvas, so it is unit-testable in plain Dart.

/// Axis-aligned clip window in tile-extent units.
class ClipRect {
  final double minX, minY, maxX, maxY;

  const ClipRect(this.minX, this.minY, this.maxX, this.maxY);

  /// Whether this window fully contains the given bounds — the caller's
  /// fast path: fully-contained geometry needs no clipping.
  bool containsBounds(double bMinX, double bMinY, double bMaxX, double bMaxY) =>
      bMinX >= minX && bMaxX <= maxX && bMinY >= minY && bMaxY <= maxY;
}

/// A clipped polyline: the sub-runs intersecting the window plus, per
/// sub-run, the polyline distance (extent units) from the *original* run
/// start to the sub-run's first vertex. Dash and stamp phases are
/// derived from these distances so patterns stay anchored to the
/// un-clipped geometry — phase agrees across clip boundaries and
/// display-tile seams.
class ClippedRuns {
  final List<Float32List> runs;
  final Float64List startDistances;

  const ClippedRuns(this.runs, this.startDistances);
}

/// Reusable per-isolate scratch for the sub-run currently being emitted.
/// Safe as a global: clipping runs synchronously on the UI thread (same
/// pattern as the MVT decoder's `_scratch`).
Float32List _runScratch = Float32List(512);

void _growRunScratch(int needed) {
  var n = _runScratch.length * 2;
  while (n < needed) {
    n *= 2;
  }
  _runScratch = Float32List(n)..setRange(0, _runScratch.length, _runScratch);
}

final _segmentClip = _SegmentClip();

/// Segment-wise Liang–Barsky clip of an interleaved x,y polyline.
///
/// With [close], the implicit closing segment (last vertex back to the
/// first) is processed too — used when a polygon ring is stroked as a
/// line. Runs with fewer than 2 points yield no output; zero-length
/// segments are skipped (they contribute nothing but a cap dot).
ClippedRuns clipPolyline(Float32List run, ClipRect rect, {bool close = false}) {
  final runs = <Float32List>[];
  final starts = <double>[];
  final n = run.length ~/ 2;
  if (n >= 2) {
    var open = false;
    var len = 0;
    var runStart = 0.0;
    var dist = 0.0;

    void flush() {
      if (open && len >= 4) {
        runs.add(Float32List(len)..setRange(0, len, _runScratch));
        starts.add(runStart);
      }
      open = false;
      len = 0;
    }

    void append(double x, double y) {
      if (len + 2 > _runScratch.length) _growRunScratch(len + 2);
      _runScratch[len++] = x;
      _runScratch[len++] = y;
    }

    final segCount = close ? n : n - 1;
    for (var s = 0; s < segCount; s++) {
      final i0 = s * 2;
      final x0 = run[i0];
      final y0 = run[i0 + 1];
      final wraps = s == n - 1;
      final x1 = wraps ? run[0] : run[i0 + 2];
      final y1 = wraps ? run[1] : run[i0 + 3];
      final dx = x1 - x0;
      final dy = y1 - y0;
      final segLen = math.sqrt(dx * dx + dy * dy);
      if (segLen == 0) continue;
      if (!_segmentClip.clip(x0, y0, dx, dy, rect) ||
          _segmentClip.t1 <= _segmentClip.t0) {
        flush();
        dist += segLen;
        continue;
      }
      final t0 = _segmentClip.t0;
      final t1 = _segmentClip.t1;
      if (!open || t0 > 0) {
        // Either no run is open, or the polyline left the window and
        // re-entered mid-segment: start a fresh sub-run at the entry.
        flush();
        open = true;
        runStart = dist + t0 * segLen;
        append(x0 + dx * t0, y0 + dy * t0);
      }
      append(x0 + dx * t1, y0 + dy * t1);
      if (t1 < 1) flush(); // exited the window: pen up
      dist += segLen;
    }
    flush();
  }
  return ClippedRuns(runs, Float64List.fromList(starts));
}

/// Sutherland–Hodgman clip of one implicitly-closed ring against the
/// window's four half-planes. Preserves winding, so nonZero fills across
/// exterior + hole rings stay correct; added edges lie on the window
/// border, which the caller keeps outside the visible canvas clip.
/// Returns null when fewer than 3 vertices remain.
Float32List? clipRing(Float32List ring, ClipRect rect) {
  final n = ring.length;
  if (n < 6) return null;
  var inBuf = Float32List(n + 16)..setRange(0, n, ring);
  var inLen = n;
  var outBuf = Float32List(n + 16);

  for (var edge = 0; edge < 4; edge++) {
    // Each input vertex emits at most 2 output vertices.
    final cap = inLen * 2 + 8;
    if (outBuf.length < cap) outBuf = Float32List(cap);
    var outLen = 0;
    var px = inBuf[inLen - 2];
    var py = inBuf[inLen - 1];
    var pIn = _insideEdge(edge, px, py, rect);
    for (var i = 0; i + 1 < inLen; i += 2) {
      final cx = inBuf[i];
      final cy = inBuf[i + 1];
      final cIn = _insideEdge(edge, cx, cy, rect);
      if (cIn != pIn) {
        // Crossing guarantees the denominator is non-zero.
        double ix, iy;
        if (edge == 0) {
          ix = rect.minX;
          iy = py + (cy - py) * ((rect.minX - px) / (cx - px));
        } else if (edge == 1) {
          ix = rect.maxX;
          iy = py + (cy - py) * ((rect.maxX - px) / (cx - px));
        } else if (edge == 2) {
          iy = rect.minY;
          ix = px + (cx - px) * ((rect.minY - py) / (cy - py));
        } else {
          iy = rect.maxY;
          ix = px + (cx - px) * ((rect.maxY - py) / (cy - py));
        }
        outBuf[outLen++] = ix;
        outBuf[outLen++] = iy;
      }
      if (cIn) {
        outBuf[outLen++] = cx;
        outBuf[outLen++] = cy;
      }
      px = cx;
      py = cy;
      pIn = cIn;
    }
    if (outLen < 6) return null;
    final tmp = inBuf;
    inBuf = outBuf;
    inLen = outLen;
    outBuf = tmp;
  }
  return Float32List(inLen)..setRange(0, inLen, inBuf);
}

bool _insideEdge(int edge, double x, double y, ClipRect r) => switch (edge) {
      0 => x >= r.minX,
      1 => x <= r.maxX,
      2 => y >= r.minY,
      _ => y <= r.maxY,
    };

/// Mutable Liang–Barsky state, reused across segments to avoid a
/// per-segment allocation.
class _SegmentClip {
  double t0 = 0;
  double t1 = 1;

  bool clip(double x0, double y0, double dx, double dy, ClipRect r) {
    t0 = 0;
    t1 = 1;
    return _edge(-dx, x0 - r.minX) &&
        _edge(dx, r.maxX - x0) &&
        _edge(-dy, y0 - r.minY) &&
        _edge(dy, r.maxY - y0);
  }

  bool _edge(double p, double q) {
    if (p == 0) return q >= 0;
    final t = q / p;
    if (p < 0) {
      if (t > t1) return false;
      if (t > t0) t0 = t;
    } else {
      if (t < t0) return false;
      if (t < t1) t1 = t;
    }
    return true;
  }
}
