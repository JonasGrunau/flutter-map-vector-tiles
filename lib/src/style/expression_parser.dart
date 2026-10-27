import 'dart:math' as math;
import 'dart:ui' show Color;

import 'expression.dart';
import 'geometry_expressions.dart';
import 'interpolation.dart';
import 'number_format.dart';

/// Compiles MapLibre style expressions (and legacy filter / function
/// syntax) into Dart closures.
///
/// The parser is deliberately tolerant: anything it cannot compile
/// becomes an expression evaluating to null (callers fall back to the
/// spec default for the property), and the problem is reported through
/// [warnings] instead of throwing. This keeps real-world styles
/// (MapTiler, ArcGIS, Protomaps, ...) rendering even when they use
/// exotic operators.
///
/// Evaluation is as strict as MapLibre's: an operand of a type the
/// operator does not take — a numeric string compared with a number, a
/// non-boolean `case` condition — makes the expression evaluate to
/// [evalError], which every operator passes on and which ends as the
/// property's fallback, or false for a filter. Where the operands'
/// types are known at parse time the check is compiled away.
class ExpressionParser {
  /// [globalState] holds the values `global-state` reads: the style's
  /// `state` defaults with any overrides applied (see
  /// `Theme.withGlobalState`). They are compiled in as constants, so an
  /// expression reading only global state stays zoom-only and a filter
  /// reading it stays cacheable — a different state is a different
  /// theme.
  ExpressionParser({Map<String, Object?> globalState = const {}})
      : _globalState = globalState;

  final Map<String, Object?> _globalState;

  /// Property names referenced via `get`/`has`/legacy filters. When an
  /// expression accesses properties dynamically, [referencesAllProperties]
  /// is set instead.
  final Set<String> referencedProperties = {};
  bool referencesAllProperties = false;
  final List<String> warnings = [];

  /// Set while parsing when the subtree read feature data (properties,
  /// feature id, geometry type) — the basis for zoom-only detection.
  bool _readsFeature = false;

  /// Whether anything parsed so far reads the zoom — `["zoom"]` anywhere,
  /// or a legacy function keyed on it. Sticky, so the theme reader
  /// samples it straight after parsing a layer's filter with a fresh
  /// parser: a filter that never reads the zoom selects the same
  /// features at every zoom, which lets the renderer resolve it once
  /// per prepared tile (see `MatchedFeatures`).
  bool get readsZoom => _readsZoom;
  bool _readsZoom = false;

  /// Whether anything parsed so far reads `global-state` — the theme
  /// reader keeps the style document only for themes where a different
  /// state can change anything.
  bool get readsGlobalState => _readsGlobalState;
  bool _readsGlobalState = false;

  /// Whether anything parsed so far needs the feature's geometry
  /// (`within`, `distance`), which the renderer then builds per feature
  /// (see `ThemeLayer.readsGeometry`).
  bool get readsGeometry => _readsGeometry;
  bool _readsGeometry = false;

  /// Parses one style property, additionally reporting whether the
  /// compiled expression is zoom-only (reads no feature data). The
  /// typed property wrappers memoize zoom-only results against the
  /// zoom — see `DoubleProp.zoomOnly`.
  ///
  /// [accepts] tells the values the property takes, and [enumValues]
  /// the values of an enum property. A legacy identity function hands
  /// on only those, and its `default` (or null) for any other feature
  /// value, as MapLibre does — which holds an enum property to its
  /// values only when the function has a default, and otherwise takes
  /// any string.
  ({Expr expr, bool zoomOnly}) parseForProperty(Object? json,
      {bool Function(Object? value)? accepts, Set<String>? enumValues}) {
    final saved = _readsFeature;
    _readsFeature = false;
    final expr = json is Map
        ? _parseLegacyFunction(
            json.cast<String, Object?>(),
            json['default'] != null && enumValues != null
                ? enumValues.contains
                : accepts)
        : parse(json);
    final zoomOnly = !_readsFeature;
    _readsFeature = saved || _readsFeature;
    return (expr: expr, zoomOnly: zoomOnly);
  }

  /// Records a feature-property reference discovered outside the
  /// parser (legacy `{token}` templates in the theme reader).
  void noteFeatureProperty(String name) {
    referencedProperties.add(name);
    _readsFeature = true;
  }

  /// Every operator [_parseOp] understands. Used to disambiguate literal
  /// string arrays (`['top', 'bottom']`, font stacks) from expressions.
  static const operators = {
    'literal',
    'get',
    'has',
    'properties',
    'id',
    'geometry-type',
    'zoom',
    'global-state',
    'let',
    'var',
    '!',
    '==',
    '!=',
    '<',
    '<=',
    '>',
    '>=',
    'all',
    'any',
    'case',
    'match',
    'coalesce',
    'within',
    'distance',
    'step',
    'interpolate',
    'interpolate-hcl',
    'interpolate-lab',
    'in',
    'index-of',
    'at',
    'slice',
    'length',
    'to-string',
    'to-number',
    'to-boolean',
    'to-color',
    'typeof',
    'string',
    'number',
    'boolean',
    'object',
    'array',
    'semiliteral',
    'image',
    'format',
    'number-format',
    'concat',
    'join',
    'split',
    'upcase',
    'downcase',
    'is-supported-script',
    'resolved-locale',
    'collator',
    'rgb',
    'rgba',
    'to-rgba',
    '+',
    '*',
    '-',
    '/',
    '%',
    '^',
    'abs',
    'ceil',
    'floor',
    'round',
    'sqrt',
    'ln',
    'log2',
    'log10',
    'sin',
    'cos',
    'tan',
    'asin',
    'acos',
    'atan',
    'min',
    'max',
    'e',
    'pi',
    'ln2',
    'feature-state',
    'heatmap-density',
    'line-progress',
    'accumulated',
    'elevation',
  };

  Expr parse(Object? json) {
    if (json == null) return (_) => null;
    if (json is num) {
      final v = json.toDouble();
      return (_) => v;
    }
    if (json is bool || json is String) return (_) => json;
    if (json is Map) return _parseLegacyFunction(json.cast<String, Object?>());
    if (json is List) {
      if (json.isEmpty) return _unsupported('empty expression');
      final op = json[0];
      // A bare array whose head is not a string (e.g. `[0, 0.6]` for
      // text-offset) is a legacy literal value, not an expression.
      if (op is! String) return (_) => json;
      return _parseOp(op, json);
    }
    return _unsupported('unrecognized expression $json');
  }

  /// Compiles a layer `filter`, handling both legacy and expression syntax.
  Expr parseFilter(Object? json) {
    if (json == null) return (_) => true;
    if (json is bool) return (_) => json;
    if (json is! List || json.isEmpty) return (_) => true;
    if (_isExpressionFilter(json)) {
      final e = parse(json);
      // A filter is a boolean: anything else, an error included, keeps
      // the feature out.
      return (ctx) => identical(e(ctx), true);
    }
    return _parseLegacyFilter(json);
  }

