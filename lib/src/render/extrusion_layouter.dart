import 'dart:collection';
import 'dart:typed_data';

import '../core/tile_key.dart';
import '../pipeline/extrusion_mesh.dart';
import '../pipeline/prepared_tile.dart';
import '../style/expression.dart';
import '../style/feature_state.dart';
import '../style/theme.dart';
import 'display_tile_data.dart';
import 'extrusion_shading.dart';
import 'matched_features.dart';

/// One `fill-extrusion` layer's buildings in one data tile, ready for
/// [ExtrusionPainter]: which buildings of the tile's [mesh] the layer
/// draws, how tall, and in what colour.
///
/// Laid out once per data tile, not per display tile — one data tile
/// serves every display tile overzooming it, and every zoom past the
/// source's deepest level, so a z14 tile's buildings are laid out once
/// for z14 through z22 — and shared by identity: two display tiles over
/// the same data tile hand the painter the same instance, which is how
/// it draws each building once.
class ExtrusionLayout {
  final FillThemeLayer layer;

  /// The feature-state version it was laid out under, for a layer that
  /// reads feature state; 0 otherwise.
  final int stateVersion;

  /// The data tile the buildings come from, and its extent.
  final TileKey tile;
  final double extent;
  final ExtrusionMesh mesh;

  /// The source layer [mesh] was built from: its features, which
  /// rendered-feature queries answer with.
  final PreparedSourceLayer source;

  /// Per drawn building — one polygon of [mesh] — its index there.
  final Int32List buildings;

  /// Per drawn building: roof and floor, in metres, `base <= height` —
  /// at [zoom] for a property that reads it.
  final Float32List heights;
  final Float32List bases;

  /// The integer style zoom a layout that reads the zoom was evaluated
  /// at; null for one that reads none, which holds at every zoom.
  final int? zoom;

  /// For a height / base reading both the zoom and the feature, its
  /// values at `zoom + 1`: a frame at style zoom z draws
  /// `heights + (nextHeights - heights) · (z - zoom)`, MapLibre's
  /// two-stop composite evaluation (its interpolation factor taken as
  /// linear). Null when the property reads no zoom.
  final Float32List? nextHeights;
  final Float32List? nextBases;

  /// Per drawn building: its colour class, an index into [classes].
  final Uint16List classOf;

  /// The colour classes, three ints each: the layer colour (ARGB, alpha
  /// kept — the shading premultiplies it), and the vertical-gradient
  /// keys at the walls' foot and top (`ExtrusionShading.gradientKey`).
  /// The painter turns each into a roof colour and a wall colour per
  /// light level.
  final Int32List classes;

  /// Per wall of [mesh], for a wall a drawn neighbour shares
  /// (`ExtrusionMesh.wallTwin`): the altitude its visible part starts
  /// at, the neighbour's roof — at or above the building's own roof
  /// when the neighbour hides it whole. NaN for the rest; null when no
  /// wall of the tile has a drawn neighbour.
  final Float32List? wallFloors;

  /// Per drawn building: its footprint's bounds in extent units,
  /// `minX, minY, maxX, maxY` — copied out of [mesh] so the painter's
  /// cull reads one list in drawing order.
  final Float32List bounds;

  /// The tallest [heights] entry.
  final double maxHeight;

  ExtrusionLayout._({
    required this.layer,
    required this.stateVersion,
    required this.tile,
    required this.extent,
    required this.mesh,
    required this.source,
    required this.buildings,
    required this.heights,
    required this.bases,
    required this.zoom,
    required this.nextHeights,
    required this.nextBases,
    required this.classOf,
    required this.classes,
    required this.wallFloors,
    required this.bounds,
    required this.maxHeight,
  });

  int get length => buildings.length;

  int get byteSize =>
      buildings.lengthInBytes +
      heights.lengthInBytes +
      bases.lengthInBytes +
      (nextHeights?.lengthInBytes ?? 0) +
      (nextBases?.lengthInBytes ?? 0) +
      classOf.lengthInBytes +
      classes.lengthInBytes +
      (wallFloors?.lengthInBytes ?? 0) +
      bounds.lengthInBytes +
      64;

  /// Building [i]'s roof and floor at style zoom [styleZoom].
  double heightAt(int i, double styleZoom) =>
      _at(heights, nextHeights, i, styleZoom);
  double baseAt(int i, double styleZoom) => _at(bases, nextBases, i, styleZoom);

  double _at(Float32List at, Float32List? next, int i, double styleZoom) {
    if (next == null) return at[i];
    final t = (styleZoom - zoom!).clamp(0.0, 1.0);
    return at[i] + (next[i] - at[i]) * t;
  }
}

