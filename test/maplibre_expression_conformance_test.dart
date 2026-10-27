import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:flutter_map_vector_tiles/src/style/expression.dart';
import 'package:flutter_map_vector_tiles/src/style/expression_parser.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/maplibre_expression_fixtures.dart';

/// Every expression fixture of maplibre-style-spec, run through this
/// package's expression engine.
///
/// A fixture MapLibre evaluates has to give MapLibre's outputs here —
/// read the way the renderer reads them, through the typed property
/// wrappers — unless it is listed in [_divergences] with the reason it
/// does not. A listed fixture that starts passing fails too, so the
/// list only ever shrinks with the code.
///
/// Fixtures MapLibre *rejects* are not compared: this parser is tolerant
/// by design and degrades per property instead (see
/// `lib/src/style/AGENTS.md`). They only have to compile without
/// throwing.
void main() {
  final fixtures = (jsonDecode(maplibreExpressionFixturesJson) as Map)
      .cast<String, Map<String, Object?>>();

  test('the fixture set is the one the divergence list was made for', () {
    expect(fixtures, hasLength(583));
    for (final name in _divergences.keys) {
      expect(fixtures, contains(name), reason: 'stale divergence $name');
    }
  });

  for (final MapEntry(key: name, value: fixture) in fixtures.entries) {
    test(name, () {
      final outcome = _run(fixture);
      final divergence = _divergences[name];
      if (outcome == null) {
        expect(divergence, isNull,
            reason: '$name now matches MapLibre — remove it from '
                '_divergences');
      } else {
        expect(divergence, isNotNull, reason: outcome);
      }
    });
  }
}

/// Why a fixture's outcome here differs from MapLibre's.
const _divergences = <String, String>{
  // A test-only operator of MapLibre's suite, not part of the spec.
  'all/short-circuiting': _testOnly,
  'any/short-circuiting': _testOnly,

  'collator/accent-lt-en': _collator,
  'collator/accent-not-equals-en': _collator,
  'collator/base-equals-en': _collator,
  'collator/base-gt-en': _collator,
  'collator/case-lteq-en': _collator,
  'collator/case-not-equals-en': _collator,
  'collator/case-omitted-en': _collator,
  'collator/diacritic-omitted-en': _collator,
  'collator/variant-gteq-en': _collator,
  'collator/variable-equals': _collator,
  'collator/variable-gt': _collator,
  'collator/variable-lteq': _collator,
  'collator/variable-not-equals': _collator,
  'equal/collator-value': _collator,

  // Properties this package does not draw, whose types MapLibre boxes.
  'interpolate-hcl/linear-color-array': _unsupportedType,
  'interpolate-lab/linear-color-array': _unsupportedType,
  'interpolate/linear-color-array': _unsupportedType,
  'interpolate/projection/global-state': _unsupportedType,
  'interpolate/projection/linear': _unsupportedType,
  'interpolate/projection/same-from-to': _unsupportedType,
  'global-state/projection-invalid-value': 'no projection is drawn, so '
      'nothing parses the value as one: 42 is handed on, where MapLibre '
      'fails to read it as a projection',
  'legacy/identity/color_array': _unsupportedType,
  'legacy/identity/number_array': _unsupportedType,
  'legacy/identity/padding': _unsupportedType,

  'distance/from-line/to-polygon-hole': _float32,
  'distance/from-line/to-polygon-nearby': _float32,
  'distance/from-point/to-polygon-hole': _float32,
  'distance/from-point/to-polygon-nearby': _float32,
  'distance/from-simple-polygon/to-polygon-hole': _float32,
  'distance/from-simple-polygon/to-polygon-outside': _float32,

  'to-rgba/alpha': _alpha8Bit,
  'to-string/color': _alpha8Bit,

  'elevation/basic': 'no raster-dem source or color-relief layer is drawn, '
      'so `elevation` is always null',
  'heatmap-density/basic': 'heatmap layers are not drawn yet',
  'feature-state/basic': 'feature state is not supported yet: '
      '`feature-state` is always null',
  'feature-state/expression-arg': 'feature state is not supported yet: '
      '`feature-state` is always null',
  'format/data-driven-font': _formatOverrides,
  'format/data-driven-vertical-align': _formatOverrides,
  'image/coalesce': 'image availability is not known when expressions '
      'are compiled: `image` always yields its name',
  'is-supported-script/default': 'every script is drawn through the '
      'platform text stack: `is-supported-script` is always true',
  'legacy/interval/tokens-zoom': _tokens,
  'max/arity-0': _nonFinite,
  'min/arity-0': _nonFinite,
  'number-format/precision': '`intl` formats through 64-bit integers: '
      'fraction digits are capped at 15 significant digits, not padded '
      'with zeros past them',
};