  Expr _unsupported(String message) {
    warnings.add(message);
    return (_) => null;
  }

  void _refProp(Object? name) {
    _readsFeature = true;
    if (name is String) {
      referencedProperties.add(name);
    } else {
      referencesAllProperties = true;
    }
  }

  // -------------------------------------------------------------------------

  Expr _parseOp(String op, List<Object?> a) {
    switch (op) {
      case 'literal':
        final v = a.length > 1 ? a[1] : null;
        return (_) => v;
      case 'get':
        if (a.length > 2) {
          // get from an object expression
          final name = parse(a[1]);
          final obj = parse(a[2]);
          return (ctx) {
            final k = name(ctx);
            final o = obj(ctx);
            return k is String && o is Map ? o[k] : evalError;
          };
        }
        _refProp(a.length > 1 ? a[1] : null);
        final key = a.length > 1 ? a[1] : null;
        // A literal key — the overwhelmingly common shape, and the
        // hottest leaf in the engine — reads the map directly instead
        // of paying an inner closure plus a type test per call.
        if (key is String) return (ctx) => ctx.properties[key];
        final keyExpr = parse(key);
        return (ctx) {
          final k = keyExpr(ctx);
          return k is String ? ctx.properties[k] : evalError;
        };
      case 'has':
        if (a.length > 2) {
          final name = parse(a[1]);
          final obj = parse(a[2]);
          return (ctx) {
            final k = name(ctx);
            final o = obj(ctx);
            return k is String && o is Map ? o.containsKey(k) : evalError;
          };
        }
        _refProp(a.length > 1 ? a[1] : null);
        final key = a.length > 1 ? a[1] : null;
        if (key is String) return (ctx) => ctx.properties.containsKey(key);
        final keyExpr = parse(key);
        return (ctx) {
          final k = keyExpr(ctx);
          return k is String ? ctx.properties.containsKey(k) : evalError;
        };
      case 'properties':
        referencesAllProperties = true;
        _readsFeature = true;
        return (ctx) => ctx.properties;
      case 'id':
        _readsFeature = true;
        return (ctx) => ctx.featureId;
      case 'geometry-type':
        _readsFeature = true;
        return (ctx) => ctx.geometryType;
      case 'zoom':
        _readsZoom = true;
        return (ctx) => ctx.zoom;
      case 'global-state':
        final name = a.length == 2 ? a[1] : null;
        if (name is! String) {
          return _unsupported('global-state needs one property name');
        }
        _readsGlobalState = true;
        final value = _globalState[name];
        return (_) => value;
      case 'let':
        return _parseLet(a);
      case 'var':
        final name = a.length > 1 ? toStringValue(a[1]) : '';
        return (ctx) => ctx.vars?[name];

      // --- decisions ---
      // Their operands are booleans: anything else is an error, not
      // truthy or falsy.
      case '!':
        final e = parse(a.length > 1 ? a[1] : null);
        return (ctx) {
          final v = e(ctx);
          return v is bool ? !v : evalError;
        };
      case '==':
      case '!=':
      case '<':
      case '<=':
      case '>':
      case '>=':
        return _parseComparison(op, a);
      // Indexed loops over fixed-length lists: a for-in pays an
      // iterator per evaluation, and these run per feature in nearly
      // every filter.
      case 'all':
        final es = a.skip(1).map(parse).toList(growable: false);
        return (ctx) {
          for (var i = 0; i < es.length; i++) {
            final v = es[i](ctx);
            if (!identical(v, true)) return identical(v, false) ? v : evalError;
          }
          return true;
        };
      case 'any':
        final es = a.skip(1).map(parse).toList(growable: false);
        return (ctx) {
          for (var i = 0; i < es.length; i++) {
            final v = es[i](ctx);
            if (!identical(v, false)) return identical(v, true) ? v : evalError;
          }
          return false;
        };
      case 'case':
        return _parseCase(a);
      case 'match':
        return _parseMatch(a);
      case 'coalesce':
        final es = a.skip(1).map(parse).toList();
        return (ctx) {
          for (final e in es) {
            final v = e(ctx);
            if (v != null) return v;
          }
          return null;
        };
      case 'within':
      case 'distance':
        return _parseGeometryOp(op, a);

      // --- ramps ---
      case 'step':
        return _parseStep(a);
      case 'interpolate':
      case 'interpolate-hcl':
      case 'interpolate-lab':
        return _parseInterpolate(op, a);

      // --- lookup ---
      case 'in':
        final needle = parse(a.length > 1 ? a[1] : null);
        final haystackJson = a.length > 2 ? a[2] : null;
        // A literal haystack (the common shape) becomes an O(1) lookup
        // over parse-time-normalized values; the needle's type is only
        // tested on a miss.
        final literal = _literalList(haystackJson);
        if (literal != null) {
          final values = {for (final e in literal) _matchKey(e)};
          return (ctx) {
            final n = needle(ctx);
            if (values.contains(_matchKey(n))) return true;
            return _isNeedle(n) ? false : evalError;
          };
        }
        final haystack = parse(haystackJson);
        return (ctx) {
          final n = needle(ctx);
          if (identical(n, evalError)) return evalError;
          final h = haystack(ctx);
          // In this order, as MapLibre tests them: a falsy haystack
          // (null, empty string, 0, false) holds nothing, before either
          // type is checked.
          if (_isFalsy(h)) return false;
          if (!_isNeedle(n)) return evalError;
          if (h is List) {
            for (var i = 0; i < h.length; i++) {
              if (_looseEquals(h[i], n)) return true;
            }
            return false;
          }
          if (h is String) return h.contains(_needleText(n));
          return evalError;
        };
      case 'index-of':
        final needle = parse(a.length > 1 ? a[1] : null);
        final haystack = parse(a.length > 2 ? a[2] : null);
        final from = a.length > 3 ? parse(a[3]) : null;
        return (ctx) {
          final n = needle(ctx);
          final h = haystack(ctx);
          if (!_isNeedle(n) || (h is! List && h is! String)) return evalError;
          final length = h is List ? h.length : (h as String).length;
          var start = 0;
          if (from != null) {
            final f = asNumber(from(ctx));
            if (f == null) return evalError;
            start = f.toInt();
          }
          if (start < 0) start = h is List ? math.max(length + start, 0) : 0;
          if (h is List) {
            for (var i = start; i < h.length; i++) {
              if (_looseEquals(h[i], n)) return i;
            }
            return -1;
          }
          final s = h as String;
          final raw = s.indexOf(_needleText(n), math.min(start, s.length));
          // Counted in characters (code points), not UTF-16 units.
          return raw < 0 ? -1 : s.substring(0, raw).runes.length;
        };
      case 'at':
        final index = parse(a.length > 1 ? a[1] : null);
        final list = parse(a.length > 2 ? a[2] : null);
        return (ctx) {
          final i = index(ctx);
          final l = list(ctx);
          // An index out of bounds, or with a fraction (NaN fails that
          // test too), is an error, not a miss.
          if (i is! num || l is! List || i < 0 || i >= l.length || i % 1 != 0) {
            return evalError;
          }
          return l[i.toInt()];
        };
      case 'slice':
        final target = parse(a.length > 1 ? a[1] : null);
        final start = parse(a.length > 2 ? a[2] : null);
        final end = a.length > 3 ? parse(a[3]) : null;
        return (ctx) {
          final t = target(ctx);
          final s = asNumber(start(ctx));
          final e = end == null ? null : asNumber(end(ctx));
          if (s == null || (end != null && e == null)) return evalError;
          if (t is String) {
            // By character (code point), so a slice never splits a
            // surrogate pair.
            final chars = t.runes.toList();
            final (from, to) = _sliceRange(chars.length, s, e);
            return String.fromCharCodes(chars, from, to);
          }
          if (t is List) {
            final (from, to) = _sliceRange(t.length, s, e);
            return t.sublist(from, to);
          }
          return evalError;
        };
      case 'length':
        final e = parse(a.length > 1 ? a[1] : null);
        return (ctx) {
          final v = e(ctx);
          if (v is String) return v.runes.length;
          if (v is List) return v.length;
          return evalError;
        };

      // --- types ---
      case 'to-string':
        final e = parse(a.length > 1 ? a[1] : null);
        return (ctx) {
          final v = e(ctx);
          return identical(v, evalError) ? v : toStringValue(v);
        };
      case 'to-number':
        final es = a.skip(1).map(parse).toList();
        return (ctx) {
          for (final e in es) {
            final v = e(ctx);
            if (identical(v, evalError)) return v;
            // Null converts, to 0; an input nothing converts falls
            // through to the next.
            if (v == null) return 0.0;
            final n = toNumber(v);
            if (n != null) return n;
          }
          return evalError;
        };
      case 'to-boolean':
        final e = parse(a.length > 1 ? a[1] : null);
        return (ctx) {
          final v = e(ctx);
          return identical(v, evalError) ? v : toBoolean(v);
        };
      case 'to-color':
        final es = a.skip(1).map(parse).toList();
        return (ctx) {
          for (final e in es) {
            final v = e(ctx);
            if (identical(v, evalError)) return v;
            final c = toColor(v);
            if (c != null) return c;
          }
          return evalError;
        };
      case 'typeof':
        final e = parse(a.length > 1 ? a[1] : null);
        return (ctx) {
          final v = e(ctx);
          return identical(v, evalError) ? v : _typeName(v);
        };
      case 'string':
      case 'number':
      case 'boolean':
      case 'object':
      case 'array':
        return _parseAssertion(op, a);
      case 'semiliteral':
        // A JSON array whose elements may be expressions.
        if (a.length != 2) {
          return _unsupported('semiliteral needs exactly one argument');
        }
        final value = a[1];
        if (value is! List) return (_) => value;
        if (!value.any((e) => e is List)) return (_) => value;
        final es = value.map(parse).toList();
        return (ctx) {
          final out = <Object?>[];
          for (final e in es) {
            final v = e(ctx);
            if (identical(v, evalError)) return v;
            out.add(v);
          }
          return out;
        };
      case 'image':
        final e = parse(a.length > 1 ? a[1] : null);
        return (ctx) {
          final v = e(ctx);
          return v is String ? v : evalError;
        };
      case 'format':
        // Rich text formatting: flatten to plain concatenated text.
        // Inline images cannot be drawn into a label; leaving them out
        // keeps their names from being drawn as text instead.
        final parts = <Object?>[
          for (var i = 1; i < a.length; i++)
            if (a[i] is! Map && !_isImage(a[i])) a[i], // overrides ignored
        ];
        return _concatExpr(parts);
      case 'number-format':
        return _parseNumberFormat(a);

      // --- strings ---
      case 'concat':
        return _concatExpr(a.skip(1).toList());
      case 'join':
        final input = parse(a.length > 1 ? a[1] : null);
        final separator = parse(a.length > 2 ? a[2] : null);
        return (ctx) {
          final v = asStringList(input(ctx));
          final s = separator(ctx);
          return v != null && s is String ? v.join(s) : evalError;
        };
      case 'split':
        final input = parse(a.length > 1 ? a[1] : null);
        final separator = parse(a.length > 2 ? a[2] : null);
        return (ctx) {
          final v = input(ctx);
          final s = separator(ctx);
          return v is String && s is String ? v.split(s) : evalError;
        };
      case 'upcase':
        final e = parse(a.length > 1 ? a[1] : null);
        return (ctx) {
          final v = e(ctx);
          return v is String ? v.toUpperCase() : evalError;
        };
      case 'downcase':
        final e = parse(a.length > 1 ? a[1] : null);
        return (ctx) {
          final v = e(ctx);
          return v is String ? v.toLowerCase() : evalError;
        };
      case 'is-supported-script':
        return (_) => true;
      case 'resolved-locale':
        // With `StyleReader.language` set, `localizeStyle` has already
        // folded this to that language; only a style read without one
        // gets here.
        return (_) => 'en';
      case 'collator':
        return (_) => null;

      // --- color ---
      case 'rgb':
      case 'rgba':
        // toColor owns the channel semantics (round, alpha default);
        // this case gathers the evaluated channels and rejects any out
        // of range, as MapLibre does, instead of clamping them.
        // All-literal channels (the typical shape, e.g. as interpolate
        // outputs) fold to a Color at parse time.
        if (a.length >= 4 && a.skip(1).every((e) => e is num)) {
          final channels = a.sublist(1);
          if (!_validRgba(channels)) {
            return _unsupported('$op channels out of range: $channels');
          }
          final c = toColor(channels);
          return (_) => c;
        }
        final es = a.skip(1).map(parse).toList();
        return (ctx) {
          final channels = [for (final e in es) e(ctx)];
          return _validRgba(channels) ? toColor(channels) : evalError;
        };
      case 'to-rgba':
        final e = parse(a.length > 1 ? a[1] : null);
        return (ctx) {
          final c = toColor(e(ctx));
          if (c == null) return evalError;
          return [c.r * 255, c.g * 255, c.b * 255, c.a];
        };

      // --- math ---
      // Operands are numbers; a numeric string is not one.
      case '+':
      case '*':
        // The operator is bound at parse time — the old form re-tested
        // the op string per operand per evaluation.
        final es = a.skip(1).map(parse).toList();
        if (op == '+') {
          return (ctx) {
            var acc = 0.0;
            for (final e in es) {
              final n = asNumber(e(ctx));
              if (n == null) return evalError;
              acc += n;
            }
            return acc;
          };
        }
        return (ctx) {
          var acc = 1.0;
          for (final e in es) {
            final n = asNumber(e(ctx));
            if (n == null) return evalError;
            acc *= n;
          }
          return acc;
        };
      case '-':
        if (a.length == 2) {
          final e = parse(a[1]);
          return (ctx) {
            final n = asNumber(e(ctx));
            return n == null ? evalError : -n;
          };
        }
        return _binaryMath(a, (x, y) => x - y);
      case '/':
        return _binaryMath(a, (x, y) => y == 0 ? double.nan : x / y);
      case '%':
        return _binaryMath(a, (x, y) => x % y);
      case '^':
        return _binaryMath(a, math.pow.call);
      case 'abs':
        return _unaryMath(a, (x) => x.abs());
      case 'ceil':
        return _unaryMath(a, (x) => x.ceilToDouble());
      case 'floor':
        return _unaryMath(a, (x) => x.floorToDouble());
      case 'round':
        return _unaryMath(a, (x) => x.roundToDouble());
      case 'sqrt':
        return _unaryMath(a, math.sqrt);
      case 'ln':
        return _unaryMath(a, math.log);
      case 'log2':
        return _unaryMath(a, (x) => math.log(x) / math.ln2);
      case 'log10':
        return _unaryMath(a, (x) => math.log(x) / math.ln10);
      case 'sin':
        return _unaryMath(a, math.sin);
      case 'cos':
        return _unaryMath(a, math.cos);
      case 'tan':
        return _unaryMath(a, math.tan);
      case 'asin':
        return _unaryMath(a, math.asin);
      case 'acos':
        return _unaryMath(a, math.acos);
      case 'atan':
        return _unaryMath(a, math.atan);
      case 'min':
      case 'max':
        final es = a.skip(1).map(parse).toList();
        final pick = op == 'min' ? math.min<double> : math.max<double>;
        return (ctx) {
          double? acc;
          for (final e in es) {
            final n = asNumber(e(ctx));
            if (n == null) return evalError;
            acc = acc == null ? n : pick(acc, n);
          }
          return acc;
        };
      case 'e':
        return (_) => math.e;
      case 'pi':
        return (_) => math.pi;
      case 'ln2':
        return (_) => math.ln2;

      // --- feature state / heatmap — not applicable here ---
      case 'feature-state':
        return (_) => null;
      case 'heatmap-density':
      case 'line-progress':
      case 'accumulated':
        return (_) => 0.0;
      // Only meaningful in a `color-relief` layer over a `raster-dem`
      // source, neither of which is drawn: no elevation is known.
      case 'elevation':
        return (_) => null;

      default:
        return _unsupported('unsupported operator "$op"');
    }
  }

