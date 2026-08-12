import 'package:flutter_map/flutter_map.dart' show LatLngBounds;
import 'package:latlong2/latlong.dart';

/// Thrown when an archive cannot be opened or is not an MBTiles database.
class MbTilesException implements Exception {
  final String message;
  const MbTilesException(this.message);

  @override
  String toString() => 'MbTilesException: $message';
}

/// The `metadata` table of an MBTiles archive, as key/value strings plus
/// the entries the spec gives meaning to.
///
/// Parsing is deliberately tolerant, like the style engine's: a malformed
/// `bounds` or a non-numeric `minzoom` degrades to null rather than
/// failing the archive. Anything not modelled here is still readable
/// through [values].
class MbTilesMetadata {
  /// Every row of the table, verbatim.
  final Map<String, String> values;

  /// The archive's plain-language name (`''` when it declares none).
  final String name;

  /// `pbf` for vector archives; `png`, `jpg` or `webp` for raster ones.
  /// Lowercased, `''` when absent.
  ///
  /// Advisory only — nothing in the pipeline branches on it, since a
  /// provider is vector or raster by where it is wired up, not by what it
  /// says about itself.
  final String format;

  /// How tile blobs are compressed (`gzip`, `none`, …), when declared.
  ///
  /// Not part of the original spec and frequently absent, which is why
  /// nothing depends on it: the worker isolate sniffs the gzip magic
  /// bytes instead.
  final String? compression;

  /// Attribution HTML the archive asks to have displayed.
  final String? attribution;

  final String? description;

  /// Zoom levels the archive declares tiles for. Null when it declares
  /// none, in which case the provider derives them from the tile table.
  final int? minZoom;
  final int? maxZoom;

  /// The region covered, in WGS84 degrees.
  final LatLngBounds? bounds;

  /// The archive's suggested initial camera.
  final LatLng? center;
  final double? centerZoom;

  const MbTilesMetadata({
    required this.values,
    this.name = '',
    this.format = '',
    this.compression,
    this.attribution,
    this.description,
    this.minZoom,
    this.maxZoom,
    this.bounds,
    this.center,
    this.centerZoom,
  });

  /// True when the archive holds vector tiles (`pbf`, or `mvt` as written
  /// by some tools).
  bool get isVector => format == 'pbf' || format == 'mvt';

  factory MbTilesMetadata.parse(Map<String, String> values) {
    String? text(String key) {
      final value = values[key]?.trim();
      return value == null || value.isEmpty ? null : value;
    }

    final centerParts = _numbers(values['center'], 2);
    return MbTilesMetadata(
      values: Map.unmodifiable(values),
      name: text('name') ?? '',
      format: text('format')?.toLowerCase() ?? '',
      compression: text('compression')?.toLowerCase(),
      attribution: text('attribution'),
      description: text('description'),
      minZoom: int.tryParse(values['minzoom']?.trim() ?? ''),
      maxZoom: int.tryParse(values['maxzoom']?.trim() ?? ''),
      bounds: _bounds(values['bounds']),
      center:
          centerParts == null ? null : LatLng(centerParts[1], centerParts[0]),
      centerZoom:
          centerParts != null && centerParts.length > 2 ? centerParts[2] : null,
    );
  }

  /// `left,bottom,right,top` in WGS84 degrees, per the spec. Out-of-range
  /// or non-numeric values yield null rather than a bounds object that
  /// would throw when used.
  static LatLngBounds? _bounds(String? raw) {
    final parts = _numbers(raw, 4);
    if (parts == null || parts.length < 4) return null;
    final [west, south, east, north] = parts.take(4).toList();
    if (south > north || south < -90 || north > 90) return null;
    if (west < -180 || east > 180) return null;
    return LatLngBounds(LatLng(south, west), LatLng(north, east));
  }

  /// Splits a comma-separated list of numbers, returning null unless at
  /// least [minimum] of them parsed.
  static List<double>? _numbers(String? raw, int minimum) {
    if (raw == null) return null;
    final parts = <double>[];
    for (final part in raw.split(',')) {
      final value = double.tryParse(part.trim());
      if (value == null || !value.isFinite) return null;
      parts.add(value);
    }
    return parts.length < minimum ? null : parts;
  }
}
