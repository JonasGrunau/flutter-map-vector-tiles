import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:meta/meta.dart';

import 'sprite_atlas.dart';

/// Transparent gutter, in sheet pixels, around every repacked sprite.
///
/// Two pixels, not MapLibre's one: icons draw with mipmapped filtering,
/// and the first mip level averages 2x2 texels.
const spriteGutter = 2;

/// Packed sheets larger than this on either side keep their original
/// layout; 4096 is a texture size every GPU this package runs on accepts.
const _maxSheetSide = 4096;

/// Repacks [atlas] so every sprite sits inside a [gutter] of transparent
/// pixels, and disposes the original sheet.
///
/// Sprite sheets pack their images edge to edge. A sprite drawn at any
/// scale other than 1:1, or at a fractional position, is sampled with
/// bilinear filtering, and the filter reaches half a texel past the
/// sprite's rectangle — into its neighbour. That showed as thin lines
/// along icon edges in the neighbour's colour. MapLibre repacks icons
/// into its own padded atlas for the same reason.
///
/// Returns [atlas] unchanged when there is nothing to pack, when the
/// sheet cannot be read back, or when the packed sheet would be too
/// large; the original sheet is only disposed on success. Aliases (names
/// sharing one rectangle) stay aliases.
Future<SpriteAtlas> padSpriteSheet(SpriteAtlas atlas,
    {int gutter = spriteGutter}) async {
  final sheet = atlas.image;
  final cells = <(int, int, int, int), _Cell>{};
  final cellOf = <String, _Cell>{};
  atlas.sprites.forEach((name, sprite) {
    // A cell spans the sprite's whole rectangle, even where an index
    // entry hangs off the sheet: that part stays transparent in the cell
    // instead of the drawn rectangle reaching into the next one.
    final x0 = sprite.x.floor(), y0 = sprite.y.floor();
    final x1 = (sprite.x + sprite.width).ceil();
    final y1 = (sprite.y + sprite.height).ceil();
    final onSheet = x0 < sheet.width && y0 < sheet.height && x1 > 0 && y1 > 0;
    if (x1 <= x0 || y1 <= y0 || !onSheet) return;
    cellOf[name] = cells
        .putIfAbsent((x0, y0, x1, y1), () => _Cell(x0, y0, x1 - x0, y1 - y0));
  });
  if (cells.isEmpty) return atlas;

  // Shelf packing, tallest first, in rows as wide as the source sheet.
  final order = cells.values.toList()
    ..sort((a, b) => a.h != b.h ? b.h - a.h : b.w - a.w);
  final width = math.max(
      sheet.width, order.map((c) => c.w + 2 * gutter).reduce(math.max));
  var x = 0, y = 0, rowHeight = 0;
  for (final cell in order) {
    final cellWidth = cell.w + 2 * gutter;
    if (x + cellWidth > width) {
      y += rowHeight;
      x = 0;
      rowHeight = 0;
    }
    cell
      ..dx = x + gutter
      ..dy = y + gutter;
    x += cellWidth;
    rowHeight = math.max(rowHeight, cell.h + 2 * gutter);
  }
  final height = y + rowHeight;
  if (width > _maxSheetSide || height > _maxSheetSide) return atlas;

  // Premultiplied in, premultiplied out (`PixelFormat.rgba8888`), so the
  // copy is byte-exact.
  final data = await sheet.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (data == null) return atlas;
  final src = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  final dst = Uint8List(width * height * 4);
  for (final cell in order) {
    // Only the part of the cell that exists on the source sheet.
    final left = math.max(0, cell.x0);
    final right = math.min(sheet.width, cell.x0 + cell.w);
    final top = math.max(0, cell.y0);
    final bottom = math.min(sheet.height, cell.y0 + cell.h);
    final rowBytes = (right - left) * 4;
    for (var row = top; row < bottom; row++) {
      final from = (row * sheet.width + left) * 4;
      final to =
          ((cell.dy + row - cell.y0) * width + cell.dx + left - cell.x0) * 4;
      dst.setRange(to, to + rowBytes, src, from);
    }
  }
  final image = await decodeRgbaPixels(dst, width, height);

  final sprites = <String, Sprite>{
    for (final MapEntry(key: name, value: sprite) in atlas.sprites.entries)
      if (cellOf[name] case final cell?)
        name: Sprite(
          x: cell.dx + (sprite.x - cell.x0),
          y: cell.dy + (sprite.y - cell.y0),
          width: sprite.width,
          height: sprite.height,
          pixelRatio: sprite.pixelRatio,
          sdf: sprite.sdf,
        ),
  };
  sheet.dispose();
  return SpriteAtlas(
    image: image,
    sprites: sprites,
    pixelRatio: atlas.pixelRatio,
    cacheKey: atlas.cacheKey,
  );
}

/// [ui.decodeImageFromPixels], with its failures delivered.
///
/// It reports only success, through its callback: when the decode
/// fails, the error escapes as an uncaught error in the calling zone and
/// the callback never runs, so a style load awaiting it would hang. A
/// guarded zone routes that error into the returned future instead.
/// `ImageDescriptor.raw` would propagate errors by itself, but on web
/// it goes through a BMP, which browsers read as straight alpha, and
/// these pixels are premultiplied. On web, CanvasKit reports a failed
/// decode only as a console warning, which no zone can catch; the packer
/// always passes exactly `width * height * 4` bytes, so a malformed
/// buffer, the usual cause, cannot reach it.
@visibleForTesting
Future<ui.Image> decodeRgbaPixels(Uint8List pixels, int width, int height) {
  final completer = Completer<ui.Image>();
  runZonedGuarded(
    () => ui.decodeImageFromPixels(
      pixels,
      width,
      height,
      ui.PixelFormat.rgba8888,
      (image) =>
          completer.isCompleted ? image.dispose() : completer.complete(image),
    ),
    (error, stack) {
      if (!completer.isCompleted) completer.completeError(error, stack);
    },
  );
  return completer.future;
}

class _Cell {
  _Cell(this.x0, this.y0, this.w, this.h);

  /// Source rectangle, in whole sheet pixels; may hang off the sheet.
  final int x0, y0, w, h;

  /// Where the source rectangle lands in the packed sheet.
  int dx = 0, dy = 0;
}