  /// `within` and `distance`: a GeoJSON literal compiled once, tested
  /// against the feature's geometry ([GeometryEvalContext]). The answer
  /// depends on nothing but the feature, so it is kept per feature —
  /// against its coordinate list, weakly — and a paint property reading
  /// it costs the geometry test once per feature, not once per display
  /// tile.
  Expr _parseGeometryOp(String op, List<Object?> a) {
    if (a.length != 2) {
      return _unsupported('$op needs exactly one GeoJSON argument');
    }
    final shapes = GeoShapes.parse(a[1]);
    if (shapes == null || (op == 'within' && shapes.polygons.isEmpty)) {
      return _unsupported('$op needs GeoJSON geometry'
          '${op == 'within' ? ' with polygons' : ''}');
    }
    _readsFeature = true;
    _readsGeometry = true;
    final memo = Expando<Object>(op);
    if (op == 'within') {
      return (ctx) {
        if (ctx is! GeometryEvalContext) return false;
        final geometry = ctx.geometry;
        return memo[geometry.parts] ??= featureWithin(geometry, shapes);
      };
    }
    return (ctx) {
      if (ctx is! GeometryEvalContext) return null;
      final geometry = ctx.geometry;
      final cached = memo[geometry.parts];
      if (cached != null) return cached is double ? cached : null;
      final d = featureDistance(geometry, shapes);
      memo[geometry.parts] = d ?? false;
      return d;
    };
  }

