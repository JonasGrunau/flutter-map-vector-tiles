import 'dart:ui' show Color;

import 'package:meta/meta.dart';

import 'expression.dart';

/// A compiled map style: an ordered list of paintable layers.
class Theme {
  /// Identifier used in cache keys — bump/vary when the style changes.
  final String id;
  final List<ThemeLayer> layers;

  const Theme({required this.id, required this.layers});

  /// Evaluates the background color at [zoom] (first background layer).
  Color? backgroundColor(double zoom) {
    for (final layer in layers) {
      if (layer is BackgroundThemeLayer && layer.coversZoom(zoom)) {
        final ctx = EvalContext(zoom: zoom);
        final opacity = layer.opacity.eval(ctx).clamp(0.0, 1.0);
        final color = layer.color.eval(ctx);
        return opacity >= 1.0
            ? color
            : color.withValues(alpha: color.a * opacity);
      }
    }
    return null;
  }

  /// The source-layer names referenced per source, used to skip decoding
  /// unused MVT layers.
  Map<String, Set<String>> get referencedSourceLayers {
    final result = <String, Set<String>>{};
    for (final layer in layers) {
      final source = layer.source;
      final sourceLayer = layer.sourceLayer;
      if (source != null && sourceLayer != null) {
        (result[source] ??= {}).add(sourceLayer);
      }
    }
    return result;
  }
}

/// Base class for compiled style layers.
sealed class ThemeLayer {
  final String id;
  final String? source;
  final String? sourceLayer;
  final double minzoom;
  final double maxzoom;

  /// Compiled filter; returns a truthy value when the feature matches.
  final Expr filter;

  /// Property names this layer's expressions read, or null when unknown
  /// (all properties must be retained). Assigned once by the theme reader
  /// after all of the layer's expressions have been parsed.
  Set<String>? referencedProperties;

  /// Whether [filter] reads the zoom. Only a zoom-free filter selects
  /// the same features at every zoom and may be resolved once per
  /// prepared tile (see `MatchedFeatures`). Assigned by the theme
  /// reader; unknown means true, so a hand-built layer is always
  /// evaluated per display tile. Not for use outside this package: false
  /// on a filter that reads the zoom would draw, at every zoom, what the
  /// filter selects at zoom 0.
  @internal
  bool filterReadsZoom = true;

  ThemeLayer({
    required this.id,
    required this.source,
    required this.sourceLayer,
    required this.minzoom,
    required this.maxzoom,
    required this.filter,
    this.referencedProperties,
  });

  /// The values the reader substitutes for an absent `minzoom` /
  /// `maxzoom`. A layer sitting exactly on one of these has no edge the
  /// style asked for there, which the label pass needs to know: it fades
  /// symbols out approaching a *declared* edge, and must not ramp
  /// against a bound that only stands in for "unset".
  static const double defaultMinzoom = 0;
  static const double defaultMaxzoom = 24;

  /// Style zoom range check. Per spec, maxzoom is exclusive-ish (a layer
  /// with maxzoom 14 disappears at zoom >= 14); minzoom inclusive.
  bool coversZoom(double zoom) => zoom >= minzoom && zoom < maxzoom;

  /// Whether the range intersects the band [zoom, zoom + 1) — the
  /// fractional style zooms a tile laid out at integer style zoom
  /// [zoom] is painted at.
  bool coversZoomBand(double zoom) => zoom + 1 > minzoom && zoom < maxzoom;

  bool matches(EvalContext ctx) => toBoolean(filter(ctx));
}

class BackgroundThemeLayer extends ThemeLayer {
  final ColorProp color;
  final DoubleProp opacity;

  BackgroundThemeLayer({
    required super.id,
    required this.color,
    required this.opacity,
    required super.minzoom,
    required super.maxzoom,
    required super.filter,
  }) : super(source: null, sourceLayer: null, referencedProperties: null);
}