const _testOnly = "uses MapLibre's test-only `error` operator";
const _collator = 'collators are not implemented: strings compare by '
    'code unit whatever the locale, case or diacritic options';
const _unsupportedType = 'the value is right, but for a property type '
    '(projection, padding, number or color array) nothing here draws';
const _float32 = 'harness limit: the fixture polygon spans ~10^8 tile '
    'units at z20, beyond what the 32-bit tile coordinates hold to the '
    'centimetre (real tiles hold only their own few thousand units)';
const _alpha8Bit = 'colours keep 8-bit alpha: 0.5 reads back as 128/255';
const _formatOverrides = '`format` style overrides (fonts, scale, '
    'alignment) are ignored, so their inputs are never read';
const _tokens = 'legacy `{token}` templates are expanded by the theme '
    'reader, which this harness does not run: the template reads the '
    'feature there';
const _nonFinite = 'non-finite numbers are not numbers here: `max` of '
    'nothing is null, not -Infinity';

/// Null when [fixture] matches MapLibre, else what differs.
String? _run(Map<String, Object?> fixture) {
  final expected = fixture['expected'] as Map<String, Object?>? ?? const {};
  final compiled = expected['compiled'] as Map<String, Object?>? ?? const {};
  final spec = (fixture['propertySpec'] as Map?)?.cast<String, Object?>();
  final globalState =
      (fixture['globalState'] as Map?)?.cast<String, Object?>() ?? const {};
  final parser = ExpressionParser(globalState: globalState);
  final parsed = parser.parseForProperty(fixture['expression'],
      accepts: _accepts(spec),
      enumValues: (spec?['values'] as Map?)?.keys.cast<String>().toSet());
  if (compiled['result'] == 'error') return null;
  if (parser.warnings.isNotEmpty) {
    return 'warns on a valid expression: ${parser.warnings.join('; ')}';
  }
  // The memo and filter caches trust these two flags; MapLibre's
  // analysis of the same expression must not find it more dynamic.
  if (parsed.zoomOnly && compiled['isFeatureConstant'] == false) {
    return 'claims zoom-only, but reads the feature';
  }
  if (!parser.readsZoom && compiled['isZoomConstant'] == false) {
    return 'claims zoom-free, but reads the zoom';
  }
  final type = compiled['type'] as String? ?? '';
  final mismatches = <String>[];
  final inputs = (fixture['inputs'] as List?) ?? const [];
  final outputs = (expected['outputs'] as List?) ?? const [];
  for (var i = 0; i < inputs.length && i < outputs.length; i++) {
    final input = inputs[i] as List;
    final globals = (input[0] as Map).cast<String, Object?>();
    final feature = (input[1] as Map).cast<String, Object?>();
    final geometry = (feature['geometry'] as Map?)?.cast<String, Object?>();
    final ctx = featureContext(
      zoom: (globals['zoom'] as num?)?.toDouble() ?? 0,
      properties:
          (feature['properties'] as Map?)?.cast<String, Object?>() ?? const {},
      featureId: feature['id'],
      geometryType: switch (geometry?['type']) {
        'Point' || 'MultiPoint' => 'Point',
        'LineString' || 'MultiLineString' => 'LineString',
        'Polygon' || 'MultiPolygon' => 'Polygon',
        _ => '',
      },
      geometry: _geometry(
          geometry, (globals['canonicalID'] as Map?)?.cast<String, Object?>()),
    );
    final actual = _asProperty(parsed.expr(ctx), spec, type);
    final want = _expected(outputs[i], type);
    if (!_matches(actual, want, spec, type)) {
      mismatches.add('input $i: MapLibre ${jsonEncode(_show(want))}, '
          'here ${jsonEncode(_show(actual))}');
    }
  }
  return mismatches.isEmpty ? null : mismatches.join('; ');
}

