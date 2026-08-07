import 'dart:ui';

import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_vector_tiles/src/core/tile_key.dart';
import 'package:flutter_map_vector_tiles/src/grid/grid_layout.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

MapCamera camera({
  LatLng center = const LatLng(48.137, 11.575), // Munich
  double zoom = 12,
  double rotation = 0,
  Size size = const Size(400, 800),
}) =>
    MapCamera(
      crs: const Epsg3857(),
      center: center,
      zoom: zoom,
      rotation: rotation,
      nonRotatedSize: size,
    );

void main() {
  test('display zoom is the floor of camera zoom', () {
    expect(GridLayout.forCamera(camera(zoom: 12.0)).displayZoom, 12);
    expect(GridLayout.forCamera(camera(zoom: 12.9)).displayZoom, 12);
  });

  test('covers the viewport around the centre tile', () {
    final layout = GridLayout.forCamera(camera());
    // Munich at z12: tile x≈2179, y≈1421.
    expect(layout.minX, lessThanOrEqualTo(2179));
    expect(layout.maxX, greaterThanOrEqualTo(2179));
    expect(layout.minY, lessThanOrEqualTo(1421));
    expect(layout.maxY, greaterThanOrEqualTo(1421));
    expect(layout.contains(const TileKey(12, 2179, 1421)), true);
    expect(layout.contains(const TileKey(11, 2179, 1421)), false);
  });

  test('viewport tile count is bounded', () {
    final layout = GridLayout.forCamera(camera(), buffer: 1);
    final cols = layout.maxX - layout.minX + 1;
    final rows = layout.maxY - layout.minY + 1;
    // 400x800 at 256px tiles → ≈2-4 cols, 4-6 rows (+buffer).
    expect(cols, inInclusiveRange(2, 6));
    expect(rows, inInclusiveRange(4, 8));
  });

  test('rotation expands the range', () {
    final straight = GridLayout.forCamera(camera());
    final rotated = GridLayout.forCamera(camera(rotation: 45));
    final straightCount = (straight.maxX - straight.minX + 1) *
        (straight.maxY - straight.minY + 1);
    final rotatedCount = (rotated.maxX - rotated.minX + 1) *
        (rotated.maxY - rotated.minY + 1);
    expect(rotatedCount, greaterThanOrEqualTo(straightCount));
  });

  test('y is clamped to the world, x is not (wrapping)', () {
    final layout = GridLayout.forCamera(
        camera(center: const LatLng(84, -179.9), zoom: 2));
    expect(layout.minY, greaterThanOrEqualTo(0));
    // Near the antimeridian the x range may extend below zero.
    expect(layout.minX, lessThan(4));
  });

  test('keysByDistance starts near the centre', () {
    final layout = GridLayout.forCamera(camera(), buffer: 1);
    final keys = layout.keysByDistance();
    final first = keys.first;
    final cx = (layout.minX + layout.maxX) / 2;
    final cy = (layout.minY + layout.maxY) / 2;
    for (final key in keys.skip(1)) {
      final dFirst = (first.x - cx) * (first.x - cx) +
          (first.y - cy) * (first.y - cy);
      final d =
          (key.x - cx) * (key.x - cx) + (key.y - cy) * (key.y - cy);
      expect(dFirst, lessThanOrEqualTo(d));
    }
  });

  test('displayTileRect scales with fractional zoom', () {
    final rect = displayTileRect(const TileKey(12, 2179, 1421), 12.0);
    expect(rect.width, 256);
    final rectZoomed = displayTileRect(const TileKey(12, 2179, 1421), 13.0);
    expect(rectZoomed.width, 512);
  });
}