class FillThemeLayer extends ThemeLayer {
  final ColorProp color;
  final DoubleProp opacity;
  final ColorProp? outlineColor;
  final bool antialias;

  /// Sprite name for `fill-pattern`. When set (and the sprite resolves),
  /// the pattern replaces the color fill and outline, per spec.
  final StringProp? pattern;

  /// Whether this is a `fill-extrusion` layer, drawn flat from above.
  /// Its opacity applies to the layer as a whole rather than to each
  /// feature, per spec, so overlapping buildings are not darker where
  /// they overlap — patterned ones included — and the alpha of its
  /// colour is ignored, as the spec says.
  final bool extrusion;

  FillThemeLayer({
    required super.id,
    required super.source,
    required super.sourceLayer,
    required super.minzoom,
    required super.maxzoom,
    required super.filter,
    required this.color,
    required this.opacity,
    required this.outlineColor,
    required this.antialias,
    this.pattern,
    this.extrusion = false,
  });
}

class LineThemeLayer extends ThemeLayer {
  final ColorProp color;
  final DoubleProp width;
  final DoubleProp opacity;
  final DoubleProp gapWidth;
  final NumListProp? dashArray;
  final StringProp cap;
  final StringProp join;

  /// Sprite name for `line-pattern`. When set (and the sprite resolves),
  /// the pattern replaces the color stroke and dash array, per spec.
  final StringProp? pattern;

  LineThemeLayer({
    required super.id,
    required super.source,
    required super.sourceLayer,
    required super.minzoom,
    required super.maxzoom,
    required super.filter,
    required this.color,
    required this.width,
    required this.opacity,
    required this.gapWidth,
    required this.dashArray,
    required this.cap,
    required this.join,
    this.pattern,
  });
}

/// A `raster` layer displaying image tiles from a raster source declared
/// inside a vector style (satellite/hybrid styles, pre-rendered
/// hillshading). Painted into the tile raster at its style position.
class RasterThemeLayer extends ThemeLayer {
  final DoubleProp opacity;
  final DoubleProp brightnessMin;
  final DoubleProp brightnessMax;
  final DoubleProp contrast;
  final DoubleProp saturation;
  final DoubleProp hueRotate; // degrees

  RasterThemeLayer({
    required super.id,
    required super.source,
    required super.minzoom,
    required super.maxzoom,
    required super.filter,
    required this.opacity,
    required this.brightnessMin,
    required this.brightnessMax,
    required this.contrast,
    required this.saturation,
    required this.hueRotate,
  }) : super(sourceLayer: null, referencedProperties: const {});
}

class CircleThemeLayer extends ThemeLayer {
  final DoubleProp radius;
  final ColorProp color;
  final DoubleProp opacity;
  final ColorProp strokeColor;
  final DoubleProp strokeWidth;
  final DoubleProp strokeOpacity;

  CircleThemeLayer({
    required super.id,
    required super.source,
    required super.sourceLayer,
    required super.minzoom,
    required super.maxzoom,
    required super.filter,
    required this.radius,
    required this.color,
    required this.opacity,
    required this.strokeColor,
    required this.strokeWidth,
    required this.strokeOpacity,
  });
}

class SymbolThemeLayer extends ThemeLayer {
  // Layout
  final StringProp placement; // point | line | line-center
  final DoubleProp sortKey;
  final DoubleProp spacing;
  final StringProp textField;
  final DoubleProp textSize;
  final StringListProp textFont;
  final DoubleProp textMaxWidth; // ems
  final DoubleProp textLetterSpacing; // ems
  final StringProp textTransform; // none | uppercase | lowercase
  final StringProp textAnchor;

  /// `text-variable-anchor`: ordered anchor candidates tried until one
  /// fits without collision. When set, [textAnchor] and [textOffset] are
  /// ignored and [textRadialOffset] is used instead, per spec.
  final StringListProp? textVariableAnchor;
  final DoubleProp textRadialOffset; // ems
  final NumListProp textOffset; // ems
  final DoubleProp textPadding;
  final BoolProp textAllowOverlap;
  final BoolProp textOptional;

