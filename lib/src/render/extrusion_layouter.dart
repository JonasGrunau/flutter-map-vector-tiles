import 'dart:collection';
import 'dart:typed_data';

import '../core/tile_key.dart';
import '../pipeline/extrusion_mesh.dart';
import '../pipeline/prepared_tile.dart';
import '../style/expression.dart';
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

  /// The data tile the buildings come from, and its extent.
  final TileKey tile;
  final double extent;
  final ExtrusionMesh mesh;

  /// Per drawn building — one polygon of [mesh] — its index there.
  final Int32List buildings;

  /// Per drawn building: roof and floor, in metres, `base <= height`.
  final Float32List heights;
  final Float32List bases;

  /// Per drawn building: its colour class, an index into [classes].
  final Uint16List classOf;

  /// The colour classes, three ints each: the layer colour (ARGB, alpha
  /// kept — the shading premultiplies it), and the vertical-gradient
  /// keys at the walls' foot and top (`ExtrusionShading.gradientKey`).
  /// The painter turns each into a roof colour and a wall colour per
  /// light level.
  final Int32List classes;

  /// Per drawn building: its footprint's bounds in extent units,
  /// `minX, minY, maxX, maxY` — copied out of [mesh] so the painter's
  /// cull reads one list in drawing order.
  final Float32List bounds;

  /// The tallest [heights] entry.
  final double maxHeight;

  ExtrusionLayout._({
    required this.layer,
    required this.tile,
    required this.extent,
    required this.mesh,
    required this.buildings,
    required this.heights,
    required this.bases,
    required this.classOf,
    required this.classes,
    required this.bounds,
    required this.maxHeight,
  });

  int get length => buildings.length;

  int get byteSize =>
      buildings.lengthInBytes +
      heights.lengthInBytes +
      bases.lengthInBytes +
      classOf.lengthInBytes +
      classes.lengthInBytes +
      bounds.lengthInBytes +
      64;
}

/// Lays out the `fill-extrusion` layers of a display tile.
abstract final class ExtrusionLayouter {
  /// Per prepared source layer, its layouts by style layer.
  static final _cache = Expando<Map<FillThemeLayer, ExtrusionLayout>>();

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
      final laid = byLayer[layer] ??=
          _layoutLayer(layer, tile.key, sourceLayer, mesh, styleZoom);
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
  ) {
    final features = sourceLayer.features;
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
        );
        if (matched == null && !layer.matches(ctx)) continue;
        height = heightProp.eval(ctx);
        if (!(height > 0)) continue;
        base = baseProp.eval(ctx);
        if (!(base >= 0)) base = 0;
        if (base > height) base = height;
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
      classOf[count] = colorClass;
      bounds[count * 4] = meshBounds[p * 4];
      bounds[count * 4 + 1] = meshBounds[p * 4 + 1];
      bounds[count * 4 + 2] = meshBounds[p * 4 + 2];
      bounds[count * 4 + 3] = meshBounds[p * 4 + 3];
      if (height > maxHeight) maxHeight = height;
      count++;
    }
    return ExtrusionLayout._(
      layer: layer,
      tile: tile,
      extent: sourceLayer.extent.toDouble(),
      mesh: mesh,
      buildings: Int32List.fromList(Int32List.sublistView(buildings, 0, count)),
      heights: Float32List.fromList(Float32List.sublistView(heights, 0, count)),
      bases: Float32List.fromList(Float32List.sublistView(bases, 0, count)),
      classOf: Uint16List.fromList(Uint16List.sublistView(classOf, 0, count)),
      classes: Int32List.fromList(classes),
      bounds:
          Float32List.fromList(Float32List.sublistView(bounds, 0, count * 4)),
      maxHeight: maxHeight,
    );
  }
}