/// Lays out the `fill-extrusion` layers of a display tile.
abstract final class ExtrusionLayouter {
  /// Per prepared source layer, its layouts by style layer — and, for
  /// a layer that reads the zoom, by integer zoom.
  static final _cache =
      Expando<Map<FillThemeLayer, Map<int?, ExtrusionLayout>>>();

  /// Whether [layer]'s layout differs between integer zooms.
  static bool readsZoom(FillThemeLayer layer) =>
      layer.extrusionHeightReadsZoom ||
      layer.extrusionBaseReadsZoom ||
      layer.extrusionColorReadsZoom ||
      layer.filterReadsZoom ||
      !(layer.extrusionVerticalGradient?.isConstant ?? true);

  /// The layers of [theme] drawn as 3D buildings: every `fill-extrusion`
  /// layer without a pattern.
  static List<FillThemeLayer> layersOf(Theme theme) => [
        for (final layer in theme.layers)
          if (layer is FillThemeLayer &&
              layer.extrusion &&
              layer.pattern == null)
            layer,
      ];

  /// The buildings of every layer in [layers] visible somewhere in the
  /// band [styleZoom, styleZoom + 1), from [data]'s own sources —
  /// descendants only stand in while a zoom-out loads. Null when [data]
  /// holds none of their sources yet.
  static List<ExtrusionLayout>? layout({
    required List<FillThemeLayer> layers,
    required DisplayTileData data,
    required double styleZoom,
  }) {
    if (layers.isEmpty) return const [];
    var any = false;
    final out = <ExtrusionLayout>[];
    for (final layer in layers) {
      final tile = data.sources[layer.source];
      if (tile == null) continue;
      any = true;
      if (!layer.coversZoomBand(styleZoom)) continue;
      final sourceLayer = tile.layers[layer.sourceLayer];
      final mesh = sourceLayer?.mesh;
      if (sourceLayer == null || mesh == null) continue;
      final byLayer = _cache[sourceLayer] ??= HashMap.identity();
      // A layer reading feature state is laid out again under every new
      // state, once for all the display tiles over its data tile.
      final states = layer.readsFeatureState ? data.featureStates : null;
      final version = states?.version ?? 0;
      final zoom = readsZoom(layer) ? styleZoom.floor() : null;
      final byZoom = byLayer[layer] ??= {};
      var laid = byZoom[zoom];
      if (laid == null || laid.stateVersion != version) {
        // Two levels at most: a crossing's.
        if (byZoom.length > 2) byZoom.clear();
        laid = byZoom[zoom] = _layoutLayer(layer, tile.key, sourceLayer, mesh,
            zoom?.toDouble() ?? styleZoom, zoom, states, version);
      }
      if (laid.length > 0) out.add(laid);
    }
    return any ? out : null;
  }

