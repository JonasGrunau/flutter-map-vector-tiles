import 'dart:typed_data';

import '../core/tile_key.dart';
import '../mvt/mvt_decoder.dart';
import '../mvt/mvt_tile.dart';
import '../style/expression.dart';
import 'prepare_gunzip_web.dart' if (dart.library.io) 'prepare_gunzip_io.dart';
import 'prepared_tile.dart';
import 'tile_filters.dart';

/// Input for [prepareTileSync]; must remain isolate-transferable.
class PrepareInput {
  final int z;
  final int x;
  final int y;
  final Uint8List bytes;

  /// Per source-layer name: the property keys to retain, or null to
  /// retain all. Source-layers absent from this map are dropped entirely.
  final Map<String, Set<String>?> layerProperties;

  /// Per source-layer name: the property whose value replaces the
  /// feature id (the source's `promoteId`). The property must also be
  /// kept by [layerProperties].
  final Map<String, String> promoteIds;

  /// Per source-layer name: the `FilterIds` ids of the zoom-free layer
  /// filters to resolve (see [TileFilterPlan]), or null for none. Only
  /// an executor that hands [prepareTileSync] compiled filters resolves
  /// them; the rest leave every filter to the UI isolate.
  final Map<String, Int32List>? filterIds;

  const PrepareInput({
    required this.z,
    required this.x,
    required this.y,
    required this.bytes,
    required this.layerProperties,
    this.promoteIds = const {},
    this.filterIds,
  });
}

/// Decodes MVT bytes and trims them to what the theme needs. Pure
/// function — runs on a worker isolate (or directly on web). Bytes may
/// arrive gzip-compressed (PMTiles blobs on native platforms, servers
/// that compress without declaring it): inflation happens here, off the
/// UI isolate.
///
/// With [filters] — the worker's compiled filters — it also resolves the
/// layer filters [PrepareInput.filterIds] asks for into
/// [PreparedSourceLayer.matches], which takes that scan off the UI
/// isolate's first use of the tile.
PreparedTile prepareTileSync(PrepareInput input, {CompiledFilters? filters}) {
  final mvt = decodeMvt(maybeGunzip(input.bytes));
  final layers = <String, PreparedSourceLayer>{};
  var byteSize = 128;

  for (final layer in mvt.layers) {
    if (!input.layerProperties.containsKey(layer.name)) continue;
    final keepKeys = input.layerProperties[layer.name];
    final promoteId = input.promoteIds[layer.name];

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
        id: promoteId != null
            ? _promotedId(properties[promoteId])
            : (feature.id == 0 ? null : feature.id),
        type: type,
        parts: feature.parts,
        properties: properties,
        minX: feature.minX,
        minY: feature.minY,
        maxX: feature.maxX,
        maxY: feature.maxY,
      ));
    }
    if (features.isEmpty) continue;
    final filterIds = input.filterIds?[layer.name];
    final matches = filters == null || filterIds == null
        ? const <int, Int32List?>{}
        : _resolveFilters(filterIds, filters, features);
    for (final indices in matches.values) {
      byteSize += 16 + (indices?.lengthInBytes ?? 0);
    }
    layers[layer.name] = PreparedSourceLayer(
      extent: layer.extent,
      features: features,
      matches: matches,
    );
  }

  return PreparedTile(
    key: TileKey(input.z, input.x, input.y),
    layers: layers,
    byteSize: byteSize,
  );
}

/// A `promoteId` property's value as a feature id: numbers and strings
/// as they are, booleans as 1 or 0 (as MapLibre does), anything else —
/// or an absent property — as no id.
Object? _promotedId(Object? value) => switch (value) {
      num() || String() => value,
      bool() => value ? 1 : 0,
      _ => null,
    };

/// The features each of [ids] selects, as `PreparedSourceLayer.matches`
/// holds them. Evaluates exactly what `MatchedFeatures` would on the UI
/// isolate, so the two agree.
Map<int, Int32List?> _resolveFilters(
  Int32List ids,
  CompiledFilters filters,
  List<PreparedFeature> features,
) {
  final matches = <int, Int32List?>{};
  // One context per feature, shared by every filter: they are
  // immutable, and the zoom is never read — the filters are zoom-free.
  final contexts = [
    for (final feature in features)
      EvalContext(
        zoom: 0,
        properties: feature.properties,
        geometryType: feature.geometryType,
        featureId: feature.id,
      ),
  ];
  final scratch = Int32List(features.length);
  for (final id in ids) {
    final filter = filters[id];
    if (filter == null) continue;
    var count = 0;
    for (var i = 0; i < contexts.length; i++) {
      if (toBoolean(filter(contexts[i]))) scratch[count++] = i;
    }
    // Every feature: null, so the UI shares the feature list itself.
    matches[id] = count == features.length ? null : scratch.sublist(0, count);
  }
  return matches;
}