  /// The assertions `string`, `number`, `boolean`, `object` and `array`:
  /// the first argument of the asserted type, tried in order, or an
  /// error when none is. `array` may name its item type and length
  /// first — `["array", "number", 2, value]`, where an empty list passes
  /// any item type. The type test is bound at parse time.
  Expr _parseAssertion(String op, List<Object?> a) {
    var first = 1;
    bool Function(Object?) matches;
    if (op == 'array') {
      bool Function(Object?)? item;
      int? length;
      if (a.length > 2) {
        item = switch (a[1]) {
          'string' => (v) => v is String,
          'number' => (v) => v is num,
          'boolean' => (v) => v is bool,
          _ => null,
        };
        if (item != null) first = 2;
      }
      if (item != null && a.length > 3) {
        final n = a[2];
        if (n == null || (n is num && n >= 0 && n % 1 == 0)) {
          length = (n as num?)?.toInt();
          first = 3;
        }
      }
      matches = (v) =>
          v is List &&
          (length == null || v.length == length) &&
          (item == null || v.every(item));
    } else {
      matches = switch (op) {
        'string' => (v) => v is String,
        'number' => (v) => v is num,
        'boolean' => (v) => v is bool,
        _ => (v) => v is Map,
      };
    }
    final es = a.skip(first).map(parse).toList();
    return (ctx) {
      for (final e in es) {
        final v = e(ctx);
        if (identical(v, evalError) || matches(v)) return v;
      }
      return evalError;
    };
  }

  /// `number-format`. Every option may be an expression; the usual
  /// literal ones compile to constants, and `formatNumber` keeps the
  /// formats it builds, so a style formatting every feature the same way
  /// builds one.
  Expr _parseNumberFormat(List<Object?> a) {
    final options = a.length > 2 ? a[2] : null;
    if (a.length != 3 || options is! Map) {
      return _unsupported('number-format needs a number and options');
    }
    if (options['currency'] != null && options['unit'] != null) {
      return _unsupported('number-format: currency and unit exclude '
          'each other');
    }
    final input = parse(a[1]);
    Expr option(String key) => parse(options[key]);
    final locale = option('locale');
    final currency = option('currency');
    final unit = option('unit');
    final minDigits = option('min-fraction-digits');
    final maxDigits = option('max-fraction-digits');
    String? text(Object? v) => v == null ? null : toStringValue(v);
    return (ctx) {
      final n = asNumber(input(ctx));
      if (n == null) return evalError;
      return formatNumber(
        n,
        locale: text(locale(ctx)),
        currency: text(currency(ctx)),
        unit: text(unit(ctx)),
        minFractionDigits: toNumber(minDigits(ctx))?.toInt(),
        maxFractionDigits: toNumber(maxDigits(ctx))?.toInt(),
      );
    };
  }

