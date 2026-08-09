import 'dart:ui' show Color;

import '../logger.dart';
import 'expression.dart';
import 'expression_parser.dart';
import 'theme.dart';

/// Compiles a MapLibre/Mapbox GL style JSON document into a [Theme].
///
/// Tolerant by design: a layer that cannot be compiled is skipped with a
/// warning; unknown layer types are skipped; missing properties use spec
/// defaults. A malformed layer never fails the whole style.
class ThemeReader {
  final Logger logger;

  const ThemeReader({this.logger = const Logger.noop()});

  Theme read(Map<String, Object?> style, {String? id}) {
    final themeId = id ??
        '${style['name'] ?? 'style'}@${style['version'] ?? '0'}'
            '#${style['modified'] ?? ''}';
    final layersJson = style['layers'];
    final layers = <ThemeLayer>[];
    if (layersJson is List) {
      for (final layerJson in layersJson) {
        if (layerJson is! Map) continue;
        final json = layerJson.cast<String, Object?>();
        try {
          final layer = _readLayer(json);
          if (layer != null) layers.add(layer);
        } catch (e) {
          logger.warn('skipping layer "${json['id']}": $e');
        }
      }
    }
    return Theme(id: themeId, layers: layers);
  }

  ThemeLayer? _readLayer(Map<String, Object?> json) {
    final type = json['type'] as String? ?? '';
    final id = json['id'] as String? ?? '';
    final layout = _map(json['layout']);
    if (layout['visibility'] == 'none') return null;

    final paint = _map(json['paint']);
    final parser = ExpressionParser();
    final filter = parser.parseFilter(json['filter']);
    final minzoom = toNumber(json['minzoom']) ?? 0;
    final maxzoom = toNumber(json['maxzoom']) ?? 24;
    final source = json['source'] as String?;
    final sourceLayer = json['source-layer'] as String?;

    ThemeLayer? layer;
    switch (type) {
      case 'background':
        layer = BackgroundThemeLayer(
          id: id,
          minzoom: minzoom,
          maxzoom: maxzoom,
          filter: filter,
          color: _color(
              parser, paint['background-color'], const Color(0xff000000)),
          opacity: _double(parser, paint['background-opacity'], 1),
        );
      case 'fill':
      case 'fill-extrusion':
        final prefix = type == 'fill-extrusion' ? 'fill-extrusion' : 'fill';
        layer = FillThemeLayer(
          id: id,
          source: source,
          sourceLayer: sourceLayer,
          minzoom: minzoom,
          maxzoom: maxzoom,
          filter: filter,
          color:
              _color(parser, paint['$prefix-color'], const Color(0xff000000)),
          opacity: _double(parser, paint['$prefix-opacity'], 1),
          outlineColor: paint['fill-outline-color'] == null
              ? null
              : _color(
                  parser, paint['fill-outline-color'], const Color(0x00000000)),
          antialias: paint['fill-antialias'] != false,
          pattern: paint['$prefix-pattern'] == null
              ? null
              : _string(parser, paint['$prefix-pattern'], ''),
        );
      case 'line':
        layer = LineThemeLayer(
          id: id,
          source: source,
          sourceLayer: sourceLayer,
          minzoom: minzoom,
          maxzoom: maxzoom,
          filter: filter,
          color: _color(parser, paint['line-color'], const Color(0xff000000)),
          width: _double(parser, paint['line-width'], 1),
          opacity: _double(parser, paint['line-opacity'], 1),
          gapWidth: _double(parser, paint['line-gap-width'], 0),
          dashArray: paint['line-dasharray'] == null
              ? null
              : NumListProp(parser.parse(paint['line-dasharray']), const []),
          cap: _string(parser, layout['line-cap'], 'butt'),
          join: _string(parser, layout['line-join'], 'miter'),
          pattern: paint['line-pattern'] == null
              ? null
              : _string(parser, paint['line-pattern'], ''),
        );
      case 'circle':
        layer = CircleThemeLayer(
          id: id,
          source: source,
          sourceLayer: sourceLayer,
          minzoom: minzoom,
          maxzoom: maxzoom,
          filter: filter,
          radius: _double(parser, paint['circle-radius'], 5),
          color: _color(parser, paint['circle-color'], const Color(0xff000000)),
          opacity: _double(parser, paint['circle-opacity'], 1),
          strokeColor: _color(
              parser, paint['circle-stroke-color'], const Color(0xff000000)),
          strokeWidth: _double(parser, paint['circle-stroke-width'], 0),
          strokeOpacity: _double(parser, paint['circle-stroke-opacity'], 1),
        );
      case 'symbol':
        layer = SymbolThemeLayer(
          id: id,
          source: source,
          sourceLayer: sourceLayer,
          minzoom: minzoom,
          maxzoom: maxzoom,
          filter: filter,
          placement: _string(parser, layout['symbol-placement'], 'point'),
          sortKey: _double(parser, layout['symbol-sort-key'], 0),
          spacing: _double(parser, layout['symbol-spacing'], 250),
          textField: _string(parser, layout['text-field'], ''),
          textSize: _double(parser, layout['text-size'], 16),
          textFont: _stringList(
              parser, layout['text-font'], const ['Open Sans Regular']),
          textMaxWidth: _double(parser, layout['text-max-width'], 10),
          textLetterSpacing: _double(parser, layout['text-letter-spacing'], 0),
          textTransform: _string(parser, layout['text-transform'], 'none'),
          textAnchor: _string(parser, layout['text-anchor'], 'center'),
          textVariableAnchor: layout['text-variable-anchor'] == null
              ? null
              : _stringList(parser, layout['text-variable-anchor'], const []),
          textRadialOffset: _double(parser, layout['text-radial-offset'], 0),
          textOffset: NumListProp(
            layout['text-offset'] == null
                ? constExpr(null)
                : parser.parse(layout['text-offset']),
            const [0, 0],
          ),
          textPadding: _double(parser, layout['text-padding'], 2),
          textAllowOverlap: _bool(parser, layout['text-allow-overlap'], false),
          textOptional: _bool(parser, layout['text-optional'], false),
          textMaxAngle: _double(parser, layout['text-max-angle'], 45),
          textKeepUpright: _bool(parser, layout['text-keep-upright'], true),
          textRotationAlignment:
              _string(parser, layout['text-rotation-alignment'], 'auto'),
          iconImage: layout['icon-image'] == null
              ? null
              : _string(parser, layout['icon-image'], ''),
          iconSize: _double(parser, layout['icon-size'], 1),
          iconAnchor: _string(parser, layout['icon-anchor'], 'center'),
          iconOffset: NumListProp(
            layout['icon-offset'] == null
                ? constExpr(null)
                : parser.parse(layout['icon-offset']),
            const [0, 0],
          ),
          iconAllowOverlap: _bool(parser, layout['icon-allow-overlap'], false),
          textColor:
              _color(parser, paint['text-color'], const Color(0xff000000)),
          textHaloColor:
              _color(parser, paint['text-halo-color'], const Color(0x00000000)),
          textHaloWidth: _double(parser, paint['text-halo-width'], 0),
          textOpacity: _double(parser, paint['text-opacity'], 1),
          iconOpacity: _double(parser, paint['icon-opacity'], 1),
          iconColor:
              _color(parser, paint['icon-color'], const Color(0xff000000)),
          iconHaloColor:
              _color(parser, paint['icon-halo-color'], const Color(0x00000000)),
          iconHaloWidth: _double(parser, paint['icon-halo-width'], 0),
        );
      case 'raster':
        layer = RasterThemeLayer(
          id: id,
          source: source,
          minzoom: minzoom,
          maxzoom: maxzoom,
          filter: filter,
          opacity: _double(parser, paint['raster-opacity'], 1),
          brightnessMin: _double(parser, paint['raster-brightness-min'], 0),
          brightnessMax: _double(parser, paint['raster-brightness-max'], 1),
          contrast: _double(parser, paint['raster-contrast'], 0),
          saturation: _double(parser, paint['raster-saturation'], 0),
          hueRotate: _double(parser, paint['raster-hue-rotate'], 0),
        );
      case 'hillshade':
      case 'heatmap':
      case 'sky':
        logger.log('layer "$id": type "$type" not supported, skipped');
        return null;
      default:
        logger.warn('layer "$id": unknown type "$type", skipped');
        return null;
    }

    for (final warning in parser.warnings) {
      logger.warn('layer "$id": $warning');
    }
    if (layer is! BackgroundThemeLayer) {
      layer.referencedProperties =
          parser.referencesAllProperties ? null : parser.referencedProperties;
    }
    return layer;
  }

