import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:meta/meta.dart';

import '../pipeline/prepared_tile.dart';
import '../style/expression.dart';
import '../style/theme.dart';
import 'display_tile_data.dart';
import 'tile_rasterizer.dart';

/// A polyline in logical display-tile coordinates with precomputed
/// cumulative distances, shared by all anchors placed along it.
class SymbolPath {
  /// Interleaved x,y vertex coordinates.
  final Float32List points;

  /// Distance from the path start to each vertex.
  final Float32List cumulative;

  const SymbolPath(this.points, this.cumulative);

  double get length => cumulative[cumulative.length - 1];

  /// Index of the segment containing distance [d] (clamped).
  int segmentAt(double d) {
    var lo = 0, hi = cumulative.length - 2;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (cumulative[mid] <= d) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  Offset pointAt(double d) {
    final i = segmentAt(d);
    final segment = cumulative[i + 1] - cumulative[i];
    final f =
        segment <= 0 ? 0.0 : ((d - cumulative[i]) / segment).clamp(0.0, 1.0);
    return Offset(
      points[i * 2] + (points[i * 2 + 2] - points[i * 2]) * f,
      points[i * 2 + 1] + (points[i * 2 + 3] - points[i * 2 + 1]) * f,
    );
  }

  /// Baseline angle (radians) of the segment containing distance [d].
  double angleAt(double d) {
    final i = segmentAt(d);
    return math.atan2(points[i * 2 + 3] - points[i * 2 + 1],
        points[i * 2 + 2] - points[i * 2]);
  }
}

/// A single label/icon placement candidate within a display tile,
/// in logical tile coordinates (0..256).
class SymbolInstance {
  final SymbolThemeLayer layer;

  /// Index of the layer in the theme, for stable ordering.
  final int layerIndex;
  final Offset anchor;

  /// Baseline angle in tile space (radians); only meaningful when
  /// [alongLine] is true.
  final double angle;
  final bool alongLine;

  /// The line this anchor sits on (for curved text); null for point
  /// placements.
  final SymbolPath? path;

  /// Distance of [anchor] along [path], in logical pixels.
  final double pathDistance;
  final String text;
  final String? iconName;
  final double sortKey;
  final Map<String, Object?> properties;
  final String geometryType;
  final Object? featureId;

  /// Label-pass memo (see `LabelPainter._layoutText`): the evaluated,
  /// quantized text style and the cache-key strings built from it.
  /// Trusted as-is while the eval zoom is unchanged; on a zoom step it
  /// is revalidated by comparing the re-evaluated primitives, so the
  /// key strings are rebuilt only when a style ramp actually crosses a
  /// quantization step — not once per zoom step, and never per frame.
  TextStyleMemo? textStyleMemo;

  /// The `text-variable-anchor` this label was last placed at. Tried
  /// first at the next placement, so an anchor only moves when it
  /// genuinely stops fitting — a label that hopped to its second choice
  /// because a neighbour brushed past it for one pass would otherwise
  /// hop straight back. Null until the label is first placed, and never
  /// set for labels whose layer declares no variable anchors.
  String? anchorMemo;

  /// Whether this label's text lost its space at the last placement and
  /// only its icon was drawn (`text-optional`). Replayed between
  /// placement passes, where nothing competes for space and the text
  /// would otherwise flash back in for those frames.
  bool textDropped = false;

  /// Whether this along-line label last read *against* its line's
  /// direction. Sticky: see `LabelPainter._readsBackwards`, which only
  /// changes the answer once the line is clearly past vertical, because
  /// the raw test flips at exactly vertical — where a road's on-screen
  /// direction is a pixel of camera noise, and every flip mirrors the
  /// label to the other side of the line.
  bool? uprightFlip;

  /// Whether per-glyph curved rendering is safe for [text]: re-shaping
  /// each cluster in isolation only preserves scripts without
  /// contextual joining (Latin, Greek, Cyrillic, CJK). Computed once —
  /// the label pass consults this per frame for along-line labels.
  late final bool curveSafe = _curveSafe(text);

  /// Cross-zoom fade identity — see `labelContinuityKey` in
  /// `label_continuity.dart` for why it is this position-free record.
  /// Memoized here because the label pass needs it per candidate per
  /// frame, and a record allocation per lookup would churn the young
  /// generation on every painted frame.
  late final Object continuityKey = (layerIndex, text, iconName);

  static bool _curveSafe(String text) {
    for (final r in text.runes) {
      final ok = r < 0x0590 || // Latin, Greek, Cyrillic, combining marks
          (r >= 0x1e00 && r <= 0x2bff) || // Latin/Greek ext., punctuation
          (r >= 0x2e80 && r <= 0xa4cf) || // CJK
          (r >= 0xac00 && r <= 0xd7ff) || // Hangul
          (r >= 0xf900 && r <= 0xfaff) || // CJK compatibility
          (r >= 0xff00 && r <= 0xffef); // half/fullwidth forms
      if (!ok) return false;
    }
    return true;
  }

