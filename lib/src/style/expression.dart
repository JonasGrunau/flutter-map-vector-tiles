import 'dart:ui' show Color;

import 'css_color.dart';

/// Evaluation context for compiled style expressions.
class EvalContext {
  /// The zoom the style is being evaluated at (style zoom, i.e. camera zoom
  /// plus the layer's tile offset).
  final double zoom;

  /// Feature properties; empty for zoom-only evaluation (e.g. background).
  final Map<String, Object?> properties;

  /// 'Point', 'LineString' or 'Polygon' (MapLibre `$type` semantics).
  final String geometryType;

  final Object? featureId;

  /// Bindings introduced by `let`.
  final Map<String, Object?>? vars;

  const EvalContext({
    required this.zoom,
    this.properties = const {},
    this.geometryType = '',
    this.featureId,
    this.vars,
  });

  EvalContext withVars(Map<String, Object?> newVars) => EvalContext(
        zoom: zoom,
        properties: properties,
        geometryType: geometryType,
        featureId: featureId,
        vars: {...?vars, ...newVars},
      );

  static const empty = EvalContext(zoom: 0);
}

/// A compiled style expression.
typedef Expr = Object? Function(EvalContext ctx);

// ---------------------------------------------------------------------------
// Coercions (MapLibre "to-*" semantics, lenient).

double? toNumber(Object? v) {
  if (v is num) {
    final d = v.toDouble();
    return d.isFinite ? d : null;
  }
  if (v is String) return double.tryParse(v);
  if (v is bool) return v ? 1 : 0;
  return null;
}

bool toBoolean(Object? v) {
  if (v == null) return false;
  if (v is bool) return v;
  if (v is num) return v != 0 && !(v is double && v.isNaN);
  if (v is String) return v.isNotEmpty;
  return true;
}

String toStringValue(Object? v) {
  if (v == null) return '';
  if (v is String) return v;
  if (v is bool) return v ? 'true' : 'false';
  if (v is num) {
    if (v is int || v == v.roundToDouble()) return v.round().toString();
    return v.toString();
  }
  if (v is Color) {
    double chan(double c) => (c * 255).roundToDouble();
    return 'rgba(${chan(v.r).round()},${chan(v.g).round()},'
        '${chan(v.b).round()},${v.a})';
  }
  return v.toString();
}

Color? toColor(Object? v) {
  if (v is Color) return v;
  if (v is String) return parseCssColor(v);
  if (v is List && v.length >= 3) {
    final r = toNumber(v[0]);
    final g = toNumber(v[1]);
    final b = toNumber(v[2]);
    final a = v.length > 3 ? (toNumber(v[3]) ?? 1.0) : 1.0;
    if (r == null || g == null || b == null) return null;
    return Color.fromARGB(
      (a.clamp(0.0, 1.0) * 255).round(),
      r.round().clamp(0, 255),
      g.round().clamp(0, 255),
      b.round().clamp(0, 255),
    );
  }
  return null;
}

// ---------------------------------------------------------------------------
// Typed property accessors used by theme layers.

Expr constExpr(Object? value) => (_) => value;

/// A typed wrapper around a compiled [Expr] with a fallback value.
class DoubleProp {
  final Expr _expr;
  final double fallback;
  final bool isConstant;

  const DoubleProp(this._expr, this.fallback, {this.isConstant = false});

  factory DoubleProp.constant(double value) =>
      DoubleProp((_) => value, value, isConstant: true);

  double eval(EvalContext ctx) => toNumber(_expr(ctx)) ?? fallback;
}

class ColorProp {
  final Expr _expr;
  final Color fallback;
  final bool isConstant;

  const ColorProp(this._expr, this.fallback, {this.isConstant = false});

  factory ColorProp.constant(Color value) =>
      ColorProp((_) => value, value, isConstant: true);

  Color eval(EvalContext ctx) => toColor(_expr(ctx)) ?? fallback;
}

class StringProp {
  final Expr _expr;
  final String fallback;

  const StringProp(this._expr, this.fallback);

  factory StringProp.constant(String value) => StringProp((_) => value, value);

  String eval(EvalContext ctx) {
    final v = _expr(ctx);
    return v == null ? fallback : toStringValue(v);
  }
}

class BoolProp {
  final Expr _expr;
  final bool fallback;

  const BoolProp(this._expr, this.fallback);

  factory BoolProp.constant(bool value) => BoolProp((_) => value, value);

  bool eval(EvalContext ctx) {
    final v = _expr(ctx);
    return v == null ? fallback : toBoolean(v);
  }
}

/// Numeric list property (e.g. line-dasharray, text-offset).
class NumListProp {
  final Expr _expr;
  final List<double> fallback;

  const NumListProp(this._expr, this.fallback);

  List<double> eval(EvalContext ctx) {
    final v = _expr(ctx);
    if (v is List) {
      final out = <double>[];
      for (final e in v) {
        final n = toNumber(e);
        if (n == null) return fallback;
        out.add(n);
      }
      return out;
    }
    return fallback;
  }
}

class StringListProp {
  final Expr _expr;
  final List<String> fallback;

  const StringListProp(this._expr, this.fallback);

  List<String> eval(EvalContext ctx) {
    final v = _expr(ctx);
    if (v is List) return v.map(toStringValue).toList();
    if (v is String) return [v];
    return fallback;
  }
}
