import 'dart:math' as math;
import 'dart:ui' show Color;

/// The space `interpolate`, `interpolate-hcl` and `interpolate-lab` (and
/// a legacy function's `colorSpace`) blend colours in.
enum ColorSpace { rgb, hcl, lab }

/// [a] → [b] at [t] in [space]. RGB blends the straight (not
/// premultiplied) channels; LAB blends CIE L*a*b*, HCL its polar form
/// with the hue taking the shorter way round. Alpha is linear in all
/// three.
Color lerpColor(Color a, Color b, double t, ColorSpace space) {
  if (space == ColorSpace.rgb) return Color.lerp(a, b, t)!;
  final la = _Lab.of(a);
  final lb = _Lab.of(b);
  final alpha = a.a + (b.a - a.a) * t;
  if (space == ColorSpace.lab) {
    return _Lab(
      la.l + (lb.l - la.l) * t,
      la.a + (lb.a - la.a) * t,
      la.b + (lb.b - la.b) * t,
    ).toColor(alpha);
  }
  final ha = la.hue, hb = lb.hue;
  final ca = la.chroma, cb = lb.chroma;
  // A grey has no hue: it takes the other colour's, so blending towards
  // grey desaturates instead of swinging through red.
  final double h;
  if (ha.isNaN && hb.isNaN) {
    h = 0;
  } else if (ha.isNaN) {
    h = hb;
  } else if (hb.isNaN) {
    h = ha;
  } else {
    var d = hb - ha;
    if (d > 180) d -= 360;
    if (d < -180) d += 360;
    h = ha + d * t;
  }
  final c = ca + (cb - ca) * t;
  final rad = h * math.pi / 180;
  return _Lab(la.l + (lb.l - la.l) * t, c * math.cos(rad), c * math.sin(rad))
      .toColor(alpha);
}

/// CIE L*a*b* relative to the D50 white point, from sRGB through the
/// Bradford-adapted sRGB → XYZ(D50) matrix — the definition style
/// renderers blend `interpolate-lab` in.
final class _Lab {
  final double l, a, b;
  const _Lab(this.l, this.a, this.b);

  static const _xn = 0.96422, _yn = 1.0, _zn = 0.82521;
  static const _t0 = 4 / 29, _t1 = 6 / 29;
  static const _t2 = 3 * _t1 * _t1, _t3 = _t1 * _t1 * _t1;

  factory _Lab.of(Color c) {
    final r = _linear(c.r), g = _linear(c.g), b = _linear(c.b);
    final y = _f((0.2225045 * r + 0.7168786 * g + 0.0606169 * b) / _yn);
    final double x, z;
    if (r == g && g == b) {
      x = z = y;
    } else {
      x = _f((0.4360747 * r + 0.3850649 * g + 0.1430804 * b) / _xn);
      z = _f((0.0139322 * r + 0.0971045 * g + 0.7141733 * b) / _zn);
    }
    return _Lab(116 * y - 16, 500 * (x - y), 200 * (y - z));
  }

  double get chroma => math.sqrt(a * a + b * b);

  /// Degrees in [0, 360); NaN for a grey.
  double get hue {
    if (a.abs() < 1e-9 && b.abs() < 1e-9) return double.nan;
    final h = math.atan2(b, a) * 180 / math.pi;
    return h < 0 ? h + 360 : h;
  }

  Color toColor(double alpha) {
    var y = (l + 16) / 116;
    var x = y + a / 500;
    var z = y - b / 200;
    x = _xn * _fInverse(x);
    y = _yn * _fInverse(y);
    z = _zn * _fInverse(z);
    return Color.from(
      alpha: alpha.clamp(0.0, 1.0),
      red: _gamma(3.1338561 * x - 1.6168667 * y - 0.4906146 * z),
      green: _gamma(-0.9787684 * x + 1.9161415 * y + 0.0334540 * z),
      blue: _gamma(0.0719453 * x - 0.2289914 * y + 1.4052427 * z),
    );
  }

  static double _f(double t) =>
      t > _t3 ? math.pow(t, 1 / 3).toDouble() : t / _t2 + _t0;

  static double _fInverse(double t) => t > _t1 ? t * t * t : _t2 * (t - _t0);

  static double _linear(double c) =>
      c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();

  static double _gamma(double c) => (c <= 0.0031308
          ? 12.92 * c
          : 1.055 * math.pow(c, 1 / 2.4).toDouble() - 0.055)
      .clamp(0.0, 1.0);
}

/// The CSS / style-spec `cubic-bezier` easing through (0, 0), ([x1],
/// [y1]), ([x2], [y2]), (1, 1): for an input progress it finds the curve
/// parameter whose x is that progress — Newton's method, falling back
/// to bisection where the slope is too flat — to within 1e-6, and
/// returns the curve's y there.
double Function(double) cubicBezier(
    double x1, double y1, double x2, double y2) {
  // Polynomial coefficients of x(s) and y(s) = ((a s + b) s + c) s.
  final cx = 3 * x1, bx = 3 * (x2 - x1) - cx, ax = 1 - cx - bx;
  final cy = 3 * y1, by = 3 * (y2 - y1) - cy, ay = 1 - cy - by;
  double curveX(double s) => ((ax * s + bx) * s + cx) * s;
  double curveY(double s) => ((ay * s + by) * s + cy) * s;
  double slopeX(double s) => (3 * ax * s + 2 * bx) * s + cx;
  const epsilon = 1e-6;

  double solve(double x) {
    var s = x;
    for (var i = 0; i < 8; i++) {
      final err = curveX(s) - x;
      if (err.abs() < epsilon) return s;
      final d = slopeX(s);
      if (d.abs() < 1e-6) break;
      s -= err / d;
    }
    var lo = 0.0, hi = 1.0;
    s = x;
    if (s < lo) return lo;
    if (s > hi) return hi;
    while (lo < hi) {
      final v = curveX(s);
      if ((v - x).abs() < epsilon) return s;
      if (x > v) {
        lo = s;
      } else {
        hi = s;
      }
      s = (hi - lo) / 2 + lo;
      if (hi - lo < 1e-12) break;
    }
    return s;
  }

  return (t) => curveY(solve(t));
}
