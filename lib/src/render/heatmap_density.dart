import 'dart:math' as math;
import 'dart:typed_data';

/// The kernel density estimate behind a heatmap layer, and its colouring.
///
/// Pure arithmetic over typed lists — no `dart:ui` drawing — so it is
/// testable to the digit and could run on a worker unchanged.
///
/// One point contributes `weight · intensity · g · exp(−½ · (3d / r)²)`
/// at distance `d` from it, `r` being `heatmap-radius` and
/// `g = 1/√(2π)`: a Gaussian with σ = r/3, scaled so that a single
/// point of weight 1 peaks at 0.399. That is the spec's density, the
/// one MapLibre draws; `heatmap-color` is then read at the sum, clamped
/// to [0, 1].
///
/// A [HeatmapGrid] samples the density at cell centres. Two ways to fill
/// it give the same sums and cost different amounts, so [accumulate]
/// picks the cheaper per batch:
///
/// * **direct** — every point adds its kernel to the cells it reaches:
///   `N · (2h+1)²` for N points reaching h cells, exact at any spacing;
/// * **separable** — the points are splatted bilinearly onto the grid,
///   then blurred with the kernel along x and then y (the Gaussian
///   factors into two 1-D passes): `cells · 2(2h+1)`, independent of N.
///   The bilinear splat widens σ by under 2 % at the cell sizes
///   [HeatmapGrid.cellFor] picks.
class HeatmapGrid {
  /// Cells across and down.
  final int width;
  final int height;

  /// Cell edge in the pass's pixels.
  final double cell;

  /// Density at each cell centre, row-major.
  final Float32List values;

  HeatmapGrid(this.width, this.height, this.cell)
      : values = Float32List(width * height);

  /// `1/√(2π)`: one weight-1 point's density at its own position.
  static const double peakFactor = 0.3989422804014327;

  /// The kernel reach, in radii. The density has fallen to 4·10⁻⁵ of a
  /// point's peak there — below what an 8-bit ramp can show even for a
  /// weight of 10.
  static const double reachInRadii = 1.5;

  /// The cell edge, in logical pixels, for a pass over kernels of
  /// [radius] logical pixels, and how many output pixels across one cell
  /// becomes in [colorize].
  ///
  /// The density is sampled at σ/2 (σ = radius/3), and never finer than
  /// MapLibre's density texture, a quarter of the device resolution. It
  /// is far smoother than the ramp drawn over it, so the output comes
  /// out up to twice as fine, at no less than that quarter resolution:
  /// the GPU interpolates the colours between output pixels, and the
  /// finer output keeps that from smearing a ramp stop.
  static ({double cell, int upsampling}) cellFor(
      double radius, double devicePixelRatio) {
    final quarter = 4 / devicePixelRatio;
    final cell = math.max(quarter, radius / 6);
    return (cell: cell, upsampling: (cell / quarter).round().clamp(1, 2));
  }

  /// Adds [count] points to the grid. Point i sits at
  /// (`xs[i]`, `ys[i]`) in grid pixels — (0, 0) is the grid's top-left
  /// corner — and peaks at `peaks[i]` (weight · intensity ·
  /// [peakFactor]). Every point shares the kernel radius [radius], in
  /// pixels; group points by radius for a data-driven one. Points
  /// outside the grid still count wherever their kernel reaches in.
  void accumulate(
    Float32List xs,
    Float32List ys,
    Float32List peaks,
    int count,
    double radius,
  ) {
    if (count == 0 || radius <= 0) return;
    final r = radius / cell; // in cells
    final h = (reachInRadii * r).ceil();
    final taps = 2 * h + 1;
    final direct = count * taps * taps;
    final separable = (height + 2 * h + height) * width * taps;
    if (direct <= separable) {
      _accumulateDirect(xs, ys, peaks, count, r, h);
    } else {
      _accumulateSeparable(xs, ys, peaks, count, r, h);
    }
  }