  static bool _isImage(Object? json) =>
      json is List && json.isNotEmpty && json[0] == 'image';

  /// What a needle looks like inside a string haystack: its string
  /// form, `null` included.
  static String _needleText(Object? v) => v == null ? 'null' : toStringValue(v);

  /// [start]/[end] resolved against [length] as JavaScript's `slice`
  /// does: negative counts from the end, everything clamped, an end
  /// before the start empty.
  static (int, int) _sliceRange(int length, double start, double? end) {
    int resolve(double v) {
      final i = v.isFinite ? v.truncate() : (v < 0 ? -length : length);
      return i < 0 ? math.max(length + i, 0) : math.min(i, length);
    }

    final from = resolve(start);
    final to = end == null ? length : resolve(end);
    return (from, math.max(from, to));
  }

  /// `typeof`: arrays name their item type and length, as
  /// `array<number, 3>`; mixed or empty ones `array<value, n>`.
  static String _typeName(Object? v) => switch (v) {
        null => 'null',
        bool _ => 'boolean',
        num _ => 'number',
        String _ => 'string',
        Color _ => 'color',
        final List<Object?> l => 'array<${_itemType(l)}, ${l.length}>',
        _ => 'object',
      };

  static String _itemType(List<Object?> items) {
    final types = {for (final e in items) _typeName(e)};
    return types.length == 1 ? types.single : 'value';
  }

  /// Concatenation shared by `concat` and `format`, over raw argument
  /// JSON. All-literal parts fold to one string at parse time; the
  /// dynamic path writes through a single [StringBuffer] instead of
  /// allocating a mapped iterable per evaluation.
  Expr _concatExpr(List<Object?> parts) {
    if (parts.every((e) => e == null || e is String || e is num || e is bool)) {
      final s = parts.map(toStringValue).join();
      return (_) => s;
    }
    final es = parts.map(parse).toList();
    return (ctx) {
      final sb = StringBuffer();
      for (final e in es) {
        final v = e(ctx);
        if (identical(v, evalError)) return v;
        sb.write(toStringValue(v));
      }
      return sb.toString();
    };
  }

  /// The contents of a `["literal", [...]]` argument, or null when the
  /// argument is anything else.
  static List<Object?>? _literalList(Object? json) {
    if (json is List &&
        json.length > 1 &&
        json[0] == 'literal' &&
        json[1] is List) {
      return (json[1] as List).cast<Object?>();
    }
    return null;
  }

  Expr _unaryMath(List<Object?> a, double Function(double) f) {
    final e = parse(a.length > 1 ? a[1] : null);
    return (ctx) {
      final n = asNumber(e(ctx));
      if (n == null) return evalError;
      final r = f(n);
      return r.isFinite ? r : null;
    };
  }

  Expr _binaryMath(List<Object?> a, num Function(double, double) f) {
    final x = parse(a.length > 1 ? a[1] : null);
    final y = parse(a.length > 2 ? a[2] : null);
    return (ctx) {
      final nx = asNumber(x(ctx));
      final ny = asNumber(y(ctx));
      if (nx == null || ny == null) return evalError;
      final r = f(nx, ny).toDouble();
      return r.isFinite ? r : null;
    };
  }

  Expr _parseLet(List<Object?> a) {
    final names = <String>[];
    final values = <Expr>[];
    var i = 1;
    for (; i + 1 < a.length; i += 2) {
      final name = a[i];
      if (name is! String) break;
      names.add(name);
      values.add(parse(a[i + 1]));
    }
    final body = parse(i < a.length ? a[i] : null);
    if (names.isEmpty) return body;
    return (ctx) {
      final bindings = <String, Object?>{};
      for (var j = 0; j < names.length; j++) {
        bindings[names[j]] = values[j](ctx);
      }
      return body(ctx.withVars(bindings));
    };
  }

  Expr _parseComparison(String op, List<Object?> a) {
    final xJson = a.length > 1 ? a[1] : null;
    final yJson = a.length > 2 ? a[2] : null;
    final x = parse(xJson);
    final y = parse(yJson);
    // Operator dispatch resolved at parse time, not per evaluation.
    if (op == '==' || op == '!=') {
      final negate = op == '!=';
      // `==` compares any two values, so only an error operand fails
      // it — and literals and plain feature reads, the operands of
      // nearly every filter, never are one.
      if (_cannotFail(xJson) && _cannotFail(yJson)) {
        return negate
            ? (ctx) => !_looseEquals(x(ctx), y(ctx))
            : (ctx) => _looseEquals(x(ctx), y(ctx));
      }
      return (ctx) {
        final l = x(ctx);
        final r = y(ctx);
        if (identical(l, evalError) || identical(r, evalError)) {
          return evalError;
        }
        return _looseEquals(l, r) != negate;
      };
    }
    final order = _orderOps.indexOf(op);
    // A literal number types the other operand, as in MapLibre's
    // parser: `[">=", ["get", "rank"], 5]`, the usual shape, is one type
    // test and one comparison.
    if (yJson is num) return _orderWithNumber(order, x, yJson, evalError);
    return (ctx) => _order(order, x(ctx), y(ctx), evalError);
  }

  static const _orderOps = ['<', '<=', '>', '>='];

  /// The ordering comparison [order] (an index into [_orderOps]) of two
  /// numbers or two strings, strings by code unit; [mismatch] for any
  /// other pair — [evalError] in an expression, false in a legacy
  /// filter, where MapLibre requires operands of one type too.
  static Object _order(int order, Object? a, Object? b, Object mismatch) {
    if (a is num && b is num) {
      // As doubles: the VM compares an int with a double through a
      // runtime call, several times the cost of the whole comparison.
      final x = a.toDouble(), y = b.toDouble();
      return switch (order) {
        0 => x < y,
        1 => x <= y,
        2 => x > y,
        _ => x >= y,
      };
    }
    if (a is String && b is String) {
      final c = a.compareTo(b);
      return switch (order) {
        0 => c < 0,
        1 => c <= 0,
        2 => c > 0,
        _ => c >= 0,
      };
    }
    return mismatch;
  }

  /// [_order] against the literal number [n], specialized per operator
  /// at parse time. Compared as doubles, as in [_order]: tile values are
  /// mostly ints.
  static Expr _orderWithNumber(int order, Expr x, num n, Object mismatch) {
    final b = n.toDouble();
    return switch (order) {
      0 => (ctx) {
          final v = x(ctx);
          return v is num ? v.toDouble() < b : mismatch;
        },
      1 => (ctx) {
          final v = x(ctx);
          return v is num ? v.toDouble() <= b : mismatch;
        },
      2 => (ctx) {
          final v = x(ctx);
          return v is num ? v.toDouble() > b : mismatch;
        },
      _ => (ctx) {
          final v = x(ctx);
          return v is num ? v.toDouble() >= b : mismatch;
        },
    };
  }

