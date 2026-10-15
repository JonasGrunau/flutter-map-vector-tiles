import 'expression.dart' show toColor, toNumber;

/// Rewrites a style document so its labels prefer a translation into
/// [language] — what `StyleReader.language` applies before the style is
/// compiled. Pure JSON in, JSON out: the theme reader and expression
/// parser never learn about languages, and the property references the
/// rewrite adds are recorded by the parser like any other, so tile
/// preparation keeps the translated names without being told to.
///
/// Returns [style] itself when [language] is null or empty, or when no
/// layer depends on the language. Otherwise returns a copy that shares
/// every unchanged part with [style]; [style] is never modified.
///
/// In every layer:
///
/// - a symbol layer's `text-field` goes through [localizeTextField];
/// - `["resolved-locale", …]` becomes `["literal", language]` wherever
///   it appears, filters included — it is the expression that asks for
///   the language. Without a language the parser keeps answering `en`.
Map<String, Object?> localizeStyle(
  Map<String, Object?> style,
  String? language,
) {
  if (language == null || language.isEmpty) return style;
  final layers = style['layers'];
  if (layers is! List) return style;
  List<Object?>? localized;
  for (var i = 0; i < layers.length; i++) {
    final layer = layers[i];
    if (layer is! Map) continue;
    final rewritten = _localizeLayer(layer, language);
    if (rewritten != null) (localized ??= List.of(layers))[i] = rewritten;
  }
  return localized == null ? style : {...style, 'layers': localized};
}

/// Makes a `text-field` value prefer the [language] translation of the
/// name it shows, keeping the original as the fallback for features
/// without one.
///
/// The smallest subexpression holding every name reference — `name`,
/// `name:*` or `name_*` read with `get` — is wrapped as
///
/// ```json
/// ["coalesce", ["get", "name:de"], ["get", "name_de"], <original>]
/// ```
///
/// since OpenMapTiles-schema tiles (MapTiler, OpenFreeMap) tag
/// translations `name:xx`, and Mapbox Streets and Shortbread `name_xx`.
/// Wrapping that subexpression, rather than the whole field or each
/// reference on its own:
///
/// - keeps what a style shows beside the name — a peak's elevation, a
///   road's `({ref})` — which wrapping the whole field would drop;
/// - shows the translation once where a style combines several name
///   variants, as OpenMapTiles styles do with `name:latin` and
///   `name:nonlatin`, which wrapping each reference would show twice.
///
/// Inside a `concat`, only the contiguous run of arguments spanning the
/// name references is wrapped, for the first reason. Only references
/// whose value can reach the label count: a name tested in a `case`
/// condition, matched by `match`, compared, measured or checked with
/// `has` stays as it is, and so does everything else outside the
/// wrapped subexpression.
///
/// Legacy `{token}` templates and zoom stop functions over them become
/// the equivalent `concat` and `step` expressions first, but only when
/// they reference a name. Data-driven stop functions (`property`) are
/// left alone.
///
/// Returns [field] itself when it references no name.
Object? localizeTextField(Object? field, String language) {
  final Object? expression;
  if (field is String) {
    expression = _templateExpression(field);
  } else if (field is Map) {
    expression = _zoomFunctionExpression(field);
    if (expression == null) return field;
  } else {
    expression = field;
  }
  if (expression is! List || _nameRefs(expression) == 0) return field;
  return _wrapSmallest(expression, language);
}

Map<String, Object?>? _localizeLayer(
  Map<Object?, Object?> layer,
  String language,
) {
  Map<String, Object?>? out;
  for (final key in const ['filter', 'layout', 'paint']) {
    final value = layer[key];
    final folded = _foldLocale(value, language);
    if (!identical(folded, value)) {
      (out ??= {...layer.cast<String, Object?>()})[key] = folded;
    }
  }
  if (layer['type'] == 'symbol') {
    final layout = (out ?? layer)['layout'];
    if (layout is Map && layout.containsKey('text-field')) {
      final field = layout['text-field'];
      final localized = localizeTextField(field, language);
      if (!identical(localized, field)) {
        (out ??= {...layer.cast<String, Object?>()})['layout'] = {
          ...layout.cast<String, Object?>(),
          'text-field': localized,
        };
      }
    }
  }
  return out;
}

/// [json] with every `resolved-locale` expression replaced by
/// [language], or [json] itself when it has none.
Object? _foldLocale(Object? json, String language) {
  if (json is List) {
    if (json.isEmpty || json.first == 'literal') return json;
    if (json.first == 'resolved-locale') return ['literal', language];
    List<Object?>? out;
    for (var i = 0; i < json.length; i++) {
      final folded = _foldLocale(json[i], language);
      if (!identical(folded, json[i])) (out ??= List.of(json))[i] = folded;
    }
    return out ?? json;
  }
  if (json is Map) {
    Map<Object?, Object?>? out;
    for (final entry in json.entries) {
      final folded = _foldLocale(entry.value, language);
      if (!identical(folded, entry.value)) {
        (out ??= Map.of(json))[entry.key] = folded;
      }
    }
    return out ?? json;
  }
  return json;
}

bool _isNameKey(Object? key) =>
    key is String &&
    (key == 'name' || key.startsWith('name:') || key.startsWith('name_'));

