import 'dart:math' as math;

import 'package:intl/intl.dart';

/// The `number-format` operator: [value] in [locale]'s digits and
/// separators (`Intl.defaultLocale`, else en_US, when absent or
/// unknown), as an amount of [currency] (an ISO 4217 code) or a
/// quantity of [unit] (an ECMA-402 unit identifier such as `meter` or
/// `kilometer-per-hour`) when given. Fraction digits default to what
/// the locale uses — up to three for plain numbers, the currency's own
/// for amounts.
///
/// Unit symbols are the English short forms in every locale (`m`, `km`,
/// `°C`, `kB`): `intl` formats numbers and currencies per locale, but
/// has no unit data.
String formatNumber(
  double value, {
  String? locale,
  String? currency,
  String? unit,
  int? minFractionDigits,
  int? maxFractionDigits,
}) {
  // `intl` rounds through 64-bit integers: past about 15 significant
  // digits it overflows into garbage rather than into zeros. Doubles
  // hold no more than that anyway.
  final room = math.max(0, 15 - _integerDigits(value));
  if (maxFractionDigits != null) {
    maxFractionDigits = math.min(maxFractionDigits, room);
  }
  if (minFractionDigits != null) {
    minFractionDigits = math.min(minFractionDigits, room);
  }
  final format = _formats.putIfAbsent(
      (locale, currency, minFractionDigits, maxFractionDigits), () {
    if (_formats.length >= _maxFormats) _formats.clear();
    final resolved = Intl.verifiedLocale(locale, NumberFormat.localeExists,
        onFailure: (_) => null);
    final f = currency != null
        ? NumberFormat.simpleCurrency(locale: resolved, name: currency)
        : NumberFormat.decimalPattern(resolved);
    if (maxFractionDigits != null) {
      f.maximumFractionDigits = maxFractionDigits.clamp(0, 20);
    }
    if (minFractionDigits != null) {
      f.minimumFractionDigits = minFractionDigits.clamp(0, 20);
    }
    return f;
  });
  final number = format.format(value);
  if (unit == null || currency != null) return number;
  final symbol = _unitSymbol(unit, value);
  return _unspaced.contains(unit) ? '$number$symbol' : '$number $symbol';
}

int _integerDigits(double value) {
  final magnitude = value.abs();
  if (!magnitude.isFinite || magnitude < 1) return 1;
  return (math.log(magnitude) / math.ln10).floor() + 1;
}

/// Built formats, by locale, currency and fraction digits: building
/// one parses its locale's pattern, while a style evaluates the same few
/// formats for every feature. Cleared when full — a style that computes
/// its locale per feature must not grow it without bound.
final _formats = <(String?, String?, int?, int?), NumberFormat>{};
const _maxFormats = 32;

String _unitSymbol(String unit, double value) {
  final per = unit.indexOf('-per-');
  if (per > 0) {
    final compound = _compoundUnits[unit];
    if (compound != null) return compound;
    return '${_unitSymbol(unit.substring(0, per), 1)}/'
        '${_unitSymbol(unit.substring(per + 5), 1)}';
  }
  final plural = _pluralUnits[unit];
  if (plural != null) return value == 1 ? plural.$1 : plural.$2;
  return _units[unit] ?? unit;
}

/// Units written against the number, as `1,234.5°C` and `50%`.
const _unspaced = {'celsius', 'fahrenheit', 'percent'};

const _compoundUnits = {
  'kilometer-per-hour': 'km/h',
  'mile-per-hour': 'mph',
  'mile-per-gallon': 'mpg',
};

const _pluralUnits = {
  'day': ('day', 'days'),
  'week': ('wk', 'wks'),
  'month': ('mth', 'mths'),
  'year': ('yr', 'yrs'),
};

/// The ECMA-402 sanctioned simple units, as English short symbols.
const _units = {
  'acre': 'ac',
  'bit': 'bit',
  'byte': 'byte',
  'celsius': '°C',
  'centimeter': 'cm',
  'degree': 'deg',
  'fahrenheit': '°F',
  'fluid-ounce': 'fl oz',
  'foot': 'ft',
  'gallon': 'gal',
  'gigabit': 'Gb',
  'gigabyte': 'GB',
  'gram': 'g',
  'hectare': 'ha',
  'hour': 'hr',
  'inch': 'in',
  'kilobit': 'kb',
  'kilobyte': 'kB',
  'kilogram': 'kg',
  'kilometer': 'km',
  'liter': 'L',
  'megabit': 'Mb',
  'megabyte': 'MB',
  'meter': 'm',
  'microsecond': 'μs',
  'mile': 'mi',
  'mile-scandinavian': 'smi',
  'milliliter': 'mL',
  'millimeter': 'mm',
  'millisecond': 'ms',
  'minute': 'min',
  'nanosecond': 'ns',
  'ounce': 'oz',
  'percent': '%',
  'petabyte': 'PB',
  'pound': 'lb',
  'second': 'sec',
  'stone': 'st',
  'terabit': 'Tb',
  'terabyte': 'TB',
  'yard': 'yd',
};
