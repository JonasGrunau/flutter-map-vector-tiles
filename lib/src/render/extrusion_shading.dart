import 'dart:math' as math;
import 'dart:typed_data';

import '../style/expression.dart';
import '../style/theme.dart';

/// A style's `light`, evaluated at one zoom: what MapLibre GL hands its
/// extrusion shader as uniforms.
class ExtrusionLight {
  /// The light's position in Cartesian terms (MapLibre's
  /// `sphericalToCartesian`), in the frame it is anchored to: x right, y
  /// down, z up.
  final double x, y, z;

  /// Whether the light is fixed to the viewport rather than the map.
  final bool viewport;

  /// `light-intensity`, clamped to 0..1.
  final double intensity;

  /// The light colour's channels, 0..1.
  final double red, green, blue;

  const ExtrusionLight._(this.x, this.y, this.z, this.viewport, this.intensity,
      this.red, this.green, this.blue);

  /// [light] (the spec's default for null) at [zoom].
  factory ExtrusionLight.of(StyleLight? light, double zoom) {
    final l = light ?? StyleLight.standard;
    final ctx = EvalContext(zoom: zoom);
    final position = l.position.eval(ctx);
    final r = position.isNotEmpty ? position[0] : 1.15;
    // Azimuth 0 is the top of the frame, which is 90° in maths terms.
    final azimuthal =
        ((position.length > 1 ? position[1] : 210) + 90) * math.pi / 180;
    final polar = (position.length > 2 ? position[2] : 30) * math.pi / 180;
    final color = l.color.eval(ctx);
    return ExtrusionLight._(
      r * math.cos(azimuthal) * math.sin(polar),
      r * math.sin(azimuthal) * math.sin(polar),
      r * math.cos(polar),
      l.anchor.eval(ctx) != 'map',
      l.intensity.eval(ctx).clamp(0.0, 1.0),
      color.r,
      color.g,
      color.b,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ExtrusionLight &&
      other.x == x &&
      other.y == y &&
      other.z == z &&
      other.viewport == viewport &&
      other.intensity == intensity &&
      other.red == red &&
      other.green == green &&
      other.blue == blue;

  @override
  int get hashCode =>
      Object.hash(x, y, z, viewport, intensity, red, green, blue);
}

/// MapLibre GL's `fill-extrusion` lighting (`fill_extrusion.vertex.glsl`),
/// on the CPU.
///
/// A surface's colour is the layer colour — premultiplied, so a
/// translucent colour draws darker, never translucent — plus a 3 %
/// ambient term, times a *directional* factor that runs from
/// `1 - intensity` for a surface turned away from the light to
/// `max(1 - luminance + intensity, 1)` for one facing it, times the light
/// colour, clamped below towards the light colour's complement. A roof
/// faces the light by how high it stands (`position`'s z); a wall by the
/// cosine between its normal and the light's horizontal direction, its
/// colour then running down to its foot by `fill-extrusion-vertical-gradient`.
abstract final class ExtrusionShading {
  /// Wall light levels: how finely the cosine between a wall and the
  /// light is resolved. 64 levels step the colour by under 2/255.
  static const int levels = 64;

  /// Ints per colour class in [table]: the roof, then [levels] wall
  /// colours at the foot, then [levels] at the top.
  static const int stride = 1 + 2 * levels;

  /// No vertical gradient: [gradientKey]'s value for a wall shaded the
  /// same top to bottom.
  static const int noGradient = 255;

  /// The vertical gradient's input at one end of a wall, `(t + base) ·
  /// sqrt(height / 150)` for t = 0 at the foot and 1 at the top,
  /// quantized for a colour class key: 0..127 for 0..1. MapLibre clamps
  /// it to at least `0.7 + 0.28 · (1 − intensity)`, never under 0.7, so
  /// every value below that is one key: most buildings of a tile share
  /// a class instead of one per height.
  static int gradientKey(double t, double base, double height) {
    final v = (t + base) * math.sqrt(height / 150);
    return v >= 1 ? 127 : math.max((v * 127).round(), _lowestKey);
  }

  /// The largest key under 0.7: below every floor the shader clamps to.
  static const int _lowestKey = 88;

  /// The colours of one class — layer colour [argb], gradient keys
  /// [bottom] and [top] — under [light], written into [out] at
  /// [offset], [stride] ints.
  static void fill(Int32List out, int offset, int argb, int bottom, int top,
      ExtrusionLight light) {
    final a = ((argb >> 24) & 0xff) / 255;
    final r = ((argb >> 16) & 0xff) / 255 * a;
    final g = ((argb >> 8) & 0xff) / 255 * a;
    final b = (argb & 0xff) / 255 * a;
    final luminance = r * 0.2126 + g * 0.7152 + b * 0.0722;
    final intensity = light.intensity;
    final dark = 1 - intensity;
    final bright = math.max(1 - luminance + intensity, 1.0);
    double directional(double d) => dark + (bright - dark) * d;
    out[offset] = _color(r, g, b, directional(light.z.clamp(0.0, 1.0)), light);
    final floor = 0.7 + 0.28 * (1 - intensity);
    double gradient(int key) =>
        key == noGradient ? 1 : math.max(key / 127, floor).clamp(0.0, 1.0);
    final gb = gradient(bottom), gt = gradient(top);
    for (var level = 0; level < levels; level++) {
      final d = directional(level / (levels - 1));
      out[offset + 1 + level] = _color(r, g, b, d * gb, light);
      out[offset + 1 + levels + level] = _color(r, g, b, d * gt, light);
    }
  }

  static int _color(
      double r, double g, double b, double factor, ExtrusionLight light) {
    int channel(double c, double lightChannel) {
      final lower = 0.3 * (1 - lightChannel);
      final v = ((c + 0.03) * factor * lightChannel).clamp(lower, 1.0);
      return (v * 255).round();
    }

    return 0xff000000 |
        channel(r, light.red) << 16 |
        channel(g, light.green) << 8 |
        channel(b, light.blue);
  }

  /// For each of a wall normal's 256 directions (`ExtrusionMesh.wallAngle`),
  /// its light level under [light] with the map turned by [rotation]
  /// radians, into [out].
  static void levelsOf(ExtrusionLight light, double rotation, Uint8List out) {
    var lx = light.x, ly = light.y;
    if (light.viewport && rotation != 0) {
      // A light fixed to the screen turns against the map.
      final c = math.cos(-rotation), s = math.sin(-rotation);
      final x = c * lx - s * ly;
      ly = s * lx + c * ly;
      lx = x;
    }
    for (var i = 0; i < 256; i++) {
      final angle = i * 2 * math.pi / 256;
      // MapLibre's wall normal points into the building: the cosine is
      // against the inward one.
      final d = -(math.cos(angle) * lx + math.sin(angle) * ly);
      out[i] = (d.clamp(0.0, 1.0) * (levels - 1)).round();
    }
  }
}