bool _isNameGet(List<Object?> e) =>
    e.length == 2 && e[0] == 'get' && _isNameKey(e[1]);

/// How many name references in [e] can reach its value.
int _nameRefs(Object? e) {
  if (e is! List || e.isEmpty) return 0;
  if (_isNameGet(e)) return 1;
  var refs = 0;
  for (final i in _valueArgs(e)) {
    refs += _nameRefs(e[i]);
  }
  return refs;
}

/// The argument indices of expression [e] whose value can become part of
/// [e]'s own value — the only places a name reference ends up in the
/// label. Conditions, match inputs and labels, ramp inputs and stops are
/// not among them, nor is anything under an operator not listed here
/// (comparisons, `has`, `length`, arithmetic, …).
Iterable<int> _valueArgs(List<Object?> e) sync* {
  final n = e.length;
  switch (e.first) {
    case 'coalesce' ||
          'concat' ||
          'format' ||
          'upcase' ||
          'downcase' ||
          'to-string' ||
          'string':
      for (var i = 1; i < n; i++) {
        yield i;
      }
    case 'slice':
      if (n > 1) yield 1;
    case 'case':
      // ["case", condition, output, …, fallback]
      for (var i = 2; i < n; i += 2) {
        yield i;
      }
      if (n.isEven) yield n - 1;
    case 'match':
      // ["match", input, label, output, …, fallback]
      for (var i = 3; i < n; i += 2) {
        yield i;
      }
      if (n.isOdd && n > 2) yield n - 1;
    case 'step':
      // ["step", input, output, stop, output, …]
      for (var i = 2; i < n; i += 2) {
        yield i;
      }
    case 'interpolate' || 'interpolate-hcl' || 'interpolate-lab':
      // ["interpolate", type, input, stop, output, …]
      for (var i = 4; i < n; i += 2) {
        yield i;
      }
    case 'let':
      // ["let", name, value, …, body]
      for (var i = 2; i < n - 1; i += 2) {
        yield i;
      }
      if (n > 1) yield n - 1;
  }
}

/// Wraps the smallest subexpression of [e] that holds all of [e]'s name
/// references (at least one).
List<Object?> _wrapSmallest(List<Object?> e, String language) {
  if (_isNameGet(e)) return _preferTranslation(e, language);
  final holding = [
    for (final i in _valueArgs(e))
      if (_nameRefs(e[i]) > 0) i,
  ];
  if (holding.length == 1) {
    final i = holding.single;
    return List.of(e)..[i] = _wrapSmallest(e[i]! as List<Object?>, language);
  }
  final first = holding.first;
  final last = holding.last;
  if (e.first == 'concat' && (first > 1 || last < e.length - 1)) {
    return [
      ...e.sublist(0, first),
      _preferTranslation(['concat', ...e.sublist(first, last + 1)], language),
      ...e.sublist(last + 1),
    ];
  }
  return _preferTranslation(e, language);
}

List<Object?> _preferTranslation(Object? original, String language) => [
      'coalesce',
      ['get', 'name:$language'],
      ['get', 'name_$language'],
      original,
    ];

final _token = RegExp(r'\{([^{}]+)\}');

/// The expression a legacy `{token}` template evaluates as in
/// `ThemeReader`: literals and property values concatenated, a missing
/// property contributing nothing. A string without tokens is returned
/// as is.
Object? _templateExpression(String template) {
  final matches = _token.allMatches(template).toList();
  if (matches.isEmpty) return template;
  final parts = <Object?>[];
  var pos = 0;
  for (final m in matches) {
    if (m.start > pos) parts.add(template.substring(pos, m.start));
    parts.add(['get', m.group(1)]);
    pos = m.end;
  }
  if (pos < template.length) parts.add(template.substring(pos));
  return parts.length == 1 ? parts.single : ['concat', ...parts];
}

/// The `step` expression a legacy zoom stop function over strings
/// (`{"stops": [[2, "{ref}"], [6, "{name}"]]}`) evaluates as, its
/// templates converted by [_templateExpression]; null for anything else.
///
/// The parser holds each stop's output until the next stop, and the
/// first one below it — which is what `step` does — except where an
/// exponential function (the default type) meets two neighbouring outputs
/// that both read as numbers or both as colours (`"1"`, `"2"`): those it
/// interpolates, so such a function stays as it is. Its `default` never
/// applies: the zoom is always a number.
Object? _zoomFunctionExpression(Map<Object?, Object?> function) {
  if (function.containsKey('property')) return null;
  final type = function['type'];
  if (type != null && type != 'exponential' && type != 'interval') {
    return null;
  }
  final stops = function['stops'];
  if (stops is! List || stops.isEmpty) return null;
  final step = <Object?>[
    'step',
    ['zoom'],
  ];
  String? previous;
  for (var i = 0; i < stops.length; i++) {
    final stop = stops[i];
    if (stop is! List || stop.length < 2 || stop[0] is! num) return null;
    final output = stop[1];
    if (output is! String) return null;
    if (type != 'interval' &&
        previous != null &&
        ((toNumber(previous) != null && toNumber(output) != null) ||
            (toColor(previous) != null && toColor(output) != null))) {
      return null;
    }
    previous = output;
    if (i > 0) step.add(stop[0]);
    step.add(_templateExpression(output));
  }
  return step.length == 3 ? step[2] : step;
}
