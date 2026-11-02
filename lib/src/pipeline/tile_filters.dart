import 'dart:convert';
import 'dart:typed_data';

import '../style/expression.dart';
import '../style/expression_parser.dart';
import '../style/theme.dart';

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
        final lo = z <= minimumZoom ? double.negativeInfinity : z.toDouble();
        final hi = z >= maximumZoom ? double.infinity : z + 1.0;
        final ids = <String, Set<int>>{};
        for (final layer in _layers) {
          if (layer.minzoom < hi && layer.maxzoom > lo) {
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