/// A MapLibre evaluation error, which leaves the property at its
/// default.
const _error = _Marker('ERROR');

/// Our engine's null, which leaves the property at its default too.
const _fallback = _Marker('FALLBACK');

class _Marker {
  final String name;
  const _Marker(this.name);
}

Object? _show(Object? v) => v is _Marker ? v.name : v;

/// A fixture's GeoJSON feature as the tile geometry the renderer hands
/// expressions: quantized to an 8192 extent at the fixture's zoom, as
/// MapLibre's own fixture runner does — but in the tile that holds its
/// first coordinate. Fixtures place features anywhere in the world
/// against any tile of the zoom, and coordinates thousands of tiles
/// outside their own tile overflow the 32-bit floats tile geometry is
/// kept in; a real tile only holds its own features. The world grid —
/// and with it the quantization — is the same either way.
FeatureGeometry? _geometry(
    Map<String, Object?>? geometry, Map<String, Object?>? canonical) {
  if (geometry == null || canonical == null) return null;
  final z = (canonical['z'] as num).toInt();
  const extent = 8192;
  final tiles = math.pow(2, z).toDouble();
  List<double> world(Object? p) {
    final c = p as List;
    final lng = (c[0] as num).toDouble(), lat = (c[1] as num).toDouble();
    final mx = (180 + lng) / 360;
    final my = (180 -
            (180 / math.pi) *
                math.log(math.tan(math.pi / 4 + lat * math.pi / 360))) /
        360;
    return [
      (mx * tiles * extent).roundToDouble(),
      (my * tiles * extent).roundToDouble(),
    ];
  }

  final coordinates = geometry['coordinates'];
  Object? first = coordinates;
  while (first is List && first.isNotEmpty && first.first is List) {
    first = first.first;
  }
  if (first is! List) return null;
  final origin = world(first);
  final x = (origin[0] / extent).floor();
  final y = (origin[1] / extent).floor();
  List<double> point(Object? p) {
    final w = world(p);
    return [w[0] - x * extent, w[1] - y * extent];
  }

  Float32List run(Object? coords) =>
      Float32List.fromList([for (final p in coords as List) ...point(p)]);

  final (String type, List<Float32List> parts) = switch (geometry['type']) {
    'Point' => ('Point', [Float32List.fromList(point(coordinates))]),
    'MultiPoint' => ('Point', [run(coordinates)]),
    'LineString' => ('LineString', [run(coordinates)]),
    'MultiLineString' => (
        'LineString',
        [for (final l in coordinates as List) run(l)]
      ),
    'Polygon' => ('Polygon', [for (final r in coordinates as List) run(r)]),
    'MultiPolygon' => (
        'Polygon',
        [
          for (final p in coordinates as List)
            for (final r in p as List) run(r),
        ]
      ),
    _ => ('', <Float32List>[]),
  };
  return FeatureGeometry(
      z: z, x: x, y: y, extent: extent, type: type, parts: parts);
}

/// MapLibre's expected output in the shapes [_asProperty] produces.
Object? _expected(Object? v, String type) {
  if (v is Map && v.length == 1 && v.containsKey('error')) return _error;
  if (type == 'formatted' && v is Map && v['sections'] is List) {
    return [for (final s in v['sections'] as List) (s as Map)['text'] ?? '']
        .join();
  }
  if (type == 'resolvedImage' && v is Map) return v['name'];
  // Property types MapLibre boxes (padding, numberArray, colorArray,
  // variableAnchorOffsetCollection): compare what is inside.
  if (v is Map && v.length == 1 && v.containsKey('values')) {
    final values = v['values'];
    if (values is List) {
      return [
        for (final e in values)
          e is Map && e.containsKey('r') ? [e['r'], e['g'], e['b'], e['a']] : e,
      ];
    }
  }
  return v;
}

