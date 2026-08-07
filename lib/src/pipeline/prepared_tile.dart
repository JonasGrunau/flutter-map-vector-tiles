import 'dart:typed_data';

import '../core/tile_key.dart';

/// A decoded, trimmed vector tile ready for rendering.
///
/// Produced in a background isolate and transferred to the UI isolate.
/// Everything here is plain data (typed lists, strings, numbers) so the
/// isolate copy is cheap; `ui.Path` objects are built lazily at
/// rasterization time.
///
/// A `PreparedTile` is independent of zoom: theme-layer filters and paint
/// expressions are evaluated per display tile when rasterizing, so one
/// prepared tile serves every zoom level it is displayed at.
class PreparedTile {
  final TileKey key;

  /// Features grouped by MVT source-layer name. Only source-layers
  /// referenced by the theme are present, and feature properties are
  /// trimmed to the union of properties the theme reads.
  final Map<String, PreparedSourceLayer> layers;

  /// Approximate retained size, for LRU cost accounting.
  final int byteSize;

  const PreparedTile({
    required this.key,
    required this.layers,
    required this.byteSize,
  });

  static const empty =
      PreparedTile(key: TileKey(0, 0, 0), layers: {}, byteSize: 64);
}

class PreparedSourceLayer {
  /// Tile-space size; geometry coordinates are in `0..extent`.
  final int extent;
  final List<PreparedFeature> features;

  const PreparedSourceLayer({required this.extent, required this.features});
}

/// Geometry type in `$type` terms.
enum PreparedGeomType { point, line, polygon }

class PreparedFeature {
  final Object? id;
  final PreparedGeomType type;

  /// Interleaved x,y runs in tile-extent units. Points: single run of
  /// pairs; lines: one run per polyline; polygons: one run per ring with
  /// MVT winding (exterior CW y-down).
  final List<Float32List> parts;

  /// Trimmed properties (only keys the theme references); empty map when
  /// the feature has none of the referenced keys.
  final Map<String, Object?> properties;

  const PreparedFeature({
    required this.id,
    required this.type,
    required this.parts,
    required this.properties,
  });

  String get geometryType => switch (type) {
        PreparedGeomType.point => 'Point',
        PreparedGeomType.line => 'LineString',
        PreparedGeomType.polygon => 'Polygon',
      };
}
