import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_map/flutter_map.dart';

import '../core/tile_key.dart';

/// Visible display-tile computation for a camera.
///
/// Display tiles are 256 logical px and live at `floor(camera.zoom)`,
/// like flutter_map's raster `TileLayer`. Keys are *unwrapped* — x may
/// be outside `0..2^z` when the world repeats; wrap at fetch time.
class GridLayout {
  final int displayZoom;

  /// Inclusive tile index bounds.
  final int minX, maxX, minY, maxY;

  const GridLayout({
    required this.displayZoom,
    required this.minX,
    required this.maxX,
    required this.minY,
    required this.maxY,
  });

  factory GridLayout.forCamera(MapCamera camera, {int buffer = 0}) {
    final displayZoom =
        camera.zoom.floor().clamp(0, 30);
    final scale = camera.getZoomScale(camera.zoom, displayZoom.toDouble());
    final pixelCenter =
        camera.projectAtZoom(camera.center, displayZoom.toDouble());
    final halfWidth = camera.size.width / (scale * 2);
    final halfHeight = camera.size.height / (scale * 2);
    const tileSize = 256.0;

    final n = 1 << displayZoom;
    return GridLayout(
      displayZoom: displayZoom,
      minX: ((pixelCenter.dx - halfWidth) / tileSize).floor() - buffer,
      maxX: ((pixelCenter.dx + halfWidth) / tileSize).ceil() - 1 + buffer,
      minY: math.max(
          0, ((pixelCenter.dy - halfHeight) / tileSize).floor() - buffer),
      maxY: math.min(n - 1,
          ((pixelCenter.dy + halfHeight) / tileSize).ceil() - 1 + buffer),
    );
  }

  bool contains(TileKey key) =>
      key.z == displayZoom &&
      key.x >= minX &&
      key.x <= maxX &&
      key.y >= minY &&
      key.y <= maxY;

  /// Keys ordered by distance from the range centre, so the middle of
  /// the viewport loads first.
  List<TileKey> keysByDistance() {
    final keys = <TileKey>[];
    for (var y = minY; y <= maxY; y++) {
      for (var x = minX; x <= maxX; x++) {
        keys.add(TileKey(displayZoom, x, y));
      }
    }
    final cx = (minX + maxX) / 2;
    final cy = (minY + maxY) / 2;
    keys.sort((a, b) {
      final da = (a.x - cx) * (a.x - cx) + (a.y - cy) * (a.y - cy);
      final db = (b.x - cx) * (b.x - cx) + (b.y - cy) * (b.y - cy);
      return da.compareTo(db);
    });
    return keys;
  }

  /// Distance of [key] from the viewport centre, as a load priority.
  int priorityOf(TileKey key) {
    final cx = (minX + maxX) / 2;
    final cy = (minY + maxY) / 2;
    return (((key.x - cx) * (key.x - cx) + (key.y - cy) * (key.y - cy)) * 4)
        .round();
  }
}

/// The world-pixel rectangle of a display tile at the camera zoom.
Rect displayTileRect(TileKey key, double cameraZoom) {
  final scaledSize = 256.0 * math.pow(2.0, cameraZoom - key.z);
  return Rect.fromLTWH(
      key.x * scaledSize, key.y * scaledSize, scaledSize, scaledSize);
}
