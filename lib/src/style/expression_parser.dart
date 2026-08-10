import 'dart:math' as math;
import 'dart:ui' show Color;

import 'package:flutter/animation.dart' show Cubic;

import 'expression.dart';

/// Compiles MapLibre style expressions (and legacy filter / function
/// syntax) into Dart closures.
///
/// The parser is deliberately tolerant: anything it cannot compile
/// becomes an expression evaluating to null (callers fall back to the
/// spec default for the property), and the problem is reported through
/// [warnings] instead of throwing. This keeps real-world styles
/// (MapTiler, ArcGIS, Protomaps, ...) rendering even when they use
/// exotic operators.
class ExpressionParser {
  /// Property names referenced via `get`/`has`/legacy filters. When an
  /// expression accesses properties dynamically, [referencesAllProperties]
  /// is set instead.
  final Set<String> referencedProperties = {};
  bool referencesAllProperties = false;
  final List<String> warnings = [];

  /// Set while parsing when the subtree read feature data (properties,
  /// feature id, geometry type) — the basis for zoom-only detection.
  bool _readsFeature = false;

  /// Parses one style property, additionally reporting whether the
  /// compiled expression is zoom-only (reads no feature data). The
  /// typed property wrappers memoize zoom-only results against the
  /// zoom — see `DoubleProp.zoomOnly`.
  ({Expr expr, bool zoomOnly}) parseForProperty(Object? json) {
    final saved = _readsFeature;
    _readsFeature = false;
    final expr = parse(json);
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
    'image',
    'format',
    'concat',
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
      return (ctx) => toBoolean(e(ctx));
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
            final o = obj(ctx);
            return o is Map ? o[toStringValue(name(ctx))] : null;
          };
        }
        _refProp(a.length > 1 ? a[1] : null);
        final key = a.length > 1 ? a[1] : null;
        // A literal key — the overwhelmingly common shape, and the
        // hottest leaf in the engine — reads the map directly instead
        // of paying an inner closure plus string coercion per call.
        if (key is String) return (ctx) => ctx.properties[key];
        final keyExpr = parse(key);
        return (ctx) => ctx.properties[toStringValue(keyExpr(ctx))];
      case 'has':
        if (a.length > 2) {
          final name = parse(a[1]);
          final obj = parse(a[2]);
          return (ctx) {
            final o = obj(ctx);
            return o is Map && o.containsKey(toStringValue(name(ctx)));
          };
        }
        _refProp(a.length > 1 ? a[1] : null);
        final key = a.length > 1 ? a[1] : null;
        if (key is String) return (ctx) => ctx.properties.containsKey(key);
        final keyExpr = parse(key);
        return (ctx) => ctx.properties.containsKey(toStringValue(keyExpr(ctx)));
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
        return (ctx) => ctx.zoom;
      case 'let':
        return _parseLet(a);
      case 'var':
        final name = a.length > 1 ? toStringValue(a[1]) : '';
        return (ctx) => ctx.vars?[name];

      // --- decisions ---
      case '!':
        final e = parse(a.length > 1 ? a[1] : null);
        return (ctx) => !toBoolean(e(ctx));
      case '==':
      case '!=':
      case '<':
      case '<=':
      case '>':
      case '>=':
        return _parseComparison(op, a);
      case 'all':
        final es = a.skip(1).map(parse).toList();
        return (ctx) {
          for (final e in es) {
            if (!toBoolean(e(ctx))) return false;
          }
          return true;
        };
      case 'any':
        final es = a.skip(1).map(parse).toList();
        return (ctx) {
          for (final e in es) {
            if (toBoolean(e(ctx))) return true;
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
        return _unsupported('within is not supported');

      // --- ramps ---
      case 'step':
        return _parseStep(a);
      case 'interpolate':
      case 'interpolate-hcl':
      case 'interpolate-lab':
        return _parseInterpolate(a);

      // --- lookup ---
      case 'in':
        final needle = parse(a.length > 1 ? a[1] : null);
        final haystackJson = a.length > 2 ? a[2] : null;
        // A literal haystack (the common shape) becomes an O(1) lookup
        // over parse-time-normalized values.
        final literal = _literalList(haystackJson);
        if (literal != null) {
          final values = {for (final e in literal) _matchKey(e)};
          return (ctx) => values.contains(_matchKey(needle(ctx)));
        }
        final haystack = parse(haystackJson);
        return (ctx) {
          final n = needle(ctx);
          final h = haystack(ctx);
          if (h is List) {
            for (var i = 0; i < h.length; i++) {
              if (_looseEquals(h[i], n)) return true;
            }
            return false;
          }
          if (h is String) return h.contains(toStringValue(n));
          return false;
        };
      case 'index-of':
        final needle = parse(a.length > 1 ? a[1] : null);
        final haystack = parse(a.length > 2 ? a[2] : null);
        return (ctx) {
          final n = needle(ctx);
          final h = haystack(ctx);
          if (h is List) {
            for (var i = 0; i < h.length; i++) {
              if (_looseEquals(h[i], n)) return i;
            }
            return -1;
          }
          if (h is String) return h.indexOf(toStringValue(n));
          return -1;
        };
      case 'at':
        final index = parse(a.length > 1 ? a[1] : null);
        final list = parse(a.length > 2 ? a[2] : null);
        return (ctx) {
          final l = list(ctx);
          final i = toNumber(index(ctx))?.toInt();
          if (l is List && i != null && i >= 0 && i < l.length) return l[i];
          return null;
        };
      case 'slice':
        final target = parse(a.length > 1 ? a[1] : null);
        final start = parse(a.length > 2 ? a[2] : null);
        final end = a.length > 3 ? parse(a[3]) : null;
        return (ctx) {
          final t = target(ctx);
          final s = toNumber(start(ctx))?.toInt() ?? 0;
          if (t is String) {
            final e = end != null
                ? (toNumber(end(ctx))?.toInt() ?? t.length)
                : t.length;
            if (s < 0 || s > t.length) return '';
            return t.substring(s, e.clamp(s, t.length));
          }
          if (t is List) {
            final e = end != null
                ? (toNumber(end(ctx))?.toInt() ?? t.length)
                : t.length;
            if (s < 0 || s > t.length) return const <Object?>[];
            return t.sublist(s, e.clamp(s, t.length));
          }
          return null;
        };
      case 'length':
        final e = parse(a.length > 1 ? a[1] : null);
        return (ctx) {
          final v = e(ctx);
          if (v is String) return v.length;
          if (v is List) return v.length;
          return null;
        };

      // --- types ---
      case 'to-string':
        final e = parse(a.length > 1 ? a[1] : null);
        return (ctx) => toStringValue(e(ctx));
      case 'to-number':
        final es = a.skip(1).map(parse).toList();
        return (ctx) {
          for (final e in es) {
            final n = toNumber(e(ctx));
            if (n != null) return n;
          }
          return 0.0;
        };
      case 'to-boolean':
        final e = parse(a.length > 1 ? a[1] : null);
        return (ctx) => toBoolean(e(ctx));
      case 'to-color':
        final es = a.skip(1).map(parse).toList();
        return (ctx) {
          for (final e in es) {
            final c = toColor(e(ctx));
            if (c != null) return c;
          }
          return null;
        };
      case 'typeof':
        final e = parse(a.length > 1 ? a[1] : null);
        return (ctx) => switch (e(ctx)) {
              null => 'null',
              bool _ => 'boolean',
              num _ => 'number',
              String _ => 'string',
              Color _ => 'color',
              List<Object?> _ => 'array',
              _ => 'object',
            };
      case 'string':
      case 'number':
      case 'boolean':
      case 'object':
      case 'array':
        // Assertion operators: return the first argument that matches the
        // asserted type; fall through to the next otherwise. The type
        // predicate is bound at parse time.
        final es = a.skip(1).map(parse).toList();
        final matches = switch (op) {
          'string' => (Object? v) => v is String,
          'number' => (Object? v) => v is num,
          'boolean' => (Object? v) => v is bool,
          'array' => (Object? v) => v is List,
          _ => (Object? v) => v is Map,
        };
        return (ctx) {
          for (final e in es) {
            final v = e(ctx);
            if (matches(v)) return v;
          }
          return null;
        };
      case 'image':
        final e = parse(a.length > 1 ? a[1] : null);
        return (ctx) => toStringValue(e(ctx));
      case 'format':
        // Rich text formatting: flatten to plain concatenated text.
        final parts = <Object?>[
          for (var i = 1; i < a.length; i++)
            if (a[i] is! Map) a[i], // style overrides — ignored
        ];
        return _concatExpr(parts);

      // --- strings ---
      case 'concat':
        return _concatExpr(a.skip(1).toList());
      case 'upcase':
        final e = parse(a.length > 1 ? a[1] : null);
        return (ctx) => toStringValue(e(ctx)).toUpperCase();
      case 'downcase':
        final e = parse(a.length > 1 ? a[1] : null);
        return (ctx) => toStringValue(e(ctx)).toLowerCase();
      case 'is-supported-script':
        return (_) => true;
      case 'resolved-locale':
        return (_) => 'en';
      case 'collator':
        return (_) => null;

      // --- color ---
      case 'rgb':
      case 'rgba':
        // toColor owns the channel semantics (clamp, round, alpha
        // default) — this case only gathers the evaluated channels.
        // All-literal channels (the typical shape, e.g. as interpolate
        // outputs) fold to a Color at parse time.
        if (a.length >= 4 && a.skip(1).every((e) => e is num)) {
          final c = toColor(a.sublist(1));
          return (_) => c;
        }
        final es = a.skip(1).map(parse).toList();
        return (ctx) => toColor([for (final e in es) e(ctx)]);
      case 'to-rgba':
        final e = parse(a.length > 1 ? a[1] : null);
        return (ctx) {
          final c = toColor(e(ctx));
          if (c == null) return null;
          return [c.r * 255, c.g * 255, c.b * 255, c.a];
        };

      // --- math ---
      case '+':
      case '*':
        // The operator is bound at parse time — the old form re-tested
        // the op string per operand per evaluation.
        final es = a.skip(1).map(parse).toList();
        if (op == '+') {
          return (ctx) {
            var acc = 0.0;
            for (final e in es) {
              final n = toNumber(e(ctx));
              if (n == null) return null;
              acc += n;
            }
            return acc;
          };
        }
        return (ctx) {
          var acc = 1.0;
          for (final e in es) {
            final n = toNumber(e(ctx));
            if (n == null) return null;
            acc *= n;
          }
          return acc;
        };
      case '-':
        if (a.length == 2) {
          final e = parse(a[1]);
          return (ctx) {
            final n = toNumber(e(ctx));
            return n == null ? null : -n;
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
            final n = toNumber(e(ctx));
            if (n == null) return null;
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

      default:
        return _unsupported('unsupported operator "$op"');
    }
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
        sb.write(toStringValue(e(ctx)));
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
      final n = toNumber(e(ctx));
      if (n == null) return null;
      final r = f(n);
      return r.isFinite ? r : null;
    };
  }

  Expr _binaryMath(List<Object?> a, num Function(double, double) f) {
    final x = parse(a.length > 1 ? a[1] : null);
    final y = parse(a.length > 2 ? a[2] : null);
    return (ctx) {
      final nx = toNumber(x(ctx));
      final ny = toNumber(y(ctx));
      if (nx == null || ny == null) return null;
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
    final x = parse(a.length > 1 ? a[1] : null);
    final y = parse(a.length > 2 ? a[2] : null);
    // Operator dispatch resolved at parse time, not per evaluation.
    return switch (op) {
      '==' => (ctx) => _looseEquals(x(ctx), y(ctx)),
      '!=' => (ctx) => !_looseEquals(x(ctx), y(ctx)),
      _ => (ctx) => _compare(op, x(ctx), y(ctx)),
    };
  }

  /// Ordering comparison shared by expression and legacy filters:
  /// string pairs compare lexicographically (the spec'd behaviour for
  /// same-type operands); anything else goes through [toNumber] —
  /// tolerant of numeric strings against numbers, which real styles
  /// rely on. Incomparable operands are false.
  static bool _compare(String op, Object? a, Object? b) {
    final int? cmp;
    if (a is String && b is String) {
      cmp = a.compareTo(b);
    } else {
      final na = toNumber(a);
      final nb = toNumber(b);
      cmp = (na == null || nb == null) ? null : na.compareTo(nb);
    }
    if (cmp == null) return false;
    return switch (op) {
      '<' => cmp < 0,
      '<=' => cmp <= 0,
      '>' => cmp > 0,
      _ => cmp >= 0,
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
        if (toBoolean(conditions[j](ctx))) return outputs[j](ctx);
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
      return out != null ? out(ctx) : fallback(ctx);
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
    return (ctx) {
      final v = toNumber(input(ctx));
      if (v == null) return outputs[0](ctx);
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

  Expr _parseInterpolate(List<Object?> a) {
    if (a.length < 5) return _unsupported('interpolate needs stops');
    final type = a[1];
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
            easing = Cubic(
              toNumber(type[1]) ?? 0,
              toNumber(type[2]) ?? 0,
              toNumber(type[3]) ?? 1,
              toNumber(type[4]) ?? 1,
            ).transform;
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
    return (ctx) {
      final v = toNumber(input(ctx));
      if (v == null || stops.isEmpty) return null;
      if (v <= stops.first) return outputs.first(ctx);
      if (v >= stops.last) return outputs.last(ctx);
      var hi = 1;
      while (hi < stops.length && stops[hi] < v) {
        hi++;
      }
      final lo = hi - 1;
      final t =
          easing(_intervalFactor(v, stops, lo, base, invDenom).clamp(0.0, 1.0));
      return _interpolateValues(outputs[lo](ctx), outputs[hi](ctx), t);
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

  static Object? _interpolateValues(Object? a, Object? b, double t) {
    final na = toNumber(a);
    final nb = toNumber(b);
    if (na != null && nb != null) return na + (nb - na) * t;
    final ca = toColor(a);
    final cb = toColor(b);
    if (ca != null && cb != null) return Color.lerp(ca, cb, t);
    if (a is List && b is List && a.length == b.length) {
      final out = <Object?>[];
      for (var i = 0; i < a.length; i++) {
        out.add(_interpolateValues(a[i], b[i], t));
      }
      return out;
    }
    return t < 0.5 ? a : b;
  }

  // -------------------------------------------------------------------------
  // Legacy (pre-expression) syntax.

  /// Legacy property functions: `{"stops": [...], "base": b, "property": p}`.
  Expr _parseLegacyFunction(Map<String, Object?> json) {
    final stopsJson = json['stops'];
    if (stopsJson is! List || stopsJson.isEmpty) {
      final property = json['property'] as String?;
      if (json['type'] == 'identity') {
        // Identity function: the feature property's raw value (the
        // zoom when no property is named).
        if (property == null) return (ctx) => ctx.zoom;
        _refProp(property);
        final defaultValue = json['default'];
        return (ctx) => ctx.properties[property] ?? defaultValue;
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
    final base = toNumber(json['base']) ?? 1.0;
    final property = json['property'] as String?;
    if (property != null) _refProp(property);
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
      final v = toNumber(inputOf(ctx));
      if (v == null) return defaultValue;
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
      final lo = hi - 1;
      if (isInterval) return outputs[lo];
      return _interpolateValues(outputs[lo], outputs[hi],
          _intervalFactor(v, stops, lo, base, invDenom).clamp(0.0, 1.0));
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
        return switch (op) {
          '==' => (ctx) => _looseEquals(_legacyValue(ctx, key), value),
          '!=' => (ctx) => !_looseEquals(_legacyValue(ctx, key), value),
          _ => (ctx) => _compare(op as String, _legacyValue(ctx, key), value),
        };
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

  static bool _looseEquals(Object? a, Object? b) {
    if (a == null || b == null) return a == b;
    if (a is num && b is num) return a.toDouble() == b.toDouble();
    return a == b;
  }
}