  SymbolInstance({
    required this.layer,
    required this.layerIndex,
    required this.anchor,
    required this.angle,
    required this.alongLine,
    this.path,
    this.pathDistance = 0,
    required this.text,
    required this.iconName,
    required this.sortKey,
    required this.properties,
    required this.geometryType,
    required this.featureId,
  });
}

/// The evaluated, quantized text style of a [SymbolInstance], memoized
/// on the instance by `LabelPainter._layoutText`.
///
/// Text is shaped once at a fixed reference size and drawn scaled, so
/// none of these primitives depend on the font size — for the common
/// all-constant style they change never, and for zoom ramps only when a
/// colour/opacity/halo quantization step is crossed. While they are
/// unchanged the pre-built [cacheKey]/[styleKey] strings are reused,
/// keeping string building out of the per-frame label path.
class TextStyleMemo {
  /// Fill/halo colours with the quantized `text-opacity` folded in.
  final int fillArgb;
  final int haloArgb;

  /// `text-halo-width` as a ratio of the font size, in 1/128-em steps;
  /// 0 when the halo is absent or fully transparent.
  final int haloRatioQ;
  final List<String> fonts;
  final double letterSpacingEm;
  final double maxWidthEm;

  /// Key prefix shared by every glyph of this style (glyph cache).
  final String styleKey;

  /// Full text-layout cache key (text cache).
  final String cacheKey;

  /// The eval zoom this memo was last validated at: while it is
  /// unchanged the style expressions need not be re-evaluated at all.
  double zoom;

  TextStyleMemo({
    required this.fillArgb,
    required this.haloArgb,
    required this.haloRatioQ,
    required this.fonts,
    required this.letterSpacingEm,
    required this.maxWidthEm,
    required this.styleKey,
    required this.cacheKey,
    required this.zoom,
  });

  bool matches(
    int fillArgb,
    int haloArgb,
    int haloRatioQ,
    List<String> fonts,
    double letterSpacingEm,
    double maxWidthEm,
  ) =>
      fillArgb == this.fillArgb &&
      haloArgb == this.haloArgb &&
      haloRatioQ == this.haloRatioQ &&
      letterSpacingEm == this.letterSpacingEm &&
      maxWidthEm == this.maxWidthEm &&
      _sameFonts(fonts);

  bool _sameFonts(List<String> other) {
    // Constant `text-font` lists are pre-converted once by the style
    // engine, so this is almost always an identity hit.
    if (identical(other, fonts)) return true;
    if (other.length != fonts.length) return false;
    for (var i = 0; i < fonts.length; i++) {
      if (other[i] != fonts[i]) return false;
    }
    return true;
  }
}

/// Extracts symbol placement candidates from a display tile's prepared
/// data at a given style zoom. Runs once per (display tile, integer
/// zoom); results are cached by the tile model.
class SymbolLayouter {
  /// Ignore symbols anchored outside the tile (with a small buffer):
  /// neighbouring tiles will place them, avoiding duplicates at seams.
  static const double _buffer = 0.5;

  /// Layout passes run; for tests asserting that cached results are
  /// reused instead of re-extracted.
  @visibleForTesting
  static int debugLayoutCount = 0;

  /// Whether any symbol layer of [theme] is visible somewhere in the
  /// zoom band [styleZoom, styleZoom + 1) — the render pump skips the
  /// symbol phase entirely below the first symbol minzoom, so
  /// label-free zooms pay nothing for it.
  static bool anySymbolLayerCovers(Theme theme, double styleZoom) {
    for (final layer in theme.layers) {
      if (layer is SymbolThemeLayer && layer.coversZoomBand(styleZoom)) {
        return true;
      }
    }
    return false;
  }

