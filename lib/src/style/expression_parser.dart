import 'dart:math' as math;
import 'dart:ui' show Color;

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
      if (op is! String) return _unsupported('non-string operator $op');
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
        final key = parse(a.length > 1 ? a[1] : null);
        return (ctx) => ctx.properties[toStringValue(key(ctx))];
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
        final key = parse(a.length > 1 ? a[1] : null);
        return (ctx) => ctx.properties.containsKey(toStringValue(key(ctx)));
      case 'properties':
        referencesAllProperties = true;
        return (ctx) => ctx.properties;
      case 'id':
        return (ctx) => ctx.featureId;
      case 'geometry-type':
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
        final haystack = parse(a.length > 2 ? a[2] : null);
        return (ctx) {
          final n = needle(ctx);
          final h = haystack(ctx);
          if (h is List) return h.any((e) => _looseEquals(e, n));
          if (h is String) return h.contains(toStringValue(n));
          return false;
        };
      case 'index-of':
        final needle = parse(a.length > 1 ? a[1] : null);
        final haystack = parse(a.length > 2 ? a[2] : null);
        return (ctx) {
          final n = needle(ctx);
          final h = haystack(ctx);
          if (h is List) return h.indexWhere((e) => _looseEquals(e, n));
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
            final e =
                end != null ? (toNumber(end(ctx))?.toInt() ?? t.length) : t.length;
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
        // asserted type; fall through to the next otherwise.
        final es = a.skip(1).map(parse).toList();
        return (ctx) {
          for (final e in es) {
            final v = e(ctx);
            final matches = switch (op) {
              'string' => v is String,
              'number' => v is num,
              'boolean' => v is bool,
              'array' => v is List,
              _ => v is Map,
            };
            if (matches) return v;
          }
          return null;
        };
      case 'image':
        final e = parse(a.length > 1 ? a[1] : null);
        return (ctx) => toStringValue(e(ctx));
      case 'format':
        // Rich text formatting: flatten to plain concatenated text.
        final parts = <Expr>[];
        for (var i = 1; i < a.length; i++) {
          if (a[i] is Map) continue; // style overrides — ignored
          parts.add(parse(a[i]));
        }
        return (ctx) => parts.map((e) => toStringValue(e(ctx))).join();

      // --- strings ---
      case 'concat':
        final es = a.skip(1).map(parse).toList();
        return (ctx) => es.map((e) => toStringValue(e(ctx))).join();
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
        final es = a.skip(1).map(parse).toList();
        return (ctx) {
          final v = es.map((e) => toNumber(e(ctx))).toList();
          if (v.length < 3 || v.take(3).any((n) => n == null)) return null;
          final alpha = v.length > 3 ? (v[3] ?? 1.0) : 1.0;
          return Color.fromARGB(
            (alpha.clamp(0.0, 1.0) * 255).round(),
            v[0]!.round().clamp(0, 255),
            v[1]!.round().clamp(0, 255),
            v[2]!.round().clamp(0, 255),
          );
        };
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
        final es = a.skip(1).map(parse).toList();
        return (ctx) {
          var acc = op == '+' ? 0.0 : 1.0;
          for (final e in es) {
            final n = toNumber(e(ctx));
            if (n == null) return null;
            acc = op == '+' ? acc + n : acc * n;
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
        return (ctx) {
          double? acc;
          for (final e in es) {
            final n = toNumber(e(ctx));
            if (n == null) return null;
            acc = acc == null
                ? n
                : op == 'min'
                    ? math.min(acc, n)
                    : math.max(acc, n);
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
    return (ctx) {
      final vx = x(ctx);
      final vy = y(ctx);
      switch (op) {
        case '==':
          return _looseEquals(vx, vy);
        case '!=':
          return !_looseEquals(vx, vy);
      }
      final int? cmp;
      if (vx is String && vy is String) {
        cmp = vx.compareTo(vy);
      } else {
        final nx = toNumber(vx);
        final ny = toNumber(vy);
        cmp = (nx == null || ny == null) ? null : nx.compareTo(ny);
      }
      if (cmp == null) return false;
      return switch (op) {
        '<' => cmp < 0,
        '<=' => cmp <= 0,
        '>' => cmp > 0,
        _ => cmp >= 0,
      };
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
            final x1 = toNumber(type[1]) ?? 0;
            final y1 = toNumber(type[2]) ?? 0;
            final x2 = toNumber(type[3]) ?? 1;
            final y2 = toNumber(type[4]) ?? 1;
            easing = _cubicBezier(x1, y1, x2, y2);
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
      final span = stops[hi] - stops[lo];
      var t = span <= 0 ? 0.0 : (v - stops[lo]) / span;
      if (base != 1.0) {
        final p = math.pow(base, span).toDouble();
        t = p == 1
            ? t
            : (math.pow(base, v - stops[lo]).toDouble() - 1) / (p - 1);
      }
      t = easing(t.clamp(0.0, 1.0));
      return _interpolateValues(outputs[lo](ctx), outputs[hi](ctx), t);
    };
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

  static double Function(double) _cubicBezier(
      double x1, double y1, double x2, double y2) {
    double sampleX(double t) =>
        3 * x1 * t * (1 - t) * (1 - t) + 3 * x2 * t * t * (1 - t) + t * t * t;
    double sampleY(double t) =>
        3 * y1 * t * (1 - t) * (1 - t) + 3 * y2 * t * t * (1 - t) + t * t * t;
    return (x) {
      // Binary search for parameter t with sampleX(t) == x.
      var lo = 0.0, hi = 1.0;
      for (var i = 0; i < 20; i++) {
        final mid = (lo + hi) / 2;
        if (sampleX(mid) < x) {
          lo = mid;
        } else {
          hi = mid;
        }
      }
      return sampleY((lo + hi) / 2);
    };
  }

  // -------------------------------------------------------------------------
  // Legacy (pre-expression) syntax.

  /// Legacy property functions: `{"stops": [...], "base": b, "property": p}`.
  Expr _parseLegacyFunction(Map<String, Object?> json) {
    final stopsJson = json['stops'];
    if (stopsJson is! List || stopsJson.isEmpty) {
      // Could be a plain object value (e.g. constant) — pass through.
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

    return (ctx) {
      final Object? rawInput =
          property == null ? ctx.zoom : ctx.properties[property];
      if (type == 'categorical') {
        for (var i = 0; i < stopInputs.length; i++) {
          if (_looseEquals(stopInputs[i], rawInput)) return outputs[i];
        }
        return defaultValue;
      }
      final v = toNumber(rawInput);
      if (v == null) return defaultValue;
      if (v <= stops.first) return outputs.first;
      if (v >= stops.last) return outputs.last;
      var hi = 1;
      while (hi < stops.length && stops[hi] < v) {
        hi++;
      }
      final lo = hi - 1;
      if (type == 'interval') return outputs[lo];
      final span = stops[hi] - stops[lo];
      var t = span <= 0 ? 0.0 : (v - stops[lo]) / span;
      if (base != 1.0) {
        final p = math.pow(base, span).toDouble();
        t = p == 1
            ? t
            : (math.pow(base, v - stops[lo]).toDouble() - 1) / (p - 1);
      }
      return _interpolateValues(outputs[lo], outputs[hi], t.clamp(0.0, 1.0));
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
      case 'all':
        final es =
            filter.skip(1).map((f) => parseFilter(f)).toList(growable: false);
        return (ctx) => es.every((e) => toBoolean(e(ctx)));
      case 'any':
        final es =
            filter.skip(1).map((f) => parseFilter(f)).toList(growable: false);
        return (ctx) => es.any((e) => toBoolean(e(ctx)));
      case 'none':
        final es =
            filter.skip(1).map((f) => parseFilter(f)).toList(growable: false);
        return (ctx) => !es.any((e) => toBoolean(e(ctx)));
      case 'has':
        final key = _legacyKey(filter);
        if (key == r'$id') return (ctx) => ctx.featureId != null;
        if (key == r'$type') return (_) => true;
        _refProp(key);
        return (ctx) => ctx.properties.containsKey(key);
      case '!has':
        final key = _legacyKey(filter);
        if (key == r'$id') return (ctx) => ctx.featureId == null;
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
        final negate = op == '!=';
        return (ctx) {
          final actual = _legacyValue(ctx, key);
          switch (op) {
            case '==':
            case '!=':
              final eq = _looseEquals(actual, value);
              return negate ? !eq : eq;
          }
          final na = toNumber(actual);
          final nb = toNumber(value);
          if (na == null || nb == null) {
            if (actual is String && value is String) {
              final cmp = actual.compareTo(value);
              return switch (op) {
                '<' => cmp < 0,
                '<=' => cmp <= 0,
                '>' => cmp > 0,
                _ => cmp >= 0,
              };
            }
            return false;
          }
          return switch (op) {
            '<' => na < nb,
            '<=' => na <= nb,
            '>' => na > nb,
            _ => na >= nb,
          };
        };
      case 'in':
      case '!in':
        final key = _legacyKey(filter);
        _refLegacyKey(key);
        final values = filter.skip(2).toList(growable: false);
        final negate = op == '!in';
        return (ctx) {
          final actual = _legacyValue(ctx, key);
          final contained = values.any((v) => _looseEquals(v, actual));
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
