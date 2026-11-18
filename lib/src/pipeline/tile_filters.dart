import 'dart:convert';
import 'dart:typed_data';

import '../style/expression.dart';
import '../style/expression_parser.dart';
import '../style/theme.dart';

/// Whether a layer drawn from style zoom [minzoom] up to [maxzoom]
/// draws a data tile at [z] of a source spanning [minimumZoom] to
/// [maximumZoom]: the tile is drawn at style zoom z — at and past z when
/// it is the source's deepest level, at and before it when it is the
/// shallowest.
bool drawsDataZoom(double minzoom, double maxzoom, int z,
    {required int minimumZoom, required int maximumZoom}) {
  final lo = z <= minimumZoom ? double.negativeInfinity : z.toDouble();
  final hi = z >= maximumZoom ? double.infinity : z + 1.0;
  return minzoom < hi && maxzoom > lo;
}

/// Which source layers of one source a data tile gets building meshes
/// for (`PrepareInput.extrusionLayers`), by its zoom: those a 3D layer
/// draws at that zoom, in the band [drawsDataZoom] gives. A tile seen at
/// other zooms only as a stand-in gets none — MapLibre builds no 3D
/// bucket for a layer its tile's zoom hides either — so browsing below
/// the buildings' zooms cuts no meshes, and a tile drawn from such an
/// ancestor while its own data loads shows its buildings when it does.
class TileMeshPlan {
  final int minimumZoom;
  final int maximumZoom;

  final List<({String sourceLayer, double minzoom, double maxzoom})> _layers;

  final _byZoom = <int, Set<String>>{};

  /// The plan for [layers], one source's layers drawn in 3D.
  TileMeshPlan(
    Iterable<ThemeLayer> layers, {
    required this.minimumZoom,
    required this.maximumZoom,
  }) : _layers = [
          for (final layer in layers)
            if (layer.sourceLayer case final sourceLayer?)
              (
                sourceLayer: sourceLayer,
                minzoom: layer.minzoom,
                maxzoom: layer.maxzoom,
              ),
        ];

  /// The source layers a data tile at [z] builds meshes for.
  Set<String> at(int z) => _byZoom.putIfAbsent(
      z,
      () => {
            for (final layer in _layers)
              if (drawsDataZoom(layer.minzoom, layer.maxzoom, z,
                  minimumZoom: minimumZoom, maximumZoom: maximumZoom))
                layer.sourceLayer,
          });

  /// [sourceLayer]'s part of the plan, for a decoded-tile cache's
  /// signature: the zoom ranges of the layers drawing it in 3D; null
  /// when it gets no mesh at any zoom.
  String? signatureOf(String sourceLayer) {
    final ranges = [
      for (final layer in _layers)
        if (layer.sourceLayer == sourceLayer)
          '${layer.minzoom}-${layer.maxzoom}',
    ]..sort();
    return ranges.isEmpty ? null : ranges.join(',');
  }
}

/// Which zoom-free layer filters a data tile of one source has resolved
/// on the worker, by source layer.
///
/// A data tile at zoom z is drawn at style zoom z — at and past z when
/// it is the source's deepest level, at and before it when it is the
/// shallowest — so a filter is resolved for it only when some layer
/// using it can draw in that band. A layer outside it (one that only
/// sees the tile as a stand-in ancestor or descendant) finds no match
/// list and resolves on the UI isolate, as every filter did before.
class TileFilterPlan {
  final int minimumZoom;
  final int maximumZoom;

  /// The layers with a `filterId`, reduced to what the plan reads.
  final List<({String sourceLayer, int id, double minzoom, double maxzoom})>
      _layers;

  final _byZoom = <int, Map<String, Int32List>?>{};

  /// The filters of [layers] (one source's) that have a `filterId`.
  TileFilterPlan(
    Iterable<ThemeLayer> layers, {
    required this.minimumZoom,
    required this.maximumZoom,
  }) : _layers = [
          for (final layer in layers)
            if ((layer.sourceLayer, layer.filterId)
                case (final sourceLayer?, final id?))
              (
                sourceLayer: sourceLayer,
                id: id,
                minzoom: layer.minzoom,
                maxzoom: layer.maxzoom,
              ),
        ];

  /// The filter ids to resolve for a data tile at [z], by source layer;
  /// null when there are none. A filter several layers share is
  /// resolved when any one of them draws in the band.
  Map<String, Int32List>? idsAt(int z) => _byZoom.putIfAbsent(z, () {
        final ids = <String, Set<int>>{};
        for (final layer in _layers) {
          if (drawsDataZoom(layer.minzoom, layer.maxzoom, z,
              minimumZoom: minimumZoom, maximumZoom: maximumZoom)) {
            (ids[layer.sourceLayer] ??= {}).add(layer.id);
          }
        }
        return ids.isEmpty
            ? null
            : {
                for (final MapEntry(:key, :value) in ids.entries)
                  key: Int32List.fromList(value.toList()),
              };
      });
}

/// The worker isolate's compiled filters, by `FilterIds` id.
///
/// Each worker compiles a filter once, from the JSON source the executor
/// sends with the first job that needs it, using the parser the theme
/// reader used — so a match list resolved here equals the one the UI
/// isolate would have resolved.
class CompiledFilters {
  final _filters = <int, Expr>{};

  /// Compiles [sources] (id → JSON source). A source that fails to
  /// decode or compile is left out: its layers resolve on the UI
  /// isolate.
  void addAll(Map<int, String> sources) {
    sources.forEach((id, source) {
      try {
        _filters[id] = ExpressionParser().parseFilter(jsonDecode(source));
      } catch (_) {
        _filters.remove(id);
      }
    });
  }

  Expr? operator [](int id) => _filters[id];
}
