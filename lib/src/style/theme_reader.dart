import 'dart:convert';
import 'dart:ui' show Color;

import 'package:meta/meta.dart';

import '../logger.dart';
import 'expression.dart';
import 'expression_parser.dart';
import 'filter_ids.dart';
import 'theme.dart';

/// Compiles a MapLibre/Mapbox GL style JSON document into a [Theme].
///
/// Tolerant by design: a layer that cannot be compiled is skipped with a
/// warning; unknown layer types are skipped; missing properties use spec
/// defaults. A malformed layer never fails the whole style.
class ThemeReader {
  final Logger logger;

  const ThemeReader({this.logger = const Logger.noop()});

  /// Compiles [style] under its `state` defaults. When any expression
  /// reads `global-state`, the theme keeps [style] to compile its
  /// siblings from (see [Theme.withGlobalState]), so the document must
  /// not be changed afterwards.
  Theme read(Map<String, Object?> style, {String? id}) {
    final themeId = id ?? idOf(style);
    final defaults = _stateDefaults(style['state']);
    final compiled = _compile(style, defaults, logger);
    if (!compiled.readsGlobalState) {
      return Theme(id: themeId, layers: compiled.layers);
    }
    return _GlobalStates(style, themeId, defaults).adopt(compiled.layers);
  }

  /// The id [read] gives [style] when the caller names none.
  @internal
  static String idOf(Map<String, Object?> style) =>
      '${style['name'] ?? 'style'}@${style['version'] ?? '0'}'
      '#${style['modified'] ?? ''}';

  /// The root `state` property: `{name: {"default": value}}`.
  static Map<String, Object?> _stateDefaults(Object? json) {
    if (json is! Map) return const {};
    return {
      for (final entry in json.entries)
        if (entry.key is String && entry.value is Map)
          entry.key as String: (entry.value as Map)['default'],
    };
  }

  static ({List<ThemeLayer> layers, bool readsGlobalState}) _compile(
      Map<String, Object?> style,
      Map<String, Object?> globalState,
      Logger logger) {
    final layersJson = style['layers'];
    final layers = <ThemeLayer>[];
    var readsGlobalState = false;
    if (layersJson is List) {
      for (final layerJson in layersJson) {
        if (layerJson is! Map) continue;
        final json = layerJson.cast<String, Object?>();
        try {
          final parser = ExpressionParser(globalState: globalState);
          final layer = _readLayer(json, parser, logger);
          readsGlobalState |= parser.readsGlobalState;
          if (layer != null) layers.add(layer);
        } catch (e) {
          logger.warn('skipping layer "${json['id']}": $e');
        }
      }
    }
    return (layers: layers, readsGlobalState: readsGlobalState);
  }

  static ThemeLayer? _readLayer(
      Map<String, Object?> json, ExpressionParser parser, Logger logger) {
    final type = json['type'] as String? ?? '';
    final id = json['id'] as String? ?? '';
    final layout = _map(json['layout']);
    if (layout['visibility'] == 'none') return null;

    final paint = _map(json['paint']);
    final filter = parser.parseFilter(json['filter']);
    // Sampled before anything else is parsed: the flags are sticky.
    final filterReadsZoom = parser.readsZoom;
    // A worker compiles the filter from its JSON alone, with no global
    // state and no feature geometry: only a filter reading neither
    // resolves there (see ThemeLayer.filterId).
    final filterOnWorker =
        !filterReadsZoom && !parser.readsGlobalState && !parser.readsGeometry;
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
          pattern: paint['background-pattern'] == null
              ? null
              : _string(parser, paint['background-pattern'], ''),
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
          translate: _optionalNumList(parser, paint['$prefix-translate']),
          // An extrusion has no sort key.
          sortKey: extrusion
              ? null
              : _optionalDouble(parser, layout['fill-sort-key']),
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
          translate: _optionalNumList(parser, paint['line-translate']),
          offset: _optionalDouble(parser, paint['line-offset']),
          blur: _optionalDouble(parser, paint['line-blur']),
          miterLimit: layout['line-miter-limit'] == null
              ? null
              : _double(parser, layout['line-miter-limit'], 2),
          sortKey: _optionalDouble(parser, layout['line-sort-key']),
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
          blur: _optionalDouble(parser, paint['circle-blur']),
          translate: _optionalNumList(parser, paint['circle-translate']),
          sortKey: _optionalDouble(parser, layout['circle-sort-key']),
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
          // The generic `resampling` supersedes `raster-resampling`.
          resampling:
              paint['resampling'] == null && paint['raster-resampling'] == null
                  ? null
                  : _string(
                      parser,
                      paint['resampling'] ?? paint['raster-resampling'],
                      'linear'),
        );
      case 'hillshade':
        final directions =
            _doubles(parser, paint['hillshade-illumination-direction'], 335);
        final altitudes =
            _doubles(parser, paint['hillshade-illumination-altitude'], 45);
        final shadows = _colors(
            parser, paint['hillshade-shadow-color'], const Color(0xff000000));
        final highlights = _colors(parser, paint['hillshade-highlight-color'],
            const Color(0xffffffff));
        final lights = [
          directions.length,
          altitudes.length,
          shadows.length,
          highlights.length,
        ].reduce((a, b) => a > b ? a : b);
        if (lights > HillshadeThemeLayer.maxLights) {
          logger.warn('layer "$id": $lights light sources, only the first '
              '${HillshadeThemeLayer.maxLights} are drawn');
        }
        layer = HillshadeThemeLayer(
          id: id,
          source: source,
          minzoom: minzoom,
          maxzoom: maxzoom,
          filter: filter,
          method: _string(parser, paint['hillshade-method'], 'standard'),
          directions: directions,
          altitudes: altitudes,
          anchor: _string(
              parser, paint['hillshade-illumination-anchor'], 'viewport'),
          exaggeration: _double(parser, paint['hillshade-exaggeration'], 0.5),
          shadowColors: shadows,
          highlightColors: highlights,
          accentColor: _color(
              parser, paint['hillshade-accent-color'], const Color(0xff000000)),
          resampling: _string(parser, paint['resampling'], 'linear'),
        );
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
    if (filterOnWorker && layer.sourceLayer != null) {
      layer.filterId = FilterIds.intern(json['filter']);
    }
    layer.readsGeometry = parser.readsGeometry;
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