  /// Whether [json] compiles to an expression that never evaluates to
  /// [evalError]: a literal, or a plain read of the feature, the zoom
  /// or the global state.
  static bool _cannotFail(Object? json) {
    if (json is! List) return json is! Map;
    if (json.isEmpty) return false;
    return switch (json[0]) {
      'literal' ||
      'zoom' ||
      'id' ||
      'geometry-type' ||
      'properties' ||
      'global-state' =>
        true,
      'get' || 'has' => json.length == 2 && json[1] is String,
      _ => false,
    };
  }

  Expr _parseCase(List<Object?> a) {
    final conditions = <Expr>[];
    final outputs = <Expr>[];
    var i = 1;
    for (; i + 1 < a.length; i += 2) {
      conditions.add(parse(a[i]));
      outputs.add(parse(a[i + 1]));
    }
    final fallback = parse(i < a.length ? a[i] : null);
    return (ctx) {
      for (var j = 0; j < conditions.length; j++) {
        final c = conditions[j](ctx);
        if (identical(c, true)) return outputs[j](ctx);
        if (!identical(c, false)) return evalError;
      }
      return fallback(ctx);
    };
  }

  Expr _parseMatch(List<Object?> a) {
    if (a.length < 4) return _unsupported('match needs input and fallback');
    final input = parse(a[1]);
    final labels = <Object?, Expr>{};
    var i = 2;
    for (; i + 1 < a.length - 1; i += 2) {
      final label = a[i];
      final output = parse(a[i + 1]);
      if (label is List) {
        for (final l in label) {
          labels[_matchKey(l)] = output;
        }
      } else {
        labels[_matchKey(label)] = output;
      }
    }
    final fallback = parse(a[a.length - 1]);
    return (ctx) {
      final v = _matchKey(input(ctx));
      final out = labels[v];
      if (out != null) return out(ctx);
      // An input of another type than the labels' is a miss; an error
      // stays one.
      return identical(v, evalError) ? v : fallback(ctx);
    };
  }

  /// Normalizes match labels so `1` and `1.0` compare equal.
  static Object? _matchKey(Object? v) {
    if (v is num) {
      final d = v.toDouble();
      return d == d.roundToDouble() ? d.round() : d;
    }
    return v;
  }

  Expr _parseStep(List<Object?> a) {
    if (a.length < 3) return _unsupported('step needs input and base output');
    final input = parse(a[1]);
    final outputs = <Expr>[parse(a[2])];
    final stops = <double>[];
    for (var i = 3; i + 1 < a.length; i += 2) {
      stops.add(toNumber(a[i]) ?? 0);
      outputs.add(parse(a[i + 1]));
    }
    // Without stops the input is never read, so never checked either.
    if (stops.isEmpty) return outputs[0];
    return (ctx) {
      final x = input(ctx);
      if (x is! num) return evalError;
      // A double against the double stops — see [_order].
      final v = x.toDouble();
      var idx = 0;
      for (var i = 0; i < stops.length; i++) {
        if (v >= stops[i]) {
          idx = i + 1;
        } else {
          break;
        }
      }
      return outputs[idx](ctx);
    };
  }

  Expr _parseInterpolate(String op, List<Object?> a) {
    if (a.length < 5) return _unsupported('interpolate needs stops');
    final type = a[1];
    final space = switch (op) {
      'interpolate-hcl' => ColorSpace.hcl,
      'interpolate-lab' => ColorSpace.lab,
      _ => ColorSpace.rgb,
    };
    double Function(double t) easing = (t) => t;
    var base = 1.0;
    if (type is List && type.isNotEmpty) {
      switch (type[0]) {
        case 'linear':
          break;
        case 'exponential':
          base = type.length > 1 ? (toNumber(type[1]) ?? 1.0) : 1.0;
        case 'cubic-bezier':
          if (type.length >= 5) {
            easing = cubicBezier(
              toNumber(type[1]) ?? 0,
              toNumber(type[2]) ?? 0,
              toNumber(type[3]) ?? 1,
              toNumber(type[4]) ?? 1,
            );
          }
      }
    }
    final input = parse(a[2]);
    final stops = <double>[];
    final outputs = <Expr>[];
    for (var i = 3; i + 1 < a.length; i += 2) {
      stops.add(toNumber(a[i]) ?? 0);
      outputs.add(parse(a[i + 1]));
    }
    // Exponential easing: pow(base, span) is constant per interval, so
    // the inverse denominators are precomputed and evaluation pays a
    // single pow on the input instead of two.
    final invDenom = base == 1.0 ? null : _inverseDenominators(stops, base);
    // With one stop the input is never read, so never checked either.
    if (stops.length == 1) return outputs.first;
    return (ctx) {
      final x = input(ctx);
      if (x is! num) return evalError;
      final v = x.toDouble();
      if (v <= stops.first) return outputs.first(ctx);
      if (v >= stops.last) return outputs.last(ctx);
      var hi = 1;
      while (hi < stops.length && stops[hi] < v) {
        hi++;
      }
      final lo = hi - 1;
      final t =
          easing(_intervalFactor(v, stops, lo, base, invDenom).clamp(0.0, 1.0));
      // Outputs that cannot be blended — an error among them — are an
      // error here, where a legacy function holds the lower one.
      return _blend(outputs[lo](ctx), outputs[hi](ctx), t, space) ?? evalError;
    };
  }

  /// `1 / (pow(base, span) - 1)` per stop interval; 0 encodes the
  /// degenerate zero-span interval (where the factor is defined as 0).
  static List<double> _inverseDenominators(List<double> stops, double base) {
    final out = List<double>.filled(math.max(stops.length - 1, 0), 0);
    for (var i = 0; i + 1 < stops.length; i++) {
      final p = math.pow(base, stops[i + 1] - stops[i]).toDouble();
      out[i] = p == 1 ? 0 : 1 / (p - 1);
    }
    return out;
  }

  /// The unclamped interpolation parameter for [v] within the stop
  /// interval starting at [lo] — linear when [invDenom] is null,
  /// exponential otherwise. Shared by `interpolate` expressions and
  /// legacy stop functions; callers clamp to [0, 1].
  static double _intervalFactor(double v, List<double> stops, int lo,
      double base, List<double>? invDenom) {
    if (invDenom == null) {
      final span = stops[lo + 1] - stops[lo];
      return span <= 0 ? 0 : (v - stops[lo]) / span;
    }
    final inv = invDenom[lo];
    if (inv == 0) return 0;
    return (math.pow(base, v - stops[lo]).toDouble() - 1) * inv;
  }

