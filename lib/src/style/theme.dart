import 'dart:ui' show Color;

import 'package:meta/meta.dart';

import 'expression.dart';

/// A compiled map style: an ordered list of paintable layers.
class Theme {
  /// Identifier used in cache keys — bump/vary when the style changes.
  final String id;
  final List<ThemeLayer> layers;

  /// The values `["global-state", name]` expressions read in this theme:
  /// the style's `state` defaults with the overrides it was made with
  /// (see [withGlobalState]). Empty for a style that declares none and
  /// for hand-built themes.
  final Map<String, Object?> globalState;

  /// The theme's siblings under other global states, when its style
  /// reads any; null otherwise.
  final GlobalStateFamily? _family;

  const Theme({required this.id, required this.layers})
      : globalState = const {},
        _family = null;

  /// A theme read by `ThemeReader` from a style that reads global state.
  @internal
  const Theme.withFamily({
    required this.id,
    required this.layers,
    required this.globalState,
    required GlobalStateFamily family,
  }) : _family = family;

  /// This style under another global state: [state] overrides the
  /// style's `state` defaults — keys it leaves out, or maps to null,
  /// keep their default — and every `global-state` expression reads the
  /// result.
  ///
  /// The state is compiled in, so a theme is never re-evaluated when it
  /// changes: a different state is a different theme, with its own id
  /// (the default state keeps this style's plain id). Asking for a state
  /// again returns the same instance — recent ones are kept — so it is
  /// safe to call in `build`:
  ///
  /// ```dart
  /// VectorTileLayer(
  ///   theme: style.theme.withGlobalState({'showTrails': showTrails}),
  ///   ...
  /// )
  /// ```
  ///
  /// `VectorTileLayer` redraws its tiles from the data it already holds
  /// when the new theme is a sibling of the old one, without reloading
  /// anything. A style that reads no global state returns itself: no
  /// state can change how it draws.
  Theme withGlobalState(Map<String, Object?> state) =>
      _family?.themeFor(state) ?? this;

  /// Whether [other] is this style under another global state, so the
  /// two differ in nothing but what their expressions compute: the same
  /// layers and sources, reading the same feature properties.
  @internal
  bool isSiblingOf(Theme other) =>
      _family != null && identical(_family, other._family);

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

/// The themes one style compiles to under different global states —
/// see [Theme.withGlobalState]. Implemented by the theme reader, which
/// owns the style document they are compiled from.
@internal
abstract interface class GlobalStateFamily {
  /// The theme for [overrides] over the style's `state` defaults.
  Theme themeFor(Map<String, Object?> overrides);
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

  /// Whether any of the layer's expressions needs the feature's geometry
  /// (`within`, `distance`), which the renderer then builds for every
  /// feature it evaluates them for. Assigned by the theme reader; false
  /// for hand-built layers, which cannot hold such expressions.
  @internal
  bool readsGeometry = false;

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
  // Paint
  final ColorProp textColor;
  final ColorProp textHaloColor;
  final DoubleProp textHaloWidth;
  final DoubleProp textOpacity;
  final DoubleProp iconOpacity;

  /// `icon-color`/`icon-halo-*` only apply to SDF sprites (see
  /// [Sprite.sdf]); ordinary sprites carry their own colours.
  final ColorProp iconColor;
  final ColorProp iconHaloColor;
  final DoubleProp iconHaloWidth;

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
  });
}
