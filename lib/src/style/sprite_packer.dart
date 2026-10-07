import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'sprite_atlas.dart';

/// Transparent gutter, in sheet pixels, around every repacked sprite.
///
/// Two pixels, not MapLibre's one: icons draw with mipmapped filtering,
/// and the first mip level averages 2x2 texels.
const spriteGutter = 2;

/// Packed sheets taller than this keep their original layout; 4096 is
/// a texture size every GPU this package runs on accepts.
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
    final x0 = math.max(0, sprite.x.floor());
    final y0 = math.max(0, sprite.y.floor());
    final x1 = math.min(sheet.width, (sprite.x + sprite.width).ceil());
    final y1 = math.min(sheet.height, (sprite.y + sprite.height).ceil());
    if (x1 <= x0 || y1 <= y0) return;
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
  if (height > _maxSheetSide) return atlas;

  // Premultiplied in, premultiplied out (`PixelFormat.rgba8888`), so the
  // copy is byte-exact.
  final data = await sheet.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (data == null) return atlas;
  final src = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  final dst = Uint8List(width * height * 4);
  for (final cell in order) {
    final rowBytes = cell.w * 4;
    for (var row = 0; row < cell.h; row++) {
      final from = ((cell.y0 + row) * sheet.width + cell.x0) * 4;
      final to = ((cell.dy + row) * width + cell.dx) * 4;
      dst.setRange(to, to + rowBytes, src, from);
    }
  }
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
      dst, width, height, ui.PixelFormat.rgba8888, completer.complete);
  final image = await completer.future;

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

class _Cell {
  _Cell(this.x0, this.y0, this.w, this.h);

  /// Source rectangle, in whole sheet pixels.
  final int x0, y0, w, h;

  /// Where the source rectangle lands in the packed sheet.
  int dx = 0, dy = 0;
}
