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

  /// Per wall of [mesh], for a wall another drawn building stands in
  /// front of (`ExtrusionMesh.wallCovers`): that building, an index
  /// into [buildings] — the wall's visible part starts at its roof
  /// (`heightAt`), and the wall is hidden whole while that roof is at
  /// or above the building's own. -1 for the rest; null when no wall of
  /// the tile has one. A building, not an altitude: heights that ramp
  /// with the zoom move both roofs every frame.
  final Int32List? wallCoveredBy;

  /// Per drawn building: its footprint's bounds in extent units,
  /// `minX, minY, maxX, maxY` — copied out of [mesh] so the painter's
  /// cull reads one list in drawing order.
  final Float32List bounds;

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
    required this.wallCoveredBy,
    required this.bounds,
  });

  int get length => buildings.length;

  ExtrusionLight? _tableLight;
  Int32List? _table;

  /// [classes] under [light]: per class, `ExtrusionShading.stride`
  /// colours — kept with the layout, so a new tile set or a new frame
  /// fills it again only when the light changed.
  ///
  /// A new light gets a new table, never the old one filled again: two
  /// maps over the same data share their layouts, and each holds on to
  /// the table it was handed under its own light.
  Int32List tableFor(ExtrusionLight light) {
    final table = _table;
    if (table != null && light == _tableLight) return table;
    final filled = Int32List(classes.length ~/ 3 * ExtrusionShading.stride);
    for (var c = 0; c * 3 < classes.length; c++) {
      ExtrusionShading.fill(filled, c * ExtrusionShading.stride, classes[c * 3],
          classes[c * 3 + 1], classes[c * 3 + 2], light);
    }
    _table = filled;
    _tableLight = light;
    return filled;
  }

  int get byteSize =>
      buildings.lengthInBytes +
      heights.lengthInBytes +
      bases.lengthInBytes +
      (nextHeights?.lengthInBytes ?? 0) +
      (nextBases?.lengthInBytes ?? 0) +
      classOf.lengthInBytes +
      classes.lengthInBytes +
      (wallCoveredBy?.lengthInBytes ?? 0) +
      bounds.lengthInBytes +
      64;

  /// Building [i]'s roof and floor at style zoom [styleZoom].
  @pragma('vm:prefer-inline')
  double heightAt(int i, double styleZoom) =>
      _at(heights, nextHeights, i, styleZoom);
  @pragma('vm:prefer-inline')
  double baseAt(int i, double styleZoom) => _at(bases, nextBases, i, styleZoom);

  /// Per building, 1 unless its footprint centre lies in a cell of the
  /// [side] × [side] grid over the tile that [skip] marks — the
  /// buildings a skip mask leaves (`ExtrusionTile`), for the painter and
  /// for rendered-feature queries alike.
  Uint8List keptUnder(Uint8List skip, int side) {
    final kept = Uint8List(length);
    final cell = extent / side;
    for (var i = 0; i < length; i++) {
      final cx = (bounds[i * 4] + bounds[i * 4 + 2]) / 2;
      final cy = (bounds[i * 4 + 1] + bounds[i * 4 + 3]) / 2;
      final col = (cx / cell).floor().clamp(0, side - 1);
      final row = (cy / cell).floor().clamp(0, side - 1);
      kept[i] = skip[row * side + col] == 1 ? 0 : 1;
    }
    return kept;
  }

  /// Building [i]'s roof halfway through the layout's zoom band — what
  /// orders a layer's buildings for the whole band: heights ramping with
  /// the zoom are 0 at its start, all of them.
  double sortHeight(int i) {
    final next = nextHeights;
    return next == null ? heights[i] : (heights[i] + next[i]) / 2;
  }

  @pragma('vm:prefer-inline')
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
          if (layer is FillThemeLayer && layer.drawnIn3D) layer,
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

  /// The most a height or base is taken to be, in metres: far past the
  /// near plane at every zoom, and a finite `Float32` — a larger value
  /// stored would turn into infinity, which no sort key rounds.
  static const double _maxMetres = 100000;

  /// [value] as a height or base: 0 when negative or not a number,
  /// [_maxMetres] at most.
  static double _metres(double value) =>
      value >= 0 ? (value > _maxMetres ? _maxMetres : value) : 0;

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
          nextHeight = _metres(nextHeight);
          nextBase = _metres(nextBase);
          if (nextBase > nextHeight) nextBase = nextHeight;
        }
        height = _metres(height);
        base = _metres(base);
        if (base > height) base = height;
        // A building of height 0 stays: MapLibre draws its roof on the
        // ground, roof-shaded — and nothing else draws it, the layer is
        // not in the tile images.
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
      count++;
    }
    // A wall another drawn building stands in front of starts at that
    // building's roof — the tallest such one standing no higher than
    // this one's floor, judged halfway through the zoom band, as the
    // painter's order is (`sortHeight`).
    Int32List? coveredBy;
    final coverStart = mesh.wallCoverStart, covers = mesh.wallCovers;
    if (count > 0 && covers.isNotEmpty) {
      double mid(Float32List at, Float32List? next, int i) =>
          next == null ? at[i] : (at[i] + next[i]) / 2;
      final drawnAs = Int32List(n)..fillRange(0, n, -1);
      for (var i = 0; i < count; i++) {
        drawnAs[buildings[i]] = i;
      }
      for (var i = 0; i < count; i++) {
        final p = buildings[i];
        final floorOf = mid(bases, baseNext, i);
        for (var w = mesh.wallStart[p]; w < mesh.wallStart[p + 1]; w += 2) {
          final wall = w >> 1;
          var cover = -1;
          var floor = 0.0;
          for (var k = coverStart[wall]; k < coverStart[wall + 1]; k++) {
            final other = drawnAs[covers[k]];
            if (other < 0 || mid(bases, baseNext, other) > floorOf) continue;
            final roofOf = mid(heights, heightNext, other);
            if (roofOf > floorOf && (cover < 0 || roofOf > floor)) {
              cover = other;
              floor = roofOf;
            }
          }
          if (cover < 0) continue;
          coveredBy ??= Int32List(coverStart.length - 1)
            ..fillRange(0, coverStart.length - 1, -1);
          coveredBy[wall] = cover;
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
      wallCoveredBy: coveredBy,
      bounds:
          Float32List.fromList(Float32List.sublistView(bounds, 0, count * 4)),
    );
  }
}
