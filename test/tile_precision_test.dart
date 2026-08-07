import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_map_vector_tiles/src/core/tile_key.dart';
import 'package:flutter_map_vector_tiles/src/grid/grid_layout.dart';
import 'package:flutter_test/flutter_test.dart';

/// Rounds a value to float32 — the precision a `Canvas` transform keeps
/// internally, whatever doubles Dart hands it.
double _f32(double v) => (Float32List(1)..[0] = v)[0];

/// The camera centre in world pixels at [zoom]. Longitude only, which
/// is enough to reproduce the magnitudes involved.
double _worldCenterX(double lon, double zoom) =>
    (lon + 180.0) / 360.0 * 256.0 * math.pow(2.0, zoom);

/// Worst-case error, over a realistic viewport of tiles around the
/// camera, between where a tile edge actually belongs and where each
/// strategy puts it.
///
/// Returns `(absolute:, relative:)` — `absolute` is translating the
/// canvas by the world centre and drawing at world coordinates (every
/// term rounded to float32); `relative` is subtracting the world centre
/// in Dart first, so only a small number reaches the canvas.
({double absolute, double relative}) _worstError({
  required double cameraZoom,
  required int tileZoom,
}) {
  const lon = 11.7375; // the area in the bug reports
  final worldCenterX = _worldCenterX(lon, cameraZoom);
  final tileSpan = displayTileRect(TileKey(tileZoom, 0, 0), cameraZoom).width;
  final centreTile = (worldCenterX / tileSpan).floor();

  var absolute = 0.0;
  var relative = 0.0;
  for (var dx = -3; dx <= 3; dx++) {
    final left =
        displayTileRect(TileKey(tileZoom, centreTile + dx, 0), cameraZoom).left;
    final exact = left - worldCenterX; // what the label pass computes
    absolute = math.max(
        absolute, (_f32(_f32(left) + _f32(-worldCenterX)) - exact).abs());
    relative = math.max(relative, (_f32(left - worldCenterX) - exact).abs());
  }
  return (absolute: absolute, relative: relative);
}

void main() {
  // Labels are projected in Dart doubles; tile rasters go through the
  // canvas transform in float32. Handing the canvas absolute world
  // coordinates drifts the imagery away from its own labels, and the
  // drift doubles with every zoom level — which is why this is only
  // visible when heavily zoomed in.
  group('float32 resolution of world-pixel coordinates', () {
    test('error is invisible at low zoom and grows past a pixel deep in', () {
      expect(_worstError(cameraZoom: 14, tileZoom: 14).absolute, lessThan(0.05),
          reason: 'nothing perceptible at zoom 14');
      expect(
          _worstError(cameraZoom: 18, tileZoom: 18).absolute, greaterThan(0.5),
          reason: 'half a pixel of drift by zoom 18');
      expect(_worstError(cameraZoom: 20, tileZoom: 20).absolute, greaterThan(2),
          reason: 'multiple pixels by zoom 20');
    });

    test('panning: relative coordinates track the label pass exactly', () {
      // Integer zoom, so tile edges are exact multiples of 256 and all
      // the error comes from the camera translation itself.
      final z18 = _worstError(cameraZoom: 18, tileZoom: 18);
      expect(z18.absolute, greaterThan(0.5),
          reason: 'rasters sit half a pixel off the labels while dragging');
      expect(z18.relative, lessThan(0.001));

      final z19 = _worstError(cameraZoom: 19, tileZoom: 19);
      expect(z19.absolute, greaterThan(1));
      expect(z19.relative, lessThan(0.001));
    });

    test('mid-pinch: tile edges hold still in relative coordinates', () {
      // Fractional zoom is the shaking case — tile edges are no longer
      // multiples of 256, so each one rounds on its own.
      final pinch = _worstError(cameraZoom: 18.63, tileZoom: 19);
      expect(pinch.absolute, greaterThan(2),
          reason: 'edges jump by pixels as the zoom animates');
      expect(pinch.relative, lessThan(0.001),
          reason: 'relative coordinates stay put through the pinch');
    });

    test('adjacent tiles share an edge exactly in relative coordinates', () {
      // Seams must not open or close during a pinch.
      const cameraZoom = 18.63;
      final worldCenterX = _worldCenterX(11.7375, cameraZoom);
      final tileSpan =
          displayTileRect(const TileKey(19, 0, 0), cameraZoom).width;
      final centreTile = (worldCenterX / tileSpan).floor();

      final left = displayTileRect(TileKey(19, centreTile, 0), cameraZoom);
      final right = displayTileRect(TileKey(19, centreTile + 1, 0), cameraZoom);

      expect(_f32(left.right - worldCenterX), _f32(right.left - worldCenterX));
    });
  });
}
