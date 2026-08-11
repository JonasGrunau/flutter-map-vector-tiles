import 'dart:ui' as ui;

/// A sprite sheet: one decoded image plus named sub-rectangles.
class SpriteAtlas {
  final ui.Image image;
  final Map<String, Sprite> sprites;

  /// The pixel ratio the sheet was rendered at (2 for `@2x`).
  final double pixelRatio;

  /// Identifies the sheet this atlas was built from — its URL, when
  /// `StyleReader` loaded it. Used by [signature]; see there for why an
  /// atlas needs a content-derived identity.
  final String? cacheKey;

  const SpriteAtlas({
    required this.image,
    required this.sprites,
    required this.pixelRatio,
    this.cacheKey,
  });

  /// Identifies this atlas's *content* for cache keys: two atlases with
  /// equal signatures render identically, so imagery baked with one may
  /// be reused with the other.
  ///
  /// Object identity cannot serve here. Re-reading a style yields a new
  /// atlas every time, so identity would treat each map open as a
  /// different sheet — missing every cache that outlives a layer and
  /// stranding the entries the previous atlas left behind.
  String get signature {
    final key = cacheKey;
    if (key != null) return key;
    // No URL (a hand-built atlas): the sheet's geometry stands in.
    final names = sprites.keys.toList()..sort();
    var hash = Object.hash(image.width, image.height, pixelRatio, names.length);
    for (final name in names) {
      final sprite = sprites[name]!;
      hash = Object.hash(hash, name, sprite.x, sprite.y, sprite.width,
          sprite.height, sprite.pixelRatio, sprite.sdf);
    }
    return 'atlas:$hash';
  }

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