  /// [a] and [b] blended at [t]: numbers, colours, or lists of them of
  /// one length. Null when they cannot be blended.
  static Object? _blend(Object? a, Object? b, double t, ColorSpace space) {
    // Numbers, not numeric strings: a string-valued property ramped by
    // a legacy function ("0" → "1") holds each stop like any other
    // string, as it does in MapLibre.
    if (a is num && b is num) return a + (b - a) * t;
    final ca = toColor(a);
    final cb = toColor(b);
    if (ca != null && cb != null) return lerpColor(ca, cb, t, space);
    if (a is List && b is List && a.length == b.length) {
      final out = <Object?>[];
      for (var i = 0; i < a.length; i++) {
        final v = _blend(a[i], b[i], t, space);
        if (v == null) return null;
        out.add(v);
      }
      return out;
    }
    return null;
  }

  /// A legacy function's [_blend]. Outputs it cannot blend (strings,
  /// booleans, mismatched arrays) hold the lower stop's value until the
  /// next stop, as MapLibre does — it converts a legacy function over
  /// such a property to `interval`. Snapping at the midpoint switched a
  /// zoom-staged `text-field` half a level early.
  static Object? _blendOrHold(
          Object? a, Object? b, double t, ColorSpace space) =>
      _blend(a, b, t, space) ?? a;

  static ColorSpace _legacyColorSpace(Map<String, Object?> json) =>
      switch (json['colorSpace']) {
        'hcl' => ColorSpace.hcl,
        'lab' => ColorSpace.lab,
        _ => ColorSpace.rgb,
      };

  /// A legacy zoom-and-property function, whose stops key on
  /// `{"zoom": z, "value": v}`: one property function per zoom, the
  /// zooms ramped with the function's base — or stepped through, for
  /// `interval` and `categorical` functions.
  Expr _parseCompositeFunction(Map<String, Object?> json, List<Object?> stops,
      bool Function(Object?)? accepts) {
    final byZoom = <double, List<Object?>>{};
    for (final stop in stops) {
      if (stop is! List || stop.length < 2 || stop[0] is! Map) continue;
      final key = stop[0] as Map;
      final zoom = toNumber(key['zoom']);
      if (zoom == null) continue;
      (byZoom[zoom] ??= []).add([key['value'], stop[1]]);
    }
    if (byZoom.isEmpty) {
      return _unsupported('unsupported legacy function $json');
    }
    _readsZoom = true;
    final zooms = byZoom.keys.toList()..sort();
    final perZoom = [
      for (final z in zooms)
        _parseLegacyFunction({...json, 'stops': byZoom[z]}, accepts),
    ];
    final type = json['type'] as String? ?? 'exponential';
    final base = toNumber(json['base']) ?? 1.0;
    final space = _legacyColorSpace(json);
    final stepped = type != 'exponential';
    final invDenom =
        stepped || base == 1.0 ? null : _inverseDenominators(zooms, base);
    return (ctx) {
      final z = ctx.zoom;
      if (z <= zooms.first) return perZoom.first(ctx);
      if (z >= zooms.last) return perZoom.last(ctx);
      var hi = 1;
      while (hi < zooms.length && zooms[hi] <= z) {
        hi++;
      }
      final lo = hi - 1;
      if (stepped) return perZoom[lo](ctx);
      final lower = perZoom[lo](ctx);
      final upper = perZoom[hi](ctx);
      if (lower == null || upper == null) return null;
      return _blendOrHold(lower, upper,
          _intervalFactor(z, zooms, lo, base, invDenom).clamp(0.0, 1.0), space);
    };
  }

  // -------------------------------------------------------------------------
  // Legacy (pre-expression) syntax.

  /// Legacy property functions: `{"stops": [...], "base": b, "property": p}`.
  /// [accepts] is the property's — see [parseForProperty].
  Expr _parseLegacyFunction(Map<String, Object?> json,
      [bool Function(Object?)? accepts]) {
    final stopsJson = json['stops'];
    if (stopsJson is! List || stopsJson.isEmpty) {
      final property = json['property'] as String?;
      if (json['type'] == 'identity') {
        // Identity function: the feature property's raw value (the
        // zoom when no property is named) when the property takes it,
        // else the function's default.
        if (property == null) {
          _readsZoom = true;
          return (ctx) => ctx.zoom;
        }
        _refProp(property);
        final defaultValue = json['default'];
        if (accepts == null) {
          return (ctx) => ctx.properties[property] ?? defaultValue;
        }
        return (ctx) {
          final v = ctx.properties[property];
          return v != null && accepts(v) ? v : defaultValue;
        };
      }
      if (json.containsKey('type') ||
          json.containsKey('property') ||
          json.containsKey('default')) {
        // Function-shaped but not compilable: degrade with a warning,
        // per the package contract — passing the raw map through would
        // silently coerce to null in every typed property.
        return _unsupported('unsupported legacy function $json');
      }
      // A plain object value (e.g. a constant) — pass through.
      return (_) => json;
    }
    final first = stopsJson.first;
    if (first is List && first.isNotEmpty && first.first is Map) {
      return _parseCompositeFunction(json, stopsJson, accepts);
    }
    final base = toNumber(json['base']) ?? 1.0;
    final space = _legacyColorSpace(json);
    final property = json['property'] as String?;
    if (property != null) {
      _refProp(property);
    } else {
      _readsZoom = true;
    }
    final defaultValue = json['default'];
    final type = json['type'] as String? ?? 'exponential';

    final stopInputs = <Object?>[];
    final stops = <double>[];
    final outputs = <Object?>[];
    for (final stop in stopsJson) {
      if (stop is List && stop.length >= 2) {
        stopInputs.add(stop[0]);
        stops.add(toNumber(stop[0]) ?? 0);
        outputs.add(stop[1]);
      }
    }
    if (stops.isEmpty) return (_) => defaultValue;

    Object? inputOf(EvalContext ctx) =>
        property == null ? ctx.zoom : ctx.properties[property];

    // The function type is fixed at parse time — specialize instead of
    // re-branching on the type string per evaluation.
    if (type == 'categorical') {
      // First matching stop wins, like the linear scan it replaces;
      // keys are normalized so `1` and `1.0` stay interchangeable.
      final byKey = <Object?, Object?>{};
      for (var i = 0; i < stopInputs.length; i++) {
        byKey.putIfAbsent(_matchKey(stopInputs[i]), () => outputs[i]);
      }
      return (ctx) {
        final key = _matchKey(inputOf(ctx));
        return byKey.containsKey(key) ? byKey[key] : defaultValue;
      };
    }

    final isInterval = type == 'interval';
    final invDenom =
        isInterval || base == 1.0 ? null : _inverseDenominators(stops, base);
    return (ctx) {
      // A number, not a numeric string; anything else gets the default.
      final x = inputOf(ctx);
      if (x is! num) return defaultValue;
      final v = x.toDouble();
      if (v <= stops.first) return outputs.first;
      if (v >= stops.last) return outputs.last;
      var hi = 1;
      // `<=`, not `<`: an input exactly on a middle stop belongs to that
      // stop's band — 'interval' selects the greatest stop <= input, as
      // MapLibre does. (For exponential stops the boundary is
      // equivalent: t == 0 at the upper stop equals t == 1 at the
      // lower.)
      while (hi < stops.length && stops[hi] <= v) {
        hi++;
      }
      var lo = hi - 1;
      // On a stop the style lists twice, the first of them holds.
      while (lo > 0 && stops[lo - 1] == stops[lo]) {
        lo--;
      }
      if (isInterval) return outputs[lo];
      return _blendOrHold(outputs[lo], outputs[lo + 1],
          _intervalFactor(v, stops, lo, base, invDenom).clamp(0.0, 1.0), space);
    };
  }