  /// `text-max-angle`: maximum angle change (degrees) between adjacent
  /// glyphs of curved line text; sharper labels are not placed.
  final DoubleProp textMaxAngle;
  final BoolProp textKeepUpright;
  final StringProp textRotationAlignment; // auto | map | viewport
  final StringProp? iconImage;
  final DoubleProp iconSize;
  final StringProp iconAnchor;
  final NumListProp iconOffset; // px
  final BoolProp iconAllowOverlap;

  /// `icon-rotate`: clockwise degrees, on top of whatever
  /// [iconRotationAlignment] resolves to.
  final DoubleProp iconRotate;

  /// `icon-rotation-alignment`: auto | map | viewport. `auto` resolves to
  /// `map` for a line-placed icon and `viewport` otherwise, per spec.
  final StringProp iconRotationAlignment;

  /// `text-justify`: auto | left | center | right — how the lines of
  /// multi-line text align with each other. `auto` justifies towards
  /// the side of the box the anchor is on.
  final StringProp textJustify;

  /// `text-line-height`, in ems: the distance between baselines, and so
  /// also the height of one line's box.
  final DoubleProp textLineHeight;

  /// `text-rotate`: clockwise degrees about the anchor, for text that is
  /// not placed along a line.
  final DoubleProp textRotate;

  /// `text-variable-anchor-offset`: anchors with an em offset each.
  /// When set, it takes precedence over [textAnchor], [textOffset],
  /// [textVariableAnchor] and [textRadialOffset], per spec.
  final AnchorOffsetsProp? textVariableAnchorOffset;

  /// `text-ignore-placement` / `icon-ignore-placement`: the symbol is
  /// placed without reserving its space, so later symbols may overlap it.
  final BoolProp textIgnorePlacement;
  final BoolProp iconIgnorePlacement;

  /// `text-overlap` / `icon-overlap`: never | always | cooperative.
  /// Null when the style leaves them unset, in which case
  /// [textAllowOverlap] / [iconAllowOverlap] decide, per spec.
  final StringProp? textOverlap;
  final StringProp? iconOverlap;

  /// `icon-optional`: text may show without its icon when only the icon
  /// collides — the counterpart of [textOptional].
  final BoolProp iconOptional;

  /// `icon-padding`: one to four numbers, CSS order (top, right, bottom,
  /// left), added around the icon's collision box.
  final NumListProp iconPadding;

  /// `icon-text-fit`: none | width | height | both — stretches the icon
  /// around the text, plus [iconTextFitPadding] (top, right, bottom,
  /// left, in px).
  final StringProp iconTextFit;
  final NumListProp iconTextFitPadding;

  /// `icon-keep-upright`: a map-aligned icon along a line is turned
  /// around rather than drawn upside down.
  final BoolProp iconKeepUpright;

  /// `symbol-z-order`: auto | viewport-y | source — the draw order of
  /// overlapping symbols within this layer.
  final StringProp symbolZOrder;

  /// `symbol-avoid-edges`: a symbol must not cross its tile's edge.
  final BoolProp symbolAvoidEdges;

  // Paint
  final ColorProp textColor;
  final ColorProp textHaloColor;
  final DoubleProp textHaloWidth;

  /// `text-halo-blur` / `icon-halo-blur`, in px: how far the halo fades
  /// out towards its outer edge.
  final DoubleProp textHaloBlur;
  final DoubleProp textOpacity;

  /// `text-translate` / `icon-translate` (px, right and down) and their
  /// `*-translate-anchor` (map | viewport).
  final NumListProp textTranslate;
  final StringProp textTranslateAnchor;
  final NumListProp iconTranslate;
  final StringProp iconTranslateAnchor;
  final DoubleProp iconOpacity;