  /// `exp(−4.5 · (d / r)²)` for d = −h..h cells.
  static Float32List _kernel(double r, int h) {
    final k = Float32List(2 * h + 1);
    final a = -4.5 / (r * r);
    for (var i = -h; i <= h; i++) {
      k[i + h] = math.exp(a * i * i);
    }
    return k;
  }

  void _accumulateDirect(Float32List xs, Float32List ys, Float32List peaks,
      int count, double r, int h) {
    final a = -4.5 / (r * r);
    final ex = Float64List(2 * h + 2);
    final inv = 1 / cell;
    final out = values;
    for (var p = 0; p < count; p++) {
      final peak = peaks[p];
      if (peak <= 0) continue;
      // Cell i's centre is at i + 0.5 cells.
      final gx = xs[p] * inv - 0.5;
      final gy = ys[p] * inv - 0.5;
      final x0 = math.max(0, (gx - h).ceil());
      final x1 = math.min(width - 1, (gx + h).floor());
      final y0 = math.max(0, (gy - h).ceil());
      final y1 = math.min(height - 1, (gy + h).floor());
      if (x0 > x1 || y0 > y1) continue;
      for (var x = x0; x <= x1; x++) {
        final dx = x - gx;
        ex[x - x0] = math.exp(a * dx * dx);
      }
      for (var y = y0; y <= y1; y++) {
        final dy = y - gy;
        final ey = peak * math.exp(a * dy * dy);
        final row = y * width;
        for (var x = x0; x <= x1; x++) {
          out[row + x] += ey * ex[x - x0];
        }
      }
    }
  }

  void _accumulateSeparable(Float32List xs, Float32List ys, Float32List peaks,
      int count, double r, int h) {
    // The splat grid extends h cells past every edge, so a point just
    // outside the grid still blurs into it.
    final sw = width + 2 * h;
    final sh = height + 2 * h;
    final splat = Float32List(sw * sh);
    final rowUsed = Uint8List(sh);
    final inv = 1 / cell;
    for (var p = 0; p < count; p++) {
      final peak = peaks[p];
      if (peak <= 0) continue;
      final gx = xs[p] * inv - 0.5 + h;
      final gy = ys[p] * inv - 0.5 + h;
      final ix = gx.floor();
      final iy = gy.floor();
      if (ix < -1 || iy < -1 || ix >= sw || iy >= sh) continue;
      final fx = gx - ix;
      final fy = gy - iy;
      for (var j = 0; j < 2; j++) {
        final y = iy + j;
        if (y < 0 || y >= sh) continue;
        final wy = peak * (j == 0 ? 1 - fy : fy);
        for (var i = 0; i < 2; i++) {
          final x = ix + i;
          if (x < 0 || x >= sw) continue;
          splat[y * sw + x] += wy * (i == 0 ? 1 - fx : fx);
        }
        rowUsed[y] = 1;
      }
    }
    final k = _kernel(r, h);
    final taps = k.length;
    // Along x, only for rows that received a point and only for the
    // columns the output keeps.
    final across = Float32List(width * sh);
    for (var y = 0; y < sh; y++) {
      if (rowUsed[y] == 0) continue;
      final src = y * sw;
      final dst = y * width;
      for (var x = 0; x < width; x++) {
        var sum = 0.0;
        final base = src + x; // splat column x + t − h, for tap t
        for (var t = 0; t < taps; t++) {
          sum += splat[base + t] * k[t];
        }
        across[dst + x] = sum;
      }
    }
    // Along y, into the output rows.
    final out = values;
    for (var y = 0; y < height; y++) {
      var any = false;
      for (var t = 0; t < taps; t++) {
        if (rowUsed[y + t] != 0) {
          any = true;
          break;
        }
      }
      if (!any) continue;
      final dst = y * width;
      for (var x = 0; x < width; x++) {
        var sum = 0.0;
        var src = y * width + x; // across row y + t − h + h, for tap t
        for (var t = 0; t < taps; t++) {
          sum += across[src] * k[t];
          src += width;
        }
        out[dst + x] += sum;
      }
    }
  }