  /// A number property that is null when the style leaves it unset, for
  /// properties whose default the renderer handles by doing nothing.
  static DoubleProp? _optionalDouble(ExpressionParser parser, Object? json) =>
      json == null ? null : _double(parser, json, 0);

  /// [_optionalDouble] for the `[x, y]` translate properties.
  static NumListProp? _optionalNumList(ExpressionParser parser, Object? json) =>
      json == null ? null : _numList(parser, json, const [0, 0]);

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

  /// A `numberArray` property — one number, or a literal array of them
  /// (one per light of a multidirectional hillshade). Never empty.
  static List<DoubleProp> _doubles(
      ExpressionParser parser, Object? json, double fallback) {
    if (json is List && json.isNotEmpty && json.every((e) => e is num)) {
      return [for (final e in json) DoubleProp.constant((e as num).toDouble())];
    }
    return [_double(parser, json, fallback)];
  }

  /// A `colorArray` property — one colour, or a literal array of colour
  /// strings. Never empty.
  static List<ColorProp> _colors(
      ExpressionParser parser, Object? json, Color fallback) {
    if (json is List &&
        json.isNotEmpty &&
        !ExpressionParser.operators.contains(json.first) &&
        json.every((e) => e is String && toColor(e) != null)) {
      return [for (final e in json) ColorProp.constant(toColor(e)!)];
    }
    return [_color(parser, json, fallback)];
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

/// One style's themes under different global states. Compiling a
/// sibling re-reads the style document with the new state — under a
/// millisecond for a full basemap on a phone — and every visible tile
/// is then drawn again, so recent ones are kept: asking
/// for a state again, as a `build` method does on every rebuild,
/// returns the same instance and so does not redraw anything.
final class _GlobalStates implements GlobalStateFamily {
  _GlobalStates(this._style, this._baseId, this._defaults);

  final Map<String, Object?> _style;
  final String _baseId;
  final Map<String, Object?> _defaults;

  /// By canonical state, least recently used first.
  final _themes = <String, Theme>{};
  static const _keep = 8;

  /// The theme for the default state, from layers [ThemeReader.read]
  /// already compiled.
  Theme adopt(List<ThemeLayer> layers) {
    final key = _key(_defaults);
    return _themes[key] = Theme.withFamily(
      id: _baseId,
      layers: layers,
      globalState: Map.unmodifiable(_defaults),
      family: this,
    );
  }

  @override
  Theme themeFor(Map<String, Object?> overrides) {
    final state = {..._defaults};
    overrides.forEach((name, value) {
      if (value != null) state[name] = value;
    });
    final key = _key(state);
    final cached = _themes.remove(key);
    if (cached != null) return _themes[key] = cached;
    // The default state compiled once already and logged whatever the
    // style does not support; its siblings would only repeat it.
    final compiled = ThemeReader._compile(_style, state, const Logger.noop());
    final theme = Theme.withFamily(
      id: key == _key(_defaults) ? _baseId : '$_baseId|state=$key',
      layers: compiled.layers,
      globalState: Map.unmodifiable(state),
      family: this,
    );
    _themes[key] = theme;
    if (_themes.length > _keep) _themes.remove(_themes.keys.first);
    return theme;
  }

  /// [state] as JSON with sorted keys, so equal states share a key.
  static String _key(Object? state) =>
      jsonEncode(_sorted(state), toEncodable: (Object? v) => v.toString());

  static Object? _sorted(Object? v) => switch (v) {
        final Map<Object?, Object?> m => {
            for (final k in (m.keys.map((k) => '$k').toList()..sort()))
              k: _sorted(m[k]),
          },
        final List<Object?> l => [for (final e in l) _sorted(e)],
        _ => v,
      };
}
