import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_map_vector_tiles/src/style/sprite_atlas.dart';
import 'package:flutter_map_vector_tiles/src/style/sprite_packer.dart';
import 'package:flutter_test/flutter_test.dart';

const _side = 8;

/// A 16x8 sheet packed edge to edge, the way MapTiler packs theirs:
/// 'red' fills the left 8x8 and 'blue' the right 8x8, both opaque right
/// up to their borders.
Future<ui.Image> _sheet() {
  final pixels = Uint8List(2 * _side * _side * 4);
  for (var y = 0; y < _side; y++) {
    for (var x = 0; x < 2 * _side; x++) {
      final i = (y * 2 * _side + x) * 4;
      pixels[i + (x < _side ? 0 : 2)] = 255;
      pixels[i + 3] = 255;
    }
  }
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
      pixels, 2 * _side, _side, ui.PixelFormat.rgba8888, completer.complete);
  return completer.future;
}

Future<SpriteAtlas> _atlas() async => SpriteAtlas(
      image: await _sheet(),
      pixelRatio: 2,
      cacheKey: 'sheet.png',
      sprites: const {
        'red': Sprite(x: 0, y: 0, width: 8, height: 8, pixelRatio: 2),
        'blue': Sprite(x: 8, y: 0, width: 8, height: 8, pixelRatio: 2),
        'blue-alias':
            Sprite(x: 8, y: 0, width: 8, height: 8, pixelRatio: 2, sdf: true),
      },
    );

Future<Uint8List> _rgba(ui.Image image) async {
  final data = await image.toByteData();
  return data!.buffer.asUint8List();
}

/// Draws [name] the way `_DrawableIcon` draws an icon from a 2x sheet
/// on a 2.625x screen — magnified, at a fractional position, with
/// mipmapped bilinear filtering — and counts the pixels that came out
/// with any red in them.
Future<int> _redPixels(SpriteAtlas atlas, String name) async {
  final sprite = atlas[name]!;
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawImageRect(
    atlas.image,
    sprite.sourceRect,
    const Rect.fromLTWH(3.3, 3.3, _side * 1.3125, _side * 1.3125),
    Paint()..filterQuality = FilterQuality.medium,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(20, 20);
  picture.dispose();
  final pixels = await _rgba(image);
  image.dispose();
  var red = 0;
  for (var i = 0; i < pixels.length; i += 4) {
    if (pixels[i] > 8) red++;
  }
  return red;
}

void main() {
  test('an edge-to-edge sheet bleeds the neighbour into a magnified icon',
      () async {
    // The control: without this, the next test would prove nothing.
    final atlas = await _atlas();
    expect(await _redPixels(atlas, 'blue'), greaterThan(0));
    atlas.dispose();
  },
      // CanvasKit clamps drawImageRect sampling to the source rectangle,
      // so the browser never shows the bleed this control reproduces.
      skip: kIsWeb ? 'no bleed to reproduce on web' : false);

  test('a padded sheet keeps the neighbour out of a magnified icon', () async {
    final atlas = await padSpriteSheet(await _atlas());
    expect(await _redPixels(atlas, 'blue'), 0);
    atlas.dispose();
  });

  test('repacking copies every sprite exactly, inside a transparent gutter',
      () async {
    final atlas = await padSpriteSheet(await _atlas());
    final width = atlas.image.width;
    final pixels = await _rgba(atlas.image);
    for (final (name, channel) in [('red', 0), ('blue', 2)]) {
      final sprite = atlas[name]!;
      final left = sprite.x.toInt(), top = sprite.y.toInt();
      for (var y = top - spriteGutter; y < top + _side + spriteGutter; y++) {
        for (var x = left - spriteGutter;
            x < left + _side + spriteGutter;
            x++) {
          final i = (y * width + x) * 4;
          final inside =
              x >= left && x < left + _side && y >= top && y < top + _side;
          if (inside) {
            expect(pixels[i + channel], 255, reason: '$name at ($x, $y)');
            expect(pixels[i + 3], 255, reason: '$name at ($x, $y)');
          } else {
            expect(pixels[i + 3], 0, reason: 'gutter of $name at ($x, $y)');
          }
        }
      }
    }
    atlas.dispose();
  });

  test('repacking keeps aliases, flags, pixel ratio and cache key', () async {
    final atlas = await padSpriteSheet(await _atlas());
    final blue = atlas['blue']!, alias = atlas['blue-alias']!;
    expect((alias.x, alias.y), (blue.x, blue.y));
    expect(alias.sdf, isTrue);
    expect(blue.sdf, isFalse);
    expect(blue.pixelRatio, 2);
    expect((blue.width, blue.height), (8.0, 8.0));
    expect(atlas.pixelRatio, 2);
    expect(atlas.cacheKey, 'sheet.png');
    atlas.dispose();
  });

  test('sprites outside the sheet are dropped, the rest still repack',
      () async {
    final source = await _atlas();
    final atlas = await padSpriteSheet(SpriteAtlas(
      image: source.image,
      pixelRatio: 2,
      sprites: {
        ...source.sprites,
        'off-sheet':
            const Sprite(x: 40, y: 0, width: 8, height: 8, pixelRatio: 2),
      },
    ));
    expect(atlas['off-sheet'], isNull);
    expect(await _redPixels(atlas, 'blue'), 0);
    atlas.dispose();
  });

  test('a sprite hanging off the sheet keeps clear of the next cell', () async {
    final source = await _atlas();
    final atlas = await padSpriteSheet(SpriteAtlas(
      image: source.image,
      pixelRatio: 2,
      sprites: {
        ...source.sprites,
        // Its right half lies past the sheet's edge; the narrow red
        // sprite packs right after it.
        'overhang':
            const Sprite(x: 12, y: 0, width: 8, height: 8, pixelRatio: 2),
        'red-strip':
            const Sprite(x: 0, y: 0, width: 2, height: 8, pixelRatio: 2),
      },
    ));
    expect(await _redPixels(atlas, 'overhang'), 0);
    final overhang = atlas['overhang']!;
    final width = atlas.image.width;
    final pixels = await _rgba(atlas.image);
    for (var x = 0; x < _side; x++) {
      final i = (overhang.y.toInt() * width + overhang.x.toInt() + x) * 4;
      // The half on the sheet is blue; the half past its edge is empty.
      expect(pixels[i + 3], x < 4 ? 255 : 0, reason: 'column $x');
    }
    atlas.dispose();
  });

  test('a packed sheet wider than a texture may be keeps the original',
      () async {
    // 4096 wide fits; with its gutter the one sprite needs 4100.
    final pixels = Uint8List(4096 * 4 * 4);
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
        pixels, 4096, 4, ui.PixelFormat.rgba8888, completer.complete);
    final atlas = SpriteAtlas(
      image: await completer.future,
      pixelRatio: 1,
      sprites: const {
        'wide': Sprite(x: 0, y: 0, width: 4096, height: 4, pixelRatio: 1),
      },
    );
    expect(identical(await padSpriteSheet(atlas), atlas), isTrue);
    atlas.dispose();
  });

  test('a failed pixel decode fails the future instead of hanging', () async {
    // Four bytes cannot hold 4x4 pixels; decodeImageFromPixels alone
    // would never call back.
    await expectLater(
      decodeRgbaPixels(Uint8List(4), 4, 4).timeout(const Duration(seconds: 10)),
      throwsA(isNot(isA<TimeoutException>())),
    );
  },
      // CanvasKit drops a failed decode with a console warning and
      // raises nothing a zone could catch; the packer only ever hands it
      // well-formed buffers.
      skip: kIsWeb ? 'CanvasKit reports no decode error' : false);
}