  /// Colours the density through [ramp] — 256 premultiplied RGBA
  /// colours, packed as [packRgba] does, for densities 0, 1/255 … 1 —
  /// into `rgba8888` pixels [upsampling] times finer than the grid, the
  /// density bilinearly interpolated between cell centres first (and
  /// held at the edges). Interpolating the density rather than the
  /// colours keeps every ramp stop between two cells on screen.
  Uint8List colorize(Uint32List ramp, int upsampling) {
    final ow = width * upsampling;
    final oh = height * upsampling;
    final pixels = Uint32List(ow * oh);
    // Per output column: the two cells it lies between, and the weight
    // of the second.
    final col0 = Int32List(ow);
    final col1 = Int32List(ow);
    final colF = Float32List(ow);
    for (var x = 0; x < ow; x++) {
      final g = (x + 0.5) / upsampling - 0.5;
      final i = g.floor();
      col0[x] = i.clamp(0, width - 1);
      col1[x] = (i + 1).clamp(0, width - 1);
      colF[x] = g - i;
    }
    final row = Float32List(width);
    final skipZero = ramp[0] == 0;
    for (var y = 0; y < oh; y++) {
      final g = (y + 0.5) / upsampling - 0.5;
      final j = g.floor();
      final r0 = j.clamp(0, height - 1) * width;
      final r1 = (j + 1).clamp(0, height - 1) * width;
      final f = g - j;
      var any = false;
      for (var i = 0; i < width; i++) {
        final v = values[r0 + i] * (1 - f) + values[r1 + i] * f;
        row[i] = v;
        if (v > 0) any = true;
      }
      if (!any && skipZero) continue;
      final dst = y * ow;
      for (var x = 0; x < ow; x++) {
        final a = row[col0[x]];
        final t = a + (row[col1[x]] - a) * colF[x];
        // Densities above 1 take the ramp's last colour.
        final index = t <= 0 ? 0 : (t >= 1 ? 255 : (t * 255 + 0.5).toInt());
        pixels[dst + x] = ramp[index];
      }
    }
    return pixels.buffer.asUint8List();
  }

  /// One premultiplied colour, packed so that a [Uint32List] of them
  /// reads as `rgba8888` bytes on a little-endian host — every platform
  /// Flutter runs on.
  static int packRgba(double r, double g, double b, double a) {
    final alpha = a.clamp(0.0, 1.0);
    int channel(double c) => (c.clamp(0.0, 1.0) * alpha * 255 + 0.5).toInt();
    return channel(r) |
        (channel(g) << 8) |
        (channel(b) << 16) |
        ((alpha * 255 + 0.5).toInt() << 24);
  }
}

/// Points sharing one kernel radius, positioned in a [HeatmapJob]'s grid
/// pixels.
class HeatmapBatch {
  final double radius;
  final Float32List xs;
  final Float32List ys;

  /// Each point's density peak: weight · intensity · [HeatmapGrid.peakFactor].
  final Float32List peaks;

  const HeatmapBatch(this.radius, this.xs, this.ys, this.peaks);
}

/// One heatmap layer's density pass as plain data — what a worker
/// isolate takes, and [renderHeatmap] turns into pixels.
class HeatmapJob {
  /// The density grid: cells across and down, and the cell edge.
  final int width;
  final int height;
  final double cell;

  /// Output pixels across one cell.
  final int upsampling;

  /// `heatmap-color` at densities 0, 1/255 … 1, packed as
  /// [HeatmapGrid.packRgba] does.
  final Uint32List ramp;
  final List<HeatmapBatch> batches;

  const HeatmapJob({
    required this.width,
    required this.height,
    required this.cell,
    required this.upsampling,
    required this.ramp,
    required this.batches,
  });

  int get outputWidth => width * upsampling;
  int get outputHeight => height * upsampling;
}

/// [job]'s density, coloured into premultiplied `rgba8888` pixels.
Uint8List renderHeatmap(HeatmapJob job) {
  final grid = HeatmapGrid(job.width, job.height, job.cell);
  for (final batch in job.batches) {
    grid.accumulate(
        batch.xs, batch.ys, batch.peaks, batch.xs.length, batch.radius);
  }
  return grid.colorize(job.ramp, job.upsampling);
}
