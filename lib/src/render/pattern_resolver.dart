import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../style/sprite_atlas.dart';

/// Crops `fill-pattern` sprites out of the atlas into standalone
/// [ui.Image]s usable with [ui.ImageShader], caching them by name.
///
/// Owned by the layer state; images are disposed with it. Missing
/// sprites are cached as null so unknown names are looked up only once.
class PatternResolver {
  final SpriteAtlas atlas;
  final _cache = <String, ui.Image?>{};
  var _disposed = false;

  PatternResolver(this.atlas);

  /// The pixel ratio the pattern images inherit from the sprite sheet.
  double get pixelRatio => atlas.pixelRatio;

  ui.Image? imageFor(String name) {
    if (_disposed) return null;
    if (_cache.containsKey(name)) return _cache[name];
    ui.Image? image;
    final sprite = atlas[name];
    if (sprite != null && sprite.width >= 1 && sprite.height >= 1) {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawImageRect(
        atlas.image,
        sprite.sourceRect,
        Rect.fromLTWH(0, 0, sprite.width, sprite.height),
        Paint(),
      );
      final picture = recorder.endRecording();
      image = picture.toImageSync(sprite.width.round(), sprite.height.round());
      picture.dispose();
    }
    _cache[name] = image;
    return image;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final image in _cache.values) {
      image?.dispose();
    }
    _cache.clear();
  }
}
