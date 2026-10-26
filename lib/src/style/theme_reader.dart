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
    // Sampled before anything else is parsed: the flag is sticky.
    final filterReadsZoom = parser.readsZoom;
    final minzoom = toNumber(json['minzoom']) ?? ThemeLayer.defaultMinzoom;
    final maxzoom = toNumber(json['maxzoom']) ?? ThemeLayer.defaultMaxzoom;
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
        final extrusion = type == 'fill-extrusion';
        final prefix = extrusion ? 'fill-extrusion' : 'fill';
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
          // An extrusion has no outline property.
          outlineColor: extrusion || paint['fill-outline-color'] == null
              ? null
              : _color(
                  parser, paint['fill-outline-color'], const Color(0x00000000)),
          antialias: paint['fill-antialias'] != false,
          pattern: paint['$prefix-pattern'] == null
              ? null
              : _string(parser, paint['$prefix-pattern'], ''),
          extrusion: extrusion,
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
              : _numList(parser, paint['line-dasharray'], const []),
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
          textField: _tokenString(parser, layout['text-field'], ''),
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
          textOffset: _numList(parser, layout['text-offset'], const [0, 0]),
          textPadding: _double(parser, layout['text-padding'], 2),
          textAllowOverlap: _bool(parser, layout['text-allow-overlap'], false),
          textOptional: _bool(parser, layout['text-optional'], false),
          textMaxAngle: _double(parser, layout['text-max-angle'], 45),
          textKeepUpright: _bool(parser, layout['text-keep-upright'], true),
          textRotationAlignment:
              _string(parser, layout['text-rotation-alignment'], 'auto'),
          iconImage: layout['icon-image'] == null
              ? null
              : _tokenString(parser, layout['icon-image'], ''),
          iconSize: _double(parser, layout['icon-size'], 1),
          iconAnchor: _string(parser, layout['icon-anchor'], 'center'),
          iconOffset: _numList(parser, layout['icon-offset'], const [0, 0]),
          iconAllowOverlap: _bool(parser, layout['icon-allow-overlap'], false),
          iconRotate: _double(parser, layout['icon-rotate'], 0),
          iconRotationAlignment:
              _string(parser, layout['icon-rotation-alignment'], 'auto'),
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
          textJustify: _string(parser, layout['text-justify'], 'center'),
          textLineHeight: _double(parser, layout['text-line-height'], 1.2),
          textRotate: _double(parser, layout['text-rotate'], 0),
          textVariableAnchorOffset: layout['text-variable-anchor-offset'] ==
                  null
              ? null
              : _anchorOffsets(parser, layout['text-variable-anchor-offset']),
          textIgnorePlacement:
              _bool(parser, layout['text-ignore-placement'], false),
          iconIgnorePlacement:
              _bool(parser, layout['icon-ignore-placement'], false),
          textOverlap: layout['text-overlap'] == null
              ? null
              : _string(parser, layout['text-overlap'], 'never'),
          iconOverlap: layout['icon-overlap'] == null
              ? null
              : _string(parser, layout['icon-overlap'], 'never'),
          iconOptional: _bool(parser, layout['icon-optional'], false),
          iconPadding: _padding(parser, layout['icon-padding'], const [2]),
          iconTextFit: _string(parser, layout['icon-text-fit'], 'none'),
          iconTextFitPadding: _numList(
              parser, layout['icon-text-fit-padding'], const [0, 0, 0, 0]),
          iconKeepUpright: _bool(parser, layout['icon-keep-upright'], false),
          symbolZOrder: _string(parser, layout['symbol-z-order'], 'auto'),
          symbolAvoidEdges: _bool(parser, layout['symbol-avoid-edges'], false),
          textHaloBlur: _double(parser, paint['text-halo-blur'], 0),
          textTranslate:
              _numList(parser, paint['text-translate'], const [0, 0]),
          textTranslateAnchor:
              _string(parser, paint['text-translate-anchor'], 'map'),
          iconTranslate:
              _numList(parser, paint['icon-translate'], const [0, 0]),
          iconTranslateAnchor:
              _string(parser, paint['icon-translate-anchor'], 'map'),
          iconHaloBlur: _double(parser, paint['icon-halo-blur'], 0),
        );
        if (layout['text-writing-mode'] != null) {
          // Vertical CJK layout needs per-glyph vertical metrics that
          // Flutter's paragraph layout does not offer; the text is laid
          // out horizontally, as for a style without the property.
          logger.log('layer "$id": text-writing-mode not supported, '
              'text is laid out horizontally');
        }
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
    layer.filterReadsZoom = filterReadsZoom;
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
    final p = parser.parseForProperty(json);
    return DoubleProp(p.expr, fallback, zoomOnly: p.zoomOnly);
  }

  static ColorProp _color(
      ExpressionParser parser, Object? json, Color fallback) {
    if (json == null) return ColorProp.constant(fallback);
    if (json is String) {
      final parsed = toColor(json);
      if (parsed != null) return ColorProp.constant(parsed);
    }
    final p = parser.parseForProperty(json);
    return ColorProp(p.expr, fallback, zoomOnly: p.zoomOnly);
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
    final p = parser.parseForProperty(json);
    return StringProp(p.expr, fallback, zoomOnly: p.zoomOnly);
  }

  /// `text-field` / `icon-image` — the two properties whose spec
  /// declares `tokens`. Beyond a bare template string, MapLibre also
  /// expands `{token}`s in the string outputs of a legacy stop function
  /// (`{"stops": [[14, "{name:latin}\n{name:nonlatin}"]]}`) and in its
  /// `default`; without that the template itself was drawn as the label
  /// text for the stops that used one.
  static StringProp _tokenString(
      ExpressionParser parser, Object? json, String fallback) {
    final stops = json is Map ? json['stops'] : null;
    if (stops is! List) return _string(parser, json, fallback);
    final templates = <String, Expr>{};
    for (final stop in stops) {
      if (stop is List &&
          stop.length >= 2 &&
          stop[1] is String &&
          (stop[1] as String).contains('{')) {
        final template = stop[1] as String;
        templates[template] ??= _tokenExpr(parser, template);
      }
    }
    final defaultValue = (json as Map)['default'];
    if (defaultValue is String && defaultValue.contains('{')) {
      templates[defaultValue] ??= _tokenExpr(parser, defaultValue);
    }
    final p = parser.parseForProperty(json);
    if (templates.isEmpty) {
      return StringProp(p.expr, fallback, zoomOnly: p.zoomOnly);
    }
    final select = p.expr;
    return StringProp((ctx) {
      final v = select(ctx);
      final template = v is String ? templates[v] : null;
      return template == null ? v : template(ctx);
    }, fallback);
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
      return StringListProp.constant(json.cast<String>());
    }
    final p = parser.parseForProperty(json);
    return StringListProp(p.expr, fallback, zoomOnly: p.zoomOnly);
  }

  /// Numeric-array properties (text-offset, icon-offset, dash arrays):
  /// a bare array of numbers is a literal value, pre-converted once.
  static NumListProp _numList(
      ExpressionParser parser, Object? json, List<double> fallback) {
    if (json == null) return NumListProp(constExpr(null), fallback);
    if (json is List && json.isNotEmpty && json.every((e) => e is num)) {
      return NumListProp.constant(
          [for (final e in json) (e as num).toDouble()]);
    }
    final p = parser.parseForProperty(json);
    return NumListProp(p.expr, fallback, zoomOnly: p.zoomOnly);
  }

  /// `padding` properties: one to four numbers, and a bare number for
  /// all four sides alike — literal or from an expression.
  static NumListProp _padding(
      ExpressionParser parser, Object? json, List<double> fallback) {
    if (json is num) return NumListProp.constant([json.toDouble()]);
    if (json == null || json is List && json.every((e) => e is num)) {
      return _numList(parser, json, fallback);
    }
    final p = parser.parseForProperty(json);
    final expr = p.expr;
    return NumListProp((ctx) {
      final v = expr(ctx);
      return v is num ? [v] : v;
    }, fallback, zoomOnly: p.zoomOnly);
  }

  /// `text-variable-anchor-offset`: a bare array whose head is an anchor
  /// name rather than an operator is a literal collection.
  static AnchorOffsetsProp _anchorOffsets(
      ExpressionParser parser, Object? json) {
    if (json is List &&
        json.isNotEmpty &&
        json.first is String &&
        !ExpressionParser.operators.contains(json.first)) {
      final literal = AnchorOffsetsProp.parse(json);
      if (literal != null) return AnchorOffsetsProp.constant(literal);
    }
    final p = parser.parseForProperty(json);
    return AnchorOffsetsProp(p.expr, zoomOnly: p.zoomOnly);
  }

  static BoolProp _bool(ExpressionParser parser, Object? json, bool fallback) {
    if (json == null) return BoolProp.constant(fallback);
    if (json is bool) return BoolProp.constant(json);
    final p = parser.parseForProperty(json);
    return BoolProp(p.expr, fallback, zoomOnly: p.zoomOnly);
  }

  /// Compiles legacy `{token}` templates used by text-field/icon-image.
  /// The template is split once at parse time; evaluation concatenates
  /// literal and property segments without regex machinery — this runs
  /// per symbol feature at tile prep in essentially every style.
  static Expr _tokenExpr(ExpressionParser parser, String template) {
    final pattern = RegExp(r'\{([^{}]+)\}');
    final matches = pattern.allMatches(template).toList();
    if (matches.isEmpty) return (_) => template;
    for (final m in matches) {
      parser.noteFeatureProperty(m.group(1)!);
    }
    // "{name}" — the single most common text-field — is one property.
    if (matches.length == 1 &&
        matches.first.start == 0 &&
        matches.first.end == template.length) {
      final name = matches.first.group(1)!;
      return (ctx) => toStringValue(ctx.properties[name]);
    }
    // literals[i] precedes names[i]; literals.last trails the tokens.
    final literals = <String>[];
    final names = <String>[];
    var pos = 0;
    for (final m in matches) {
      literals.add(template.substring(pos, m.start));
      names.add(m.group(1)!);
      pos = m.end;
    }
    literals.add(template.substring(pos));
    return (ctx) {
      final sb = StringBuffer();
      for (var i = 0; i < names.length; i++) {
        sb
          ..write(literals[i])
          ..write(toStringValue(ctx.properties[names[i]]));
      }
      sb.write(literals.last);
      return sb.toString();
    };
  }
}
