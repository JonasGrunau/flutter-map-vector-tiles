import 'dart:typed_data';

/// Geometry type of an MVT feature, per the MVT 2.1 specification.
enum MvtGeomType { unknown, point, lineString, polygon }

/// A decoded vector tile: a list of named layers.
class MvtTile {
  final List<MvtLayer> layers;

  const MvtTile(this.layers);

  MvtLayer? layer(String name) {
    for (final l in layers) {
      if (l.name == name) return l;
    }
    return null;
  }
}

/// A decoded MVT layer.
class MvtLayer {
  final String name;

  /// Geometry coordinate space is `0..extent` (values may slightly exceed
  /// the range for buffered geometries).
  final int extent;
  final List<String> keys;
  final List<Object?> values;
  final List<MvtFeature> features;

  const MvtLayer({
    required this.name,
    required this.extent,
    required this.keys,
    required this.values,
    required this.features,
  });
}

/// A decoded MVT feature.
///
/// Geometry is decoded into [parts]: a list of coordinate runs, each a
/// `Float32List` of interleaved x,y pairs in tile-extent units.
/// * point features: a single part with one x,y pair per point;
/// * line features: one part per polyline;
/// * polygon features: one part per ring — exterior rings are clockwise
///   (positive shoelace area in the y-down tile space), interior rings
///   counter-clockwise. Rings are implicitly closed (the closing vertex
///   is not repeated).
class MvtFeature {
  final int id;
  final MvtGeomType type;

  /// Tag indices into the parent layer's [MvtLayer.keys]/[MvtLayer.values]:
  /// even positions are key indices, odd positions value indices.
  final Uint32List tags;
  final List<Float32List> parts;

  /// Ring areas (shoelace, y-down: positive = exterior) for polygon
  /// features, aligned with [parts]; empty for other geometry types.
  final Float64List ringAreas;

  /// Geometry bounds in tile-extent units over all retained [parts] —
  /// computed during decode, where the vertices are already in cache.
  final double minX, minY, maxX, maxY;

  const MvtFeature({
    required this.id,
    required this.type,
    required this.tags,
    required this.parts,
    required this.ringAreas,
    required this.minX,
    required this.minY,
    required this.maxX,
    required this.maxY,
  });

  /// Materializes this feature's properties using the parent layer's
  /// key/value tables. With [keep], only those keys are inserted —
  /// filtering during construction instead of building the full map and
  /// deleting most of it (OSM layers carry 10-30 properties per feature
  /// while a theme typically reads 2-5).
  Map<String, Object?> decodeProperties(MvtLayer layer, {Set<String>? keep}) {
    final map = <String, Object?>{};
    for (var i = 0; i + 1 < tags.length; i += 2) {
      final k = tags[i];
      final v = tags[i + 1];
      if (k < layer.keys.length && v < layer.values.length) {
        final key = layer.keys[k];
        if (keep != null && !keep.contains(key)) continue;
        map[key] = layer.values[v];
      }
    }
    return map;
  }
}