/// What the theme reader tells the parser a property of [spec]'s type
/// takes (`ThemeReader._double`, `_color`, `_string`, `_enum`, …).
bool Function(Object?)? _accepts(Map<String, Object?>? spec) {
  switch (spec?['type']) {
    case 'number':
      return (v) => v is num;
    case 'color':
      return (v) => toColor(v) != null;
    case 'string' || 'enum':
      return (v) => v is String;
    case 'boolean':
      return (v) => v is bool;
    case 'array':
      final length = (spec!['length'] as num?)?.toInt();
      return switch (spec['value']) {
        'number' => (v) => asNumberList(v, length) != null,
        'string' => (v) => asStringList(v) != null,
        _ => null,
      };
  }
  return null;
}

/// The value as the renderer reads it: [_fallback] for null and for an
/// error — every typed property falls back to its default there —
/// through the reading of `DoubleProp`, `StringProp`, `ColorProp`,
/// `BoolProp`, `NumListProp` and `StringListProp` where the fixture
/// names the property type, and colours as MapLibre's premultiplied
/// [r, g, b, a].
Object? _asProperty(Object? v, Map<String, Object?>? spec, String type) {
  if (v == null || identical(v, evalError)) return _fallback;
  final propertyType = spec?['type'];
  switch (propertyType is String ? propertyType : type) {
    case 'color':
      final c = toColor(v);
      return c == null ? _fallback : _rgba(c);
    case 'number' when propertyType == 'number':
      return asNumber(v) ?? _fallback;
    case 'string' || 'formatted':
      return toStringValue(v);
    case 'boolean' when propertyType == 'boolean':
      return v is bool ? v : _fallback;
    case 'array' when propertyType == 'array' && spec!['value'] == 'number':
      return asNumberList(v, (spec['length'] as num?)?.toInt()) ?? _fallback;
    case 'array' when propertyType == 'array' && spec!['value'] == 'string':
      return asStringList(v) ?? _fallback;
    default:
      return _plain(v);
  }
}

List<double> _rgba(Color c) => [c.r * c.a, c.g * c.a, c.b * c.a, c.a];

Object? _plain(Object? v) {
  if (v is Color) return _rgba(v);
  if (v is num) return v.toDouble();
  if (v is List) return [for (final e in v) _plain(e)];
  if (v is Map) return {for (final e in v.entries) e.key: _plain(e.value)};
  return v;
}

/// Falling back here matches an error there, and matches the default
/// the fixture expects where MapLibre falls through to it — the
/// property's own, or the empty text of a text property.
bool _matches(
    Object? actual, Object? want, Map<String, Object?>? spec, String type) {
  if (identical(actual, _fallback)) {
    if (identical(want, _error) || want == null) return true;
    final fallback = spec?['default'] ??
        (type == 'string' || type == 'formatted' ? '' : null);
    return fallback != null &&
        _deepEquals(_asProperty(fallback, spec, type), want, type == 'color');
  }
  if (identical(want, _error)) return false;
  return _deepEquals(actual, want, type == 'color');
}

bool _deepEquals(Object? a, Object? b, bool color) {
  if (a is num && b is num) {
    return _numEquals(a.toDouble(), b.toDouble(), color);
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_deepEquals(a[i], b[i], color)) return false;
    }
    return true;
  }
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final k in a.keys) {
      if (!b.containsKey(k) || !_deepEquals(a[k], b[k], color)) return false;
    }
    return true;
  }
  return a == b;
}

/// MapLibre compares at six significant digits, truncating the expected
/// value; colours carry 8-bit channels here.
bool _numEquals(double a, double b, bool color) {
  if (a == b) return true;
  if (color && (a - b).abs() <= 2.5 / 255) return true;
  final magnitude = b == 0 ? a.abs() : b.abs();
  final digits = (math.log(magnitude) / math.ln10).ceil();
  final unit = math.pow(10, -math.max(0, 6 - digits)).toDouble();
  final d = (a - b).abs();
  // Below a micrometre (`distance` between quantized points) the last
  // digit is float noise on both sides.
  return d <= 1.5 * unit || d <= 2e-5 * magnitude || d < 1e-7;
}