  static List<SymbolInstance> layout({
    required Theme theme,
    required DisplayTileData data,
    required double styleZoom,
  }) {
    debugLayoutCount++;
    final instances = <SymbolInstance>[];
    for (var i = 0; i < theme.layers.length; i++) {
      final layer = theme.layers[i];
      // A tile of this level is painted at fractional style zooms in
      // [styleZoom, styleZoom + 1); any layer whose range intersects
      // that band is laid out, and the label pass gates each frame at
      // the exact fractional zoom.
      if (layer is! SymbolThemeLayer || !layer.coversZoomBand(styleZoom)) {
        continue;
      }
      final source = layer.source;
      final sourceLayerName = layer.sourceLayer;
      if (source == null || sourceLayerName == null) continue;
      final tile = data.sources[source];
      final sourceLayer = tile?.layers[sourceLayerName];
      if (tile == null || sourceLayer == null) continue;

      final frac = data.displayKey.fractionOf(tile.key);
      final scale =
          TileRasterizer.logicalTileSize / (sourceLayer.extent * frac.scale);
      final offsetX = -frac.dx * TileRasterizer.logicalTileSize / frac.scale;
      final offsetY = -frac.dy * TileRasterizer.logicalTileSize / frac.scale;

      // The display window in tile-extent units, expanded by the anchor
      // buffer. Every anchor lies on its feature's geometry (point
      // anchors are vertices, line anchors sit on the polyline, a
      // polygon's centroid is inside its convex hull — a
      // self-intersecting ring could theoretically escape its bbox, but
      // that is invalid MVT), so a feature whose bounds miss the window
      // cannot place an anchor `add` would accept: this cull is exact.
      final cullMinX = (-_buffer - offsetX) / scale;
      final cullMaxX =
          (TileRasterizer.logicalTileSize + _buffer - offsetX) / scale;
      final cullMinY = (-_buffer - offsetY) / scale;
      final cullMaxY =
          (TileRasterizer.logicalTileSize + _buffer - offsetY) / scale;

      for (final feature in sourceLayer.features) {
        if (feature.maxX < cullMinX ||
            feature.minX > cullMaxX ||
            feature.maxY < cullMinY ||
            feature.minY > cullMaxY) {
          continue;
        }
        final ctx = EvalContext(
          zoom: styleZoom,
          properties: feature.properties,
          geometryType: feature.geometryType,
          featureId: feature.id,
        );
        if (!layer.matches(ctx)) continue;

        var text = layer.textField.eval(ctx).trim();
        if (text.isNotEmpty) {
          text = switch (layer.textTransform.eval(ctx)) {
            'uppercase' => text.toUpperCase(),
            'lowercase' => text.toLowerCase(),
            _ => text,
          };
        }
        final iconName = layer.iconImage?.eval(ctx);
        if (text.isEmpty && (iconName == null || iconName.isEmpty)) {
          continue;
        }

        final placement = layer.placement.eval(ctx);
        final sortKey = layer.sortKey.eval(ctx);

        void add(Offset anchor, double angle, bool alongLine,
            {SymbolPath? path, double pathDistance = 0}) {
          if (anchor.dx < -_buffer ||
              anchor.dy < -_buffer ||
              anchor.dx >= TileRasterizer.logicalTileSize + _buffer ||
              anchor.dy >= TileRasterizer.logicalTileSize + _buffer) {
            return;
          }
          instances.add(SymbolInstance(
            layer: layer,
            layerIndex: i,
            anchor: anchor,
            angle: angle,
            alongLine: alongLine,
            path: path,
            pathDistance: pathDistance,
            text: text,
            iconName: (iconName == null || iconName.isEmpty) ? null : iconName,
            sortKey: sortKey,
            properties: feature.properties,
            geometryType: feature.geometryType,
            featureId: feature.id,
          ));
        }

        if (placement == 'point' || feature.type == PreparedGeomType.point) {
          for (final part in feature.parts) {
            if (feature.type == PreparedGeomType.polygon) {
              // Label polygons at their centroid (first exterior ring).
              final centroid = _centroid(part);
              add(
                  Offset(centroid.dx * scale + offsetX,
                      centroid.dy * scale + offsetY),
                  0,
                  false);
              break;
            }
            if (feature.type == PreparedGeomType.line) {
              // point placement on a line: use the midpoint.
              final mid = _midpoint(part);
              add(Offset(mid.dx * scale + offsetX, mid.dy * scale + offsetY), 0,
                  false);
              continue;
            }
            for (var p = 0; p + 1 < part.length; p += 2) {
              add(
                  Offset(
                      part[p] * scale + offsetX, part[p + 1] * scale + offsetY),
                  0,
                  false);
            }
          }
        } else {
          // line / line-center placement
          final spacing = placement == 'line-center'
              ? double.infinity
              : layer.spacing.eval(ctx);
          for (final part in feature.parts) {
            _placeAlongLine(part, scale, offsetX, offsetY, spacing, add);
          }
        }
      }
    }
    return instances;
  }