  static ExtrusionLayout _layoutLayer(
    FillThemeLayer layer,
    TileKey tile,
    PreparedSourceLayer sourceLayer,
    ExtrusionMesh mesh,
    double styleZoom,
    int? zoom,
    FeatureStates? featureStates,
    int stateVersion,
  ) {
    final features = sourceLayer.features;
    final states = featureStates?.sourceLayer(layer.source, layer.sourceLayer);
    final matched = MatchedFeatures.of(layer, sourceLayer, tile: tile);
    final Set<PreparedFeature>? selected =
        matched == null || identical(matched, features)
            ? null
            : (HashSet<PreparedFeature>.identity()..addAll(matched));
    final heightProp = layer.extrusionHeight ?? DoubleProp.constant(0);
    final baseProp = layer.extrusionBase ?? DoubleProp.constant(0);
    final n = mesh.length;
    final buildings = Int32List(n);
    final heights = Float32List(n);
    final bases = Float32List(n);
    // A height or base reading the zoom *and* the feature is evaluated
    // at both ends of the level; one reading the zoom alone is the same
    // for every building and is too.
    final heightNext =
        zoom != null && layer.extrusionHeightReadsZoom ? Float32List(n) : null;
    final baseNext =
        zoom != null && layer.extrusionBaseReadsZoom ? Float32List(n) : null;
    var nextHeight = 0.0, nextBase = 0.0;
    final classOf = Uint16List(n);
    final classes = <int>[];
    final classIndex = <int, Map<int, int>>{};
    final bounds = Float32List(n * 4);
    final gradient =
        layer.extrusionVerticalGradient?.eval(EvalContext(zoom: styleZoom)) ??
            true;
    var count = 0;
    var maxHeight = 0.0;
    var last = -1;
    var drawn = false;
    var height = 0.0, base = 0.0;
    var colorClass = 0;
    final meshBounds = mesh.bounds;
    for (var p = 0; p < n; p++) {
      // A feature's polygons are consecutive and share its evaluation.
      final index = mesh.feature[p];
      if (index != last) {
        last = index;
        drawn = false;
        final feature = features[index];
        if (selected != null && !selected.contains(feature)) continue;
        final ctx = featureContext(
          zoom: styleZoom,
          properties: feature.properties,
          geometryType: feature.geometryType,
          featureId: feature.id,
          featureState: FeatureStates.stateOf(states, feature.id),
        );
        if (matched == null && !layer.matches(ctx)) continue;
        height = heightProp.eval(ctx);
        base = baseProp.eval(ctx);
        if (heightNext != null || baseNext != null) {
          final next = featureContext(
            zoom: styleZoom + 1,
            properties: feature.properties,
            geometryType: feature.geometryType,
            featureId: feature.id,
            featureState: FeatureStates.stateOf(states, feature.id),
          );
          nextHeight = heightNext != null ? heightProp.eval(next) : height;
          nextBase = baseNext != null ? baseProp.eval(next) : base;
          if (!(nextHeight >= 0)) nextHeight = 0;
          if (!(nextBase >= 0)) nextBase = 0;
          if (nextBase > nextHeight) nextBase = nextHeight;
        }
        if (!(height >= 0)) height = 0;
        if (!(base >= 0)) base = 0;
        if (base > height) base = height;
        // Nothing to draw at either end of the level.
        if (height == 0 && !(heightNext != null && nextHeight > 0)) continue;
        final argb = layer.color.eval(ctx).toARGB32();
        final bottom = gradient
            ? ExtrusionShading.gradientKey(0, base, height)
            : ExtrusionShading.noGradient;
        final top = gradient
            ? ExtrusionShading.gradientKey(1, base, height)
            : ExtrusionShading.noGradient;
        final byGradient = classIndex[argb] ??= {};
        colorClass = byGradient[bottom << 8 | top] ??= () {
          classes
            ..add(argb)
            ..add(bottom)
            ..add(top);
          return classes.length ~/ 3 - 1;
        }();
        drawn = colorClass < 0x10000;
      }
      if (!drawn) continue;
      buildings[count] = p;
      heights[count] = height;
      bases[count] = base;
      heightNext?[count] = nextHeight;
      baseNext?[count] = nextBase;
      classOf[count] = colorClass;
      bounds[count * 4] = meshBounds[p * 4];
      bounds[count * 4 + 1] = meshBounds[p * 4 + 1];
      bounds[count * 4 + 2] = meshBounds[p * 4 + 2];
      bounds[count * 4 + 3] = meshBounds[p * 4 + 3];
      if (height > maxHeight) maxHeight = height;
      count++;
    }
    // Walls shared with a drawn neighbour start at its roof.
    Float32List? floors;
    final twins = mesh.wallTwin;
    if (count > 0) {
      final drawnAs = Int32List(n)..fillRange(0, n, -1);
      for (var i = 0; i < count; i++) {
        drawnAs[buildings[i]] = i;
      }
      for (var i = 0; i < count; i++) {
        final p = buildings[i];
        for (var w = mesh.wallStart[p]; w < mesh.wallStart[p + 1]; w += 2) {
          final twin = twins[w >> 1];
          if (twin == ExtrusionMesh.noTwin) continue;
          final other = drawnAs[twin];
          if (other < 0 || !(heights[other] > bases[i])) continue;
          floors ??= Float32List(twins.length)
            ..fillRange(0, twins.length, double.nan);
          floors[w >> 1] = heights[other];
        }
      }
    }
    return ExtrusionLayout._(
      layer: layer,
      stateVersion: stateVersion,
      tile: tile,
      extent: sourceLayer.extent.toDouble(),
      mesh: mesh,
      source: sourceLayer,
      buildings: Int32List.fromList(Int32List.sublistView(buildings, 0, count)),
      heights: Float32List.fromList(Float32List.sublistView(heights, 0, count)),
      bases: Float32List.fromList(Float32List.sublistView(bases, 0, count)),
      zoom: zoom,
      nextHeights: heightNext == null
          ? null
          : Float32List.fromList(Float32List.sublistView(heightNext, 0, count)),
      nextBases: baseNext == null
          ? null
          : Float32List.fromList(Float32List.sublistView(baseNext, 0, count)),
      classOf: Uint16List.fromList(Uint16List.sublistView(classOf, 0, count)),
      classes: Int32List.fromList(classes),
      wallFloors: floors,
      bounds:
          Float32List.fromList(Float32List.sublistView(bounds, 0, count * 4)),
      maxHeight: maxHeight,
    );
  }
}