  /// `icon-color`/`icon-halo-*` only apply to SDF sprites (see
  /// [Sprite.sdf]); ordinary sprites carry their own colours.
  final ColorProp iconColor;
  final ColorProp iconHaloColor;
  final DoubleProp iconHaloWidth;
  final DoubleProp iconHaloBlur;

  /// Every property after [iconHaloWidth] is optional and defaults to
  /// its spec value, so code constructing layers by hand keeps working.
  SymbolThemeLayer({
    required super.id,
    required super.source,
    required super.sourceLayer,
    required super.minzoom,
    required super.maxzoom,
    required super.filter,
    required this.placement,
    required this.sortKey,
    required this.spacing,
    required this.textField,
    required this.textSize,
    required this.textFont,
    required this.textMaxWidth,
    required this.textLetterSpacing,
    required this.textTransform,
    required this.textAnchor,
    this.textVariableAnchor,
    required this.textRadialOffset,
    required this.textOffset,
    required this.textPadding,
    required this.textAllowOverlap,
    required this.textOptional,
    required this.textMaxAngle,
    required this.textKeepUpright,
    required this.textRotationAlignment,
    required this.iconImage,
    required this.iconSize,
    required this.iconAnchor,
    required this.iconOffset,
    required this.iconAllowOverlap,
    required this.iconRotate,
    required this.iconRotationAlignment,
    required this.textColor,
    required this.textHaloColor,
    required this.textHaloWidth,
    required this.textOpacity,
    required this.iconOpacity,
    required this.iconColor,
    required this.iconHaloColor,
    required this.iconHaloWidth,
    StringProp? textJustify,
    DoubleProp? textLineHeight,
    DoubleProp? textRotate,
    this.textVariableAnchorOffset,
    BoolProp? textIgnorePlacement,
    BoolProp? iconIgnorePlacement,
    this.textOverlap,
    this.iconOverlap,
    BoolProp? iconOptional,
    NumListProp? iconPadding,
    StringProp? iconTextFit,
    NumListProp? iconTextFitPadding,
    BoolProp? iconKeepUpright,
    StringProp? symbolZOrder,
    BoolProp? symbolAvoidEdges,
    DoubleProp? textHaloBlur,
    NumListProp? textTranslate,
    StringProp? textTranslateAnchor,
    NumListProp? iconTranslate,
    StringProp? iconTranslateAnchor,
    DoubleProp? iconHaloBlur,
  })  : textJustify = textJustify ?? StringProp.constant('center'),
        textLineHeight = textLineHeight ?? DoubleProp.constant(1.2),
        textRotate = textRotate ?? DoubleProp.constant(0),
        textIgnorePlacement = textIgnorePlacement ?? BoolProp.constant(false),
        iconIgnorePlacement = iconIgnorePlacement ?? BoolProp.constant(false),
        iconOptional = iconOptional ?? BoolProp.constant(false),
        iconPadding = iconPadding ?? NumListProp.constant(const [2]),
        iconTextFit = iconTextFit ?? StringProp.constant('none'),
        iconTextFitPadding =
            iconTextFitPadding ?? NumListProp.constant(const [0, 0, 0, 0]),
        iconKeepUpright = iconKeepUpright ?? BoolProp.constant(false),
        symbolZOrder = symbolZOrder ?? StringProp.constant('auto'),
        symbolAvoidEdges = symbolAvoidEdges ?? BoolProp.constant(false),
        textHaloBlur = textHaloBlur ?? DoubleProp.constant(0),
        textTranslate = textTranslate ?? NumListProp.constant(const [0, 0]),
        textTranslateAnchor = textTranslateAnchor ?? StringProp.constant('map'),
        iconTranslate = iconTranslate ?? NumListProp.constant(const [0, 0]),
        iconTranslateAnchor = iconTranslateAnchor ?? StringProp.constant('map'),
        iconHaloBlur = iconHaloBlur ?? DoubleProp.constant(0);
}
