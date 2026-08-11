import 'dart:ui' as ui;

import 'package:flutter_map_vector_tiles/src/style/sprite_atlas.dart';
import 'package:flutter_test/flutter_test.dart';

ui.Image _image(int size) {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    ui.Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
    ui.Paint()..color = const ui.Color(0xff00ff00),
  );
  final picture = recorder.endRecording();
  final image = picture.toImageSync(size, size);
  picture.dispose();
  return image;
}

SpriteAtlas _atlas({
  String? cacheKey,
  int size = 8,
  double pixelRatio = 2,
  Map<String, Sprite>? sprites,
}) =>
    SpriteAtlas(
      image: _image(size),
      pixelRatio: pixelRatio,
      cacheKey: cacheKey,
      sprites: sprites ??
          const {
            'pin': Sprite(x: 0, y: 0, width: 4, height: 4, pixelRatio: 2),
          },
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SpriteAtlas.signature', () {
    // Caches that outlive a layer are keyed partly by the sprite sheet.
    // Re-reading a style builds a new atlas object every time, so an
    // identity-based key would miss on every map open — and leave the
    // previous atlas's entries stranded, holding their textures with no
    // way to reach them again.
    test('two atlases loaded from the same sheet agree', () {
      final first = _atlas(cacheKey: 'https://tiles/sprite@2x.png');
      final second = _atlas(cacheKey: 'https://tiles/sprite@2x.png');
      addTearDown(first.dispose);
      addTearDown(second.dispose);

      expect(identical(first, second), isFalse);
      expect(first.signature, second.signature);
    });

    test('different sheets differ', () {
      final first = _atlas(cacheKey: 'https://tiles/sprite@2x.png');
      final second = _atlas(cacheKey: 'https://tiles/dark@2x.png');
      addTearDown(first.dispose);
      addTearDown(second.dispose);

      expect(first.signature, isNot(second.signature));
    });

    test('without a URL, equal content still agrees', () {
      final first = _atlas();
      final second = _atlas();
      addTearDown(first.dispose);
      addTearDown(second.dispose);

      expect(first.signature, second.signature);
    });

    test('without a URL, the sheet geometry distinguishes atlases', () {
      final base = _atlas();
      final biggerSheet = _atlas(size: 16);
      final otherRatio = _atlas(pixelRatio: 1);
      final movedSprite = _atlas(sprites: const {
        'pin': Sprite(x: 4, y: 0, width: 4, height: 4, pixelRatio: 2),
      });
      final renamedSprite = _atlas(sprites: const {
        'marker': Sprite(x: 0, y: 0, width: 4, height: 4, pixelRatio: 2),
      });
      for (final atlas in [
        base,
        biggerSheet,
        otherRatio,
        movedSprite,
        renamedSprite
      ]) {
        addTearDown(atlas.dispose);
      }

      expect(
        {
          biggerSheet.signature,
          otherRatio.signature,
          movedSprite.signature,
          renamedSprite.signature,
        },
        everyElement(isNot(base.signature)),
      );
    });
  });
}