  /// Port of MapLibre's `isExpressionFilter`.
  bool _isExpressionFilter(List<Object?> filter) {
    if (filter.isEmpty) return false;
    final op = filter[0];
    switch (op) {
      case 'has':
        return filter.length >= 2 &&
            filter[1] != r'$id' &&
            filter[1] != r'$type';
      case 'in':
        return filter.length >= 3 &&
            (filter[1] is! String || filter[2] is List);
      case '!in':
      case '!has':
      case 'none':
        return false;
      case '==':
      case '!=':
      case '>':
      case '>=':
      case '<':
      case '<=':
        return filter.length != 3 || filter[1] is List || filter[2] is List;
      case 'any':
      case 'all':
        for (final f in filter.skip(1)) {
          if (f is bool) continue;
          if (f is! List || !_isExpressionFilter(f)) return false;
        }
        return true;
      default:
        return true;
    }
  }

  Expr _parseLegacyFilter(List<Object?> filter) {
    final op = filter[0];
    switch (op) {
      // Plain loops, not every/any: the iterator callbacks captured ctx
      // and allocated a closure per evaluation of the hottest closures
      // in the engine (every layer × every feature of its source-layer).
      case 'all':
        final es =
            filter.skip(1).map((f) => parseFilter(f)).toList(growable: false);
        return (ctx) {
          for (final e in es) {
            if (!toBoolean(e(ctx))) return false;
          }
          return true;
        };
      case 'any':
        final es =
            filter.skip(1).map((f) => parseFilter(f)).toList(growable: false);
        return (ctx) {
          for (final e in es) {
            if (toBoolean(e(ctx))) return true;
          }
          return false;
        };
      case 'none':
        final es =
            filter.skip(1).map((f) => parseFilter(f)).toList(growable: false);
        return (ctx) {
          for (final e in es) {
            if (toBoolean(e(ctx))) return false;
          }
          return true;
        };
      case 'has':
        final key = _legacyKey(filter);
        if (key == r'$id') {
          _readsFeature = true;
          return (ctx) => ctx.featureId != null;
        }
        if (key == r'$type') return (_) => true;
        _refProp(key);
        return (ctx) => ctx.properties.containsKey(key);
      case '!has':
        final key = _legacyKey(filter);
        if (key == r'$id') {
          _readsFeature = true;
          return (ctx) => ctx.featureId == null;
        }
        if (key == r'$type') return (_) => false;
        _refProp(key);
        return (ctx) => !ctx.properties.containsKey(key);
      case '==':
      case '!=':
      case '<':
      case '<=':
      case '>':
      case '>=':
        final key = _legacyKey(filter);
        final value = filter.length > 2 ? filter[2] : null;
        _refLegacyKey(key);
        // Operator dispatch resolved at parse time, not per evaluation.
        if (op == '==') {
          return (ctx) => _looseEquals(_legacyValue(ctx, key), value);
        }
        if (op == '!=') {
          return (ctx) => !_looseEquals(_legacyValue(ctx, key), value);
        }
        // Ordering needs operands of one type here too: a numeric string
        // is not compared with a number, and a mismatch is false, not an
        // error.
        final order = _orderOps.indexOf(op as String);
        if (value is num && key != r'$type' && key != r'$id') {
          return _orderWithNumber(
              order, (ctx) => ctx.properties[key], value, false);
        }
        return (ctx) => _order(order, _legacyValue(ctx, key), value, false);
      case 'in':
      case '!in':
        final key = _legacyKey(filter);
        _refLegacyKey(key);
        // O(1) membership over parse-time-normalized values instead of
        // a linear _looseEquals scan per feature — legacy `in` lists
        // ("class" in primary/secondary/...) are pervasive and mostly
        // *don't* match, so the scan used to run to the end.
        final values = {for (final v in filter.skip(2)) _matchKey(v)};
        final negate = op == '!in';
        return (ctx) {
          final contained = values.contains(_matchKey(_legacyValue(ctx, key)));
          return negate ? !contained : contained;
        };
      default:
        warnings.add('unsupported legacy filter "$op"');
        return (_) => true;
    }
  }

  String _legacyKey(List<Object?> filter) =>
      filter.length > 1 && filter[1] is String ? filter[1] as String : '';

  void _refLegacyKey(String key) {
    _readsFeature = true; // $type/$id read the feature too
    if (key != r'$type' && key != r'$id') _refProp(key);
  }

  static Object? _legacyValue(EvalContext ctx, String key) => switch (key) {
        r'$type' => ctx.geometryType,
        r'$id' => ctx.featureId,
        _ => ctx.properties[key],
      };

  /// What `in` and `index-of` take as a needle; an object, an array or
  /// an error is not one.
  static bool _isNeedle(Object? v) =>
      v == null || v is String || v is num || v is bool;

  /// JavaScript's falsiness, which `in` tests its haystack for before
  /// anything else.
  static bool _isFalsy(Object? v) =>
      v == null || v == false || v == 0 || v == '' || (v is double && v.isNaN);

  /// MapLibre's range check for `rgb` / `rgba` channels: 0–255 for red,
  /// green and blue, 0–1 for alpha.
  static bool _validRgba(List<Object?> channels) {
    if (channels.length != 3 && channels.length != 4) return false;
    for (var i = 0; i < channels.length; i++) {
      final c = channels[i];
      // Written so that NaN fails too.
      if (c is! num || !(c >= 0 && c <= (i == 3 ? 1 : 255))) return false;
    }
    return true;
  }

  static bool _looseEquals(Object? a, Object? b) {
    if (a == null || b == null) return a == b;
    if (a is num && b is num) return a.toDouble() == b.toDouble();
    return a == b;
  }
}