  static Map<String, Object?> _map(Object? v) =>
      v is Map ? v.cast<String, Object?>() : const {};

  static DoubleProp _double(
      ExpressionParser parser, Object? json, double fallback) {
    if (json == null) return DoubleProp.constant(fallback);
    if (json is num) return DoubleProp.constant(json.toDouble());
    return DoubleProp(parser.parse(json), fallback);
  }

  static ColorProp _color(
      ExpressionParser parser, Object? json, Color fallback) {
    if (json == null) return ColorProp.constant(fallback);
    if (json is String) {
      final parsed = toColor(json);
      if (parsed != null) return ColorProp.constant(parsed);
    }
    return ColorProp(parser.parse(json), fallback);
  }

  static StringProp _string(
      ExpressionParser parser, Object? json, String fallback) {
    if (json == null) return StringProp.constant(fallback);
    if (json is String && !json.contains('{')) {
      return StringProp.constant(json);
    }
    if (json is String) {
      // Legacy token syntax: "{name} ({ref})".
      return StringProp(_tokenExpr(parser, json), fallback);
    }
    return StringProp(parser.parse(json), fallback);
  }

  /// String-array layout properties (font stacks, anchor lists): a bare
  /// array of strings whose head is not an expression operator is a
  /// literal value, not an expression.
  static StringListProp _stringList(
      ExpressionParser parser, Object? json, List<String> fallback) {
    if (json == null) return StringListProp(constExpr(null), fallback);
    if (json is List &&
        json.isNotEmpty &&
        json.every((e) => e is String) &&
        !ExpressionParser.operators.contains(json.first)) {
      final list = json.cast<String>();
      return StringListProp((_) => list, list);
    }
    return StringListProp(parser.parse(json), fallback);
  }

  static BoolProp _bool(ExpressionParser parser, Object? json, bool fallback) {
    if (json == null) return BoolProp.constant(fallback);
    if (json is bool) return BoolProp.constant(json);
    return BoolProp(parser.parse(json), fallback);
  }

  /// Compiles legacy `{token}` templates used by text-field/icon-image.
  static Expr _tokenExpr(ExpressionParser parser, String template) {
    final pattern = RegExp(r'\{([^{}]+)\}');
    final matches = pattern.allMatches(template).toList();
    if (matches.isEmpty) return (_) => template;
    for (final m in matches) {
      parser.referencedProperties.add(m.group(1)!);
    }
    return (ctx) => template.replaceAllMapped(
          pattern,
          (m) => toStringValue(ctx.properties[m.group(1)]),
        );
  }
}
