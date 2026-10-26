import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// Compares a golden by what a reader sees rather than byte for byte, so
/// that goldens made on macOS hold on CI's Linux.
///
/// Both platforms shape the same fonts with the same HarfBuzz, so every
/// glyph lands in the same place; but CoreText draws the edges of a
/// glyph on macOS and FreeType on Linux, and their anti-aliasing
/// differs. So the images are compared as two masks — the dark text and
/// the light halo around it, against the grey background the goldens
/// are drawn on — each matched to the other within a device pixel. What
/// is left over is scattered single pixels when only the rasterizer
/// differs; a missing mark, a moved letter or a line broken elsewhere
/// leaves a patch. The comparison fails on a patch bigger than
/// [maxPatch] device pixels.
/// Makes the goldens of the test file at [testFile] compare through a
/// [TolerantGoldenComparator].
void useTolerantGoldens(String testFile) {
  final local = goldenFileComparator as LocalFileComparator;
  goldenFileComparator =
      TolerantGoldenComparator(local.basedir.resolve(testFile));
}

class TolerantGoldenComparator extends LocalFileComparator {
  TolerantGoldenComparator(super.testFile);

  /// The largest connected patch of ink, in device pixels, that one
  /// image may have and the other may not have within a pixel of it.
  /// The dot of an i is about 20 at the suite's text size.
  static const maxPatch = 12;

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async {
    final goldenBytes = Uint8List.fromList(await getGoldenBytes(golden));
    final actual = await _Pixels.decode(imageBytes);
    final expected = await _Pixels.decode(goldenBytes);
    final String verdict;
    if (actual.width != expected.width || actual.height != expected.height) {
      verdict = 'size ${actual.width}x${actual.height}, golden '
          '${expected.width}x${expected.height}';
    } else {
      final patch = _largestPatch(actual, expected);
      if (patch <= maxPatch) return true;
      verdict = 'a patch of $patch device pixels differs (at most $maxPatch '
          'may)';
    }
    final result =
        await GoldenFileComparator.compareLists(imageBytes, goldenBytes);
    final output = result.passed
        ? ''
        : await generateFailureOutput(result, golden, basedir);
    throw FlutterError('$golden: $verdict.\n$output');
  }

  /// The largest connected patch of mask pixels in one image with none
  /// of the same mask within a pixel of it in the other.
  static int _largestPatch(_Pixels a, _Pixels b) {
    final width = a.width, height = a.height;
    final unmatched = Uint8List(width * height);
    for (final mask in [_Pixels.isDark, _Pixels.isLight]) {
      for (final (from, to) in [(a, b), (b, a)]) {
        for (var y = 0; y < height; y++) {
          for (var x = 0; x < width; x++) {
            if (mask(from, x, y) && !to.near(mask, x, y)) {
              unmatched[y * width + x] = 1;
            }
          }
        }
      }
    }
    var largest = 0;
    final stack = <int>[];
    for (var start = 0; start < unmatched.length; start++) {
      if (unmatched[start] != 1) continue;
      unmatched[start] = 2;
      stack.add(start);
      var size = 0;
      while (stack.isNotEmpty) {
        final i = stack.removeLast();
        size++;
        final x = i % width, y = i ~/ width;
        for (final (nx, ny) in [
          (x - 1, y),
          (x + 1, y),
          (x, y - 1),
          (x, y + 1)
        ]) {
          if (nx < 0 || ny < 0 || nx >= width || ny >= height) continue;
          final n = ny * width + nx;
          if (unmatched[n] == 1) {
            unmatched[n] = 2;
            stack.add(n);
          }
        }
      }
      if (size > largest) largest = size;
    }
    return largest;
  }
}

class _Pixels {
  final int width;
  final int height;
  final Uint8List rgba;

  _Pixels(this.width, this.height, this.rgba);

  static Future<_Pixels> decode(Uint8List png) async {
    final codec = await ui.instantiateImageCodec(png);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final data =
        await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    final pixels =
        _Pixels(image.width, image.height, data!.buffer.asUint8List());
    image.dispose();
    codec.dispose();
    return pixels;
  }

  int _luminance(int x, int y) {
    final i = (y * width + x) * 4;
    return (rgba[i] * 299 + rgba[i + 1] * 587 + rgba[i + 2] * 114) ~/ 1000;
  }

  /// Text, well darker than the grey background.
  static bool isDark(_Pixels p, int x, int y) => p._luminance(x, y) < 110;

  /// Halo, well lighter than the grey background.
  static bool isLight(_Pixels p, int x, int y) => p._luminance(x, y) > 228;

  bool near(bool Function(_Pixels, int, int) mask, int x, int y) {
    for (var dy = -1; dy <= 1; dy++) {
      final yy = y + dy;
      if (yy < 0 || yy >= height) continue;
      for (var dx = -1; dx <= 1; dx++) {
        final xx = x + dx;
        if (xx >= 0 && xx < width && mask(this, xx, yy)) return true;
      }
    }
    return false;
  }
}
