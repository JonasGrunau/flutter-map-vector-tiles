import 'dart:typed_data';

import '../core/tile_key.dart';
import '../mvt/mvt_decoder.dart';
import '../mvt/mvt_tile.dart';
import 'prepare_gunzip_web.dart' if (dart.library.io) 'prepare_gunzip_io.dart';
import 'prepared_tile.dart';

/// Input for [prepareTileSync]; must remain isolate-transferable.
class PrepareInput {
  final int z;
  final int x;
  final int y;
  final Uint8List bytes;

  /// Per source-layer name: the property keys to retain, or null to
  /// retain all. Source-layers absent from this map are dropped entirely.
  final Map<String, Set<String>?> layerProperties;

  const PrepareInput({
    required this.z,
    required this.x,
    required this.y,
    required this.bytes,
    required this.layerProperties,
  });
}

/// Decodes MVT bytes and trims them to what the theme needs. Pure
/// function — runs on a worker isolate (or directly on web). Bytes may
/// arrive gzip-compressed (PMTiles blobs on native platforms, servers
/// that compress without declaring it): inflation happens here, off the
/// UI isolate.
PreparedTile prepareTileSync(PrepareInput input) {
  final mvt = decodeMvt(maybeGunzip(input.bytes));
  final layers = <String, PreparedSourceLayer>{};
  var byteSize = 128;

  for (final layer in mvt.layers) {
    if (!input.layerProperties.containsKey(layer.name)) continue;
    final keepKeys = input.layerProperties[layer.name];

    final features = <PreparedFeature>[];
    for (final feature in layer.features) {
      final type = switch (feature.type) {
        MvtGeomType.point => PreparedGeomType.point,
        MvtGeomType.lineString => PreparedGeomType.line,
        MvtGeomType.polygon => PreparedGeomType.polygon,
        MvtGeomType.unknown => null,
      };
      if (type == null) continue;

      Map<String, Object?> properties;
      if (keepKeys != null && keepKeys.isEmpty) {
        properties = const {};
      } else {
        properties = feature.decodeProperties(layer, keep: keepKeys);
      }

      for (final part in feature.parts) {
        byteSize += part.length * 4 + 16;
      }
      byteSize += properties.length * 48 + 32; // +32: the four bound doubles

      features.add(PreparedFeature(
        id: feature.id == 0 ? null : feature.id,
        type: type,
        parts: feature.parts,
        properties: properties,
        minX: feature.minX,
        minY: feature.minY,
        maxX: feature.maxX,
        maxY: feature.maxY,
      ));
    }
    if (features.isNotEmpty) {
      layers[layer.name] = PreparedSourceLayer(
        extent: layer.extent,
        features: features,
      );
    }
  }

  return PreparedTile(
    key: TileKey(input.z, input.x, input.y),
    layers: layers,
    byteSize: byteSize,
  );
}
