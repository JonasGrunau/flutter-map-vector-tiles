import 'dart:ui' show Color;

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

  ThemeLayer({
    required this.id,
    required this.source,
    required this.sourceLayer,
    required this.minzoom,
    required this.maxzoom,
    required this.filter,
    this.referencedProperties,
  });

  /// Style zoom range check. Per spec, maxzoom is exclusive-ish (a layer
  /// with maxzoom 14 disappears at zoom >= 14); minzoom inclusive.
  bool coversZoom(double zoom) => zoom >= minzoom && zoom < maxzoom;

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
  });
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
  final StringProp? iconImage;
  final DoubleProp iconSize;
  final StringProp iconAnchor;
  final NumListProp iconOffset; // px
  final BoolProp iconAllowOverlap;
  // Paint
  final ColorProp textColor;
  final ColorProp textHaloColor;
  final DoubleProp textHaloWidth;
  final DoubleProp textOpacity;
  final DoubleProp iconOpacity;

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
    required this.iconImage,
    required this.iconSize,
    required this.iconAnchor,
    required this.iconOffset,
    required this.iconAllowOverlap,
    required this.textColor,
    required this.textHaloColor,
    required this.textHaloWidth,
    required this.textOpacity,
    required this.iconOpacity,
  });
}
