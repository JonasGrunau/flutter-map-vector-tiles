import 'dart:ui' as ui;

/// A sprite sheet: one decoded image plus named sub-rectangles.
class SpriteAtlas {
  final ui.Image image;
  final Map<String, Sprite> sprites;

  /// The pixel ratio the sheet was rendered at (2 for `@2x`).
  final double pixelRatio;

  const SpriteAtlas({
    required this.image,
    required this.sprites,
    required this.pixelRatio,
  });

  Sprite? operator [](String name) => sprites[name];

  void dispose() => image.dispose();

  /// Parses a MapLibre sprite index JSON document.
  static Map<String, Sprite> parseIndex(Map<String, Object?> json) {
    final sprites = <String, Sprite>{};
    json.forEach((name, value) {
      if (value is Map) {
        final v = value.cast<String, Object?>();
        final x = v['x'], y = v['y'], w = v['width'], h = v['height'];
        if (x is num && y is num && w is num && h is num) {
          sprites[name] = Sprite(
            x: x.toDouble(),
            y: y.toDouble(),
            width: w.toDouble(),
            height: h.toDouble(),
            pixelRatio: (v['pixelRatio'] as num?)?.toDouble() ?? 1,
            sdf: v['sdf'] == true,
          );
        }
      }
    });
    return sprites;
  }
}

class Sprite {
  final double x;
  final double y;
  final double width;
  final double height;
  final double pixelRatio;

  /// Whether the sheet stores this image as a signed distance field
  /// (`"sdf": true` in the index). SDF sprites carry their shape in the
  /// alpha channel — the sheet's RGB is a single flat colour — and must
  /// be thresholded and tinted with `icon-color`. Blitting one directly
  /// paints the raw field: a fuzzy silhouette in the sheet's flat
  /// colour, which on dark styles reads as a dark blob.
  final bool sdf;

  const Sprite({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.pixelRatio,
    this.sdf = false,
  });

  ui.Rect get sourceRect => ui.Rect.fromLTWH(x, y, width, height);
}
