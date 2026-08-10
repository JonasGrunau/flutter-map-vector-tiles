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
    // Non-finite first, before the int test: under dart2js `infinity
    // is int` is TRUE (JS numbers without a fractional part type as
    // int) and round() throws on it. Decoded tiles can legally carry
    // non-finite doubles, and this runs uncaught on the main isolate
    // via text-field tokens.
    if (!v.isFinite) return v.toString();
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
///
/// When [zoomOnly] is set — the theme reader proved at compile time
/// that the expression reads no feature data — the *coerced* result is
/// memoized against `ctx.zoom`. A tile pass and a label frame each run
/// at one fixed zoom, so thousands of identical ramp evaluations (and
/// their `toNumber`/`toColor` coercions) collapse into one.
///
/// [isConstant] promises that the expression always yields [fallback]
/// (only [DoubleProp.constant] constructs that shape).
class DoubleProp {
  final Expr _expr;
  final double fallback;
  final bool isConstant;
  final bool zoomOnly;
  double _memoZoom = double.nan;
  double _memoValue = 0;

  DoubleProp(this._expr, this.fallback,
      {this.isConstant = false, this.zoomOnly = false});

  factory DoubleProp.constant(double value) =>
      DoubleProp((_) => value, value, isConstant: true);

  double eval(EvalContext ctx) {
    if (isConstant) return fallback;
    if (zoomOnly) {
      if (ctx.zoom == _memoZoom) return _memoValue;
      _memoZoom = ctx.zoom;
      return _memoValue = toNumber(_expr(ctx)) ?? fallback;
    }
    return toNumber(_expr(ctx)) ?? fallback;
  }
}

/// See [DoubleProp] for [isConstant]/[zoomOnly] semantics.
class ColorProp {
  final Expr _expr;
  final Color fallback;
  final bool isConstant;
  final bool zoomOnly;
  double _memoZoom = double.nan;
  Color _memoValue = const Color(0x00000000);

  ColorProp(this._expr, this.fallback,
      {this.isConstant = false, this.zoomOnly = false});

  factory ColorProp.constant(Color value) =>
      ColorProp((_) => value, value, isConstant: true);

  Color eval(EvalContext ctx) {
    if (isConstant) return fallback;
    if (zoomOnly) {
      if (ctx.zoom == _memoZoom) return _memoValue;
      _memoZoom = ctx.zoom;
      return _memoValue = toColor(_expr(ctx)) ?? fallback;
    }
    return toColor(_expr(ctx)) ?? fallback;
  }
}

/// See [DoubleProp] for [zoomOnly] semantics.
class StringProp {
  final Expr _expr;
  final String fallback;
  final bool zoomOnly;
  double _memoZoom = double.nan;
  String _memoValue = '';

  StringProp(this._expr, this.fallback, {this.zoomOnly = false});

  factory StringProp.constant(String value) => StringProp((_) => value, value);

  String eval(EvalContext ctx) {
    if (zoomOnly) {
      if (ctx.zoom == _memoZoom) return _memoValue;
      _memoZoom = ctx.zoom;
      return _memoValue = _eval(ctx);
    }
    return _eval(ctx);
  }

  String _eval(EvalContext ctx) {
    final v = _expr(ctx);
    return v == null ? fallback : toStringValue(v);
  }
}

/// See [DoubleProp] for [zoomOnly] semantics.
class BoolProp {
  final Expr _expr;
  final bool fallback;
  final bool zoomOnly;
  double _memoZoom = double.nan;
  bool _memoValue = false;

  BoolProp(this._expr, this.fallback, {this.zoomOnly = false});

  factory BoolProp.constant(bool value) => BoolProp((_) => value, value);

  bool eval(EvalContext ctx) {
    if (zoomOnly) {
      if (ctx.zoom == _memoZoom) return _memoValue;
      _memoZoom = ctx.zoom;
      final v = _expr(ctx);
      return _memoValue = v == null ? fallback : toBoolean(v);
    }
    final v = _expr(ctx);
    return v == null ? fallback : toBoolean(v);
  }
}

/// Numeric list property (e.g. line-dasharray, text-offset).
///
/// List properties are almost always literal in real styles yet are
/// evaluated per feature and per label per frame, so literal values get
/// a pre-converted list via [NumListProp.constant] instead of being
/// rebuilt and re-coerced on every call.
class NumListProp {
  final Expr _expr;
  final List<double> fallback;
  final List<double>? _constant;
  final bool zoomOnly;
  double _memoZoom = double.nan;
  List<double>? _memoValue;

  NumListProp(this._expr, this.fallback, {this.zoomOnly = false})
      : _constant = null;

  NumListProp.constant(List<double> value)
      : _expr = constExpr(value),
        fallback = value,
        _constant = List.unmodifiable(value),
        zoomOnly = false;

  List<double> eval(EvalContext ctx) {
    final constant = _constant;
    if (constant != null) return constant;
    if (zoomOnly) {
      if (ctx.zoom == _memoZoom) return _memoValue!;
      _memoZoom = ctx.zoom;
      return _memoValue = _eval(ctx);
    }
    return _eval(ctx);
  }

  List<double> _eval(EvalContext ctx) {
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

/// String list property (e.g. text-font). Literal values get a
/// pre-converted list via [StringListProp.constant] — see [NumListProp].
class StringListProp {
  final Expr _expr;
  final List<String> fallback;
  final List<String>? _constant;
  final bool zoomOnly;
  double _memoZoom = double.nan;
  List<String>? _memoValue;

  StringListProp(this._expr, this.fallback, {this.zoomOnly = false})
      : _constant = null;

  StringListProp.constant(List<String> value)
      : _expr = constExpr(value),
        fallback = value,
        _constant = List.unmodifiable(value),
        zoomOnly = false;

  List<String> eval(EvalContext ctx) {
    final constant = _constant;
    if (constant != null) return constant;
    if (zoomOnly) {
      if (ctx.zoom == _memoZoom) return _memoValue!;
      _memoZoom = ctx.zoom;
      return _memoValue = _eval(ctx);
    }
    return _eval(ctx);
  }

  List<String> _eval(EvalContext ctx) {
    final v = _expr(ctx);
    if (v is List) return v.map(toStringValue).toList();
    if (v is String) return [v];
    return fallback;
  }
}