  /// Places anchors along a polyline every [spacing] logical pixels
  /// (or a single anchor at the middle when spacing is infinite).
  ///
  /// Anchors keep their full-line parametrization — the k-th anchor sits
  /// at `spacing/2 + k·spacing` measured over the *whole* line — so an
  /// anchor lands at the same world position no matter which display
  /// tile lays it out. Only the *enumeration* is windowed: segments that
  /// cannot reach the tile (where `add` would reject every anchor) are
  /// skipped, which at deep overzoom avoids walking targets across the
  /// entire data tile.
  static void _placeAlongLine(
    Float32List part,
    double scale,
    double offsetX,
    double offsetY,
    double spacing,
    void Function(Offset anchor, double angle, bool alongLine,
            {SymbolPath? path, double pathDistance})
        add,
  ) {
    if (part.length < 4) return;
    // Transform into logical display-tile coordinates once; the path is
    // shared by every anchor placed on it (and by the curved-text pass).
    final n = part.length ~/ 2;
    final points = Float32List(n * 2);
    final cumulative = Float32List(n);
    var total = 0.0;
    var minX = double.infinity, minY = double.infinity;
    var maxX = double.negativeInfinity, maxY = double.negativeInfinity;
    for (var i = 0; i < n; i++) {
      points[i * 2] = part[i * 2] * scale + offsetX;
      points[i * 2 + 1] = part[i * 2 + 1] * scale + offsetY;
      // Bounds over the float32-stored values, so the window tests below
      // see exactly what `add` will see.
      final x = points[i * 2];
      final y = points[i * 2 + 1];
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
      if (i > 0) {
        final dx = x - points[i * 2 - 2];
        final dy = y - points[i * 2 - 1];
        total += math.sqrt(dx * dx + dy * dy);
      }
      cumulative[i] = total;
    }
    if (total < 1) return;
    // `add` rejects anchors outside this window; when the whole part
    // lies outside (far-away part of a multi-part feature), skip it.
    const lo = -_buffer;
    const hi = TileRasterizer.logicalTileSize + _buffer;
    if (maxX < lo || minX >= hi || maxY < lo || minY >= hi) return;
    final path = SymbolPath(points, cumulative);

    if (!spacing.isFinite || spacing <= 0 || total < spacing) {
      final d = total / 2;
      add(path.pointAt(d), path.angleAt(d), true, path: path, pathDistance: d);
      return;
    }

    // Windowed enumeration: the half-open segment windows [c0, c1)
    // partition [0, total), so each global target d = half + k·spacing
    // is visited exactly once, by the segment `SymbolPath.segmentAt`
    // would assign it to; the interpolation mirrors `pointAt`/`angleAt`
    // for bit-identical anchors.
    final half = spacing / 2;
    for (var i = 0; i + 1 < n; i++) {
      final c0 = cumulative[i];
      final c1 = cumulative[i + 1];
      if (c1 <= c0) continue; // zero-length segment: empty window
      final x0 = points[i * 2];
      final y0 = points[i * 2 + 1];
      final x1 = points[i * 2 + 2];
      final y1 = points[i * 2 + 3];
      // Anchors lie on the segment: skip when its box misses the window.
      if ((x0 < lo && x1 < lo) ||
          (x0 >= hi && x1 >= hi) ||
          (y0 < lo && y1 < lo) ||
          (y0 >= hi && y1 >= hi)) {
        continue;
      }
      var k = ((c0 - half) / spacing).ceil();
      if (k < 0) k = 0;
      var d = half + k * spacing;
      if (d >= c1) continue;
      final segment = c1 - c0;
      final angle = math.atan2(y1 - y0, x1 - x0);
      while (d < c1) {
        final f = ((d - c0) / segment).clamp(0.0, 1.0);
        add(Offset(x0 + (x1 - x0) * f, y0 + (y1 - y0) * f), angle, true,
            path: path, pathDistance: d);
        k++;
        d = half + k * spacing;
      }
    }
  }

  static Offset _centroid(Float32List ring) {
    var areaSum = 0.0, cx = 0.0, cy = 0.0;
    final n = ring.length;
    for (var i = 0; i + 1 < n; i += 2) {
      final x0 = ring[i], y0 = ring[i + 1];
      final j = (i + 2) % n;
      final x1 = ring[j], y1 = ring[j + 1];
      final cross = x0 * y1 - x1 * y0;
      areaSum += cross;
      cx += (x0 + x1) * cross;
      cy += (y0 + y1) * cross;
    }
    if (areaSum.abs() < 1e-7) return Offset(ring[0], ring[1]);
    return Offset(cx / (3 * areaSum), cy / (3 * areaSum));
  }

  static Offset _midpoint(Float32List part) {
    var total = 0.0;
    for (var i = 0; i + 3 < part.length; i += 2) {
      final dx = part[i + 2] - part[i];
      final dy = part[i + 3] - part[i + 1];
      total += math.sqrt(dx * dx + dy * dy);
    }
    var travelled = 0.0;
    final half = total / 2;
    for (var i = 0; i + 3 < part.length; i += 2) {
      final dx = part[i + 2] - part[i];
      final dy = part[i + 3] - part[i + 1];
      final segment = math.sqrt(dx * dx + dy * dy);
      if (travelled + segment >= half && segment > 0) {
        final f = (half - travelled) / segment;
        return Offset(part[i] + dx * f, part[i + 1] + dy * f);
      }
      travelled += segment;
    }
    return Offset(part[0], part[1]);
  }
}
