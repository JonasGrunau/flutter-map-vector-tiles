import 'dart:ui';

import 'package:meta/meta.dart';

import 'render/hit_test.dart';
import 'style/feature_state.dart';
import 'vector_tile_layer.dart';

/// Queries what a [VectorTileLayer] draws and sets the feature state its
/// style reads — MapLibre's `queryRenderedFeatures` and
/// `setFeatureState`, for one layer.
///
/// ```dart
/// final controller = VectorTileLayerController();
///
/// FlutterMap(
///   options: MapOptions(
///     onTap: (tap, _) {
///       final hits = controller.queryRenderedFeatures(tap.relative!);
///       if (hits.isEmpty || hits.first.id == null) return;
///       final hit = hits.first;
///       controller.setFeatureState(
///         source: hit.source,
///         sourceLayer: hit.sourceLayer,
///         id: hit.id!,
///         state: {'selected': true},
///       );
///     },
///   ),
///   children: [
///     VectorTileLayer(controller: controller, theme: …, tileProviders: …),
///   ],
/// )
/// ```
///
/// A controller drives one layer at a time: the one that mounted last,
/// which is also how a layer remounted under a new key takes it over
/// (Flutter mounts the new layer before it lets go of the old one).
/// Feature state lives in the controller, not the layer, so it survives
/// the layer being rebuilt or remounted with the same controller;
/// queries need the layer mounted and return nothing before that.
///
/// Feature state only changes what is drawn where the style reads it,
/// through `["feature-state", key]` in a paint property — for example
/// `"fill-color": ["case", ["boolean", ["feature-state", "selected"],
/// false], "#e53935", "#d6d0c4"]`. Changing it re-renders just the
/// display tiles that draw the feature from such a layer; labels
/// re-evaluate on the next frame.
class VectorTileLayerController {
  final _states = FeatureStates();
  FeatureQueryHost? _host;

  /// Whether a mounted [VectorTileLayer] uses this controller.
  bool get isAttached => _host != null;

  /// The features drawn at [point], topmost first.
  ///
  /// [point] is in the map widget's logical pixels — the
  /// `TapPosition.relative` that `MapOptions.onTap` hands over. Only
  /// layers in [layerIds] are searched when it is given.
  ///
  /// Labels and icons come first, as the last frame placed them (symbol
  /// layers draw above all geometry here); then features of fill, line
  /// and circle layers, topmost style layer first and, within a layer,
  /// the feature drawn last first. A geometry feature is hit where it is
  /// drawn: inside a polygon, within half a line's width (casing
  /// included) of a line, within a circle's radius plus stroke — paint
  /// opacity aside, so a transparent layer still answers, the usual way
  /// to give a thin line a larger tap target. Background and raster
  /// layers have no features.
  ///
  /// A feature with an id is returned once per style layer even when it
  /// is drawn across several tiles; one without may come back once per
  /// data tile it is in. Properties are those the decoded tiles kept —
  /// only what the style reads, unless the layer sets
  /// `VectorTileLayer.retainAllProperties`.
  List<RenderedFeature> queryRenderedFeatures(Offset point,
          {Iterable<String>? layerIds}) =>
      _host?.queryRenderedFeatures(HitArea([point]), layerIds?.toSet()) ??
      const [];

  /// [queryRenderedFeatures] for every feature drawn in [rect], in the
  /// map widget's logical pixels.
  List<RenderedFeature> queryRenderedFeaturesInRect(Rect rect,
          {Iterable<String>? layerIds}) =>
      _host?.queryRenderedFeatures(
          HitArea(
              [rect.topLeft, rect.topRight, rect.bottomRight, rect.bottomLeft]),
          layerIds?.toSet()) ??
      const [];

  /// Merges [state] into the state of feature [id] in [sourceLayer] of
  /// [source]: keys [state] does not name keep their values, as in
  /// MapLibre. Ids match as MapLibre matches them, so the number `42`
  /// and the string `'42'` name the same feature. Setting values the
  /// feature already has does nothing.
  void setFeatureState({
    required String source,
    required String sourceLayer,
    required Object id,
    required Map<String, Object?> state,
  }) {
    if (_states.set(source, sourceLayer, id, state)) {
      _host?.featureStateChanged(
          source, sourceLayer, {FeatureStates.normalizeId(id)});
    }
  }

  /// Removes state: one [key] of feature [id], all of [id]'s state when
  /// [key] is null, or the state of every feature in [sourceLayer] when
  /// [id] is null too. Throws an [ArgumentError] for a [key] without an
  /// [id].
  void removeFeatureState({
    required String source,
    required String sourceLayer,
    Object? id,
    String? key,
  }) {
    if (key != null && id == null) {
      throw ArgumentError.value(
          key, 'key', 'removing one key needs the feature id');
    }
    final changed = _states.remove(source, sourceLayer, id: id, key: key);
    if (changed.isNotEmpty) {
      _host?.featureStateChanged(source, sourceLayer, changed);
    }
  }

  /// The state of feature [id] — empty when it has none.
  Map<String, Object?> getFeatureState({
    required String source,
    required String sourceLayer,
    required Object id,
  }) =>
      Map.unmodifiable(_states.lookup(source, sourceLayer, id) ?? const {});

  /// The state this controller holds, which the layer draws with.
  @internal
  FeatureStates get featureStates => _states;

  /// Connects the layer [host]; called by the layer as it mounts. Takes
  /// the controller over from a layer still attached: a layer remounted
  /// under a new key mounts before the old one is deactivated.
  @internal
  void attach(FeatureQueryHost host) => _host = host;

  /// Disconnects [host], if it is the attached one.
  @internal
  void detach(FeatureQueryHost host) {
    if (identical(_host, host)) _host = null;
  }
}

/// What [VectorTileLayerController] needs from the layer it drives.
@internal
abstract interface class FeatureQueryHost {
  /// The features drawn in [area] (map widget pixels), topmost first.
  List<RenderedFeature> queryRenderedFeatures(
      HitArea area, Set<String>? layerIds);

  /// The state of the features [ids] (normalized) in [sourceLayer] of
  /// [source] changed.
  void featureStateChanged(String source, String sourceLayer, Set<Object> ids);
}

/// A feature [VectorTileLayerController.queryRenderedFeatures] found.
///
/// Carries what identifies it for [VectorTileLayerController.setFeatureState]
/// — [source], [sourceLayer], [id] — and which style layer drew it,
/// which MapLibre's results name too.
@immutable
class RenderedFeature {
  /// The id of the style layer that drew the feature.
  final String layerId;

  /// The style source the feature came from.
  final String source;

  /// The source layer the feature came from.
  final String sourceLayer;

  /// The feature id — the tile's own, or the property the source's
  /// `promoteId` names — or null when it has none.
  final Object? id;

  /// The feature's properties, as the decoded tile kept them.
  final Map<String, Object?> properties;

  /// `Point`, `LineString` or `Polygon`.
  final String geometryType;

  /// The feature's state when it was queried.
  final Map<String, Object?> state;

  const RenderedFeature({
    required this.layerId,
    required this.source,
    required this.sourceLayer,
    required this.id,
    required this.properties,
    required this.geometryType,
    this.state = const {},
  });

  @override
  String toString() => 'RenderedFeature($layerId, $source/$sourceLayer, '
      'id: $id, $geometryType, $properties'
      '${state.isEmpty ? '' : ', state: $state'})';
}
