import 'dart:math' as math;
import 'dart:typed_data';

import 'glyph_pbf.dart';

/// Text laid out from glyph PBF metrics: which glyphs draw where, in
/// [glyphPbfEm]-pixel units relative to the text block's top-left.
///
/// Only glyphs that draw something are listed; spaces only advance the
/// pen. Pure data, built in pure Dart — no `dart:ui` — so it can be
/// produced on any isolate.
class ShapedGlyphs {
  /// The drawn glyphs, in visual (left-to-right, line by line) order.
  final List<SdfGlyph> glyphs;

  /// Per glyph in [glyphs], two values: the pen position (the left
  /// edge of its advance) and the middle of its line.
  final Float32List positions;

  /// The block every line is aligned in: the widest line, and
  /// [lineCount] line heights.
  final double width;
  final double height;
  final int lineCount;

  /// Where each line sits in the block's width: 0 against its left
  /// edge, 0.5 centred, 1 against its right edge (`text-justify`).
  final double justify;

  /// Per glyph in [glyphs], the line it is on; per line, its width.
  final Uint16List _lines;
  final Float32List _lineWidths;

  ShapedGlyphs._(this.glyphs, this.positions, this.width, this.height,
      this.lineCount, this.justify, this._lines, this._lineWidths);

  /// This text with its lines aligned to [justify] instead, as
  /// [shapeGlyphs] would have laid it out with it.
  ShapedGlyphs justified(double justify) {
    if (justify == this.justify || lineCount < 2) return this;
    final moved = Float32List.fromList(positions);
    for (var i = 0; i < glyphs.length; i++) {
      moved[i * 2] +=
          (width - _lineWidths[_lines[i]]) * (justify - this.justify);
    }
    return ShapedGlyphs._(
        glyphs, moved, width, height, lineCount, justify, _lines, _lineWidths);
  }
}

/// Line height in ems — the `text-line-height` default.
const double glyphLineHeightEm = 1.2;

/// Where a glyph's bitmap starts, relative to the middle of its line:
/// MapLibre centres a line on that middle with the font's reference
/// line ([SdfGlyph.top]) this many pixels above it, which for Noto Sans
/// puts the baseline 9 px below the middle and centres capitals on it.
const double glyphLineMiddleToReference = 17;

/// Lays out [text] — which [isGlyphShapeable] accepted — from the glyphs
/// [glyphOf] returns, as MapLibre does: each glyph advanced by its own
/// advance plus [letterSpacingEm], lines broken at [maxWidthEm] (none
/// when null), [lineHeightEm] apart, and aligned in the widest one's
/// width by [justify] (0 left, 0.5 centred, 1 right).
///
/// Lines always break at `\n`, and where text is wider than
/// [maxWidthEm] they may break after a space, a hyphen or dash, a
/// slash, `&`, `+`, a parenthesis, a middle dot, a soft hyphen or a
/// zero-width space. Rather than filling each line greedily, the breaks
/// are chosen as MapLibre chooses them: so that every line comes out
/// close to one target width — the text's whole width over the fewest
/// lines [maxWidthEm] allows — with a shorter last line preferred to a
/// longer one, and a break that leaves an opening parenthesis at the
/// end of a line or a closing one at the start of the next avoided. A
/// line is measured without its spaces for that, as MapLibre measures
/// it. This keeps a two-line name from leaving a single word dangling
/// below a full line, and lets a line run past [maxWidthEm] where that
/// evens the lines out; a word wider than the limit is never split.
///
/// Returns null when [glyphOf] has no glyph for a code point: the
/// caller draws such text some other way rather than with a hole in it.
ShapedGlyphs? shapeGlyphs(
  String text,
  SdfGlyph? Function(int code) glyphOf, {
  double letterSpacingEm = 0,
  double? maxWidthEm,
  double lineHeightEm = glyphLineHeightEm,
  double justify = 0.5,
}) {
  final spacing = letterSpacingEm * glyphPbfEm;
  final maxWidth = maxWidthEm == null ? null : maxWidthEm * glyphPbfEm;
  final run = <(int, SdfGlyph?)>[];
  for (var i = 0; i < text.length; i++) {
    final code = text.codeUnitAt(i);
    if (code == _newline || code == _zeroWidthSpace) {
      run.add((code, null));
      continue;
    }
    final glyph = glyphOf(code);
    if (glyph == null) return null;
    run.add((code, glyph));
  }
  final lines = _breakLines(run, spacing, maxWidth);

  final widths = Float32List.fromList(
      [for (final line in lines) _lineWidth(line, spacing)]);
  final width = widths.fold(0.0, math.max);
  final lineHeight = lineHeightEm * glyphPbfEm;
  final glyphs = <SdfGlyph>[];
  final positions = <double>[];
  final lineOf = <int>[];
  for (var l = 0; l < lines.length; l++) {
    var x = (width - widths[l]) * justify;
    final middle = (l + 0.5) * lineHeight;
    for (final (_, glyph) in lines[l]) {
      if (glyph == null) continue;
      if (glyph.hasBitmap) {
        glyphs.add(glyph);
        positions
          ..add(x)
          ..add(middle);
        lineOf.add(l);
      }
      x += glyph.advance + spacing;
    }
  }
  return ShapedGlyphs._(
      glyphs,
      Float32List.fromList(positions),
      width,
      lines.length * lineHeight,
      lines.length,
      justify,
      Uint16List.fromList(lineOf),
      widths);
}

const _newline = 0x0a;
const _space = 0x20;
const _zeroWidthSpace = 0x200b;

/// What takes no room on a line: a space, a line break, a zero-width
/// space. Trimmed from both ends of every line, and left out of a
/// line's width when breaks are chosen.
bool _blank((int, SdfGlyph?) unit) => unit.$1 == _space || unit.$2 == null;

/// Width of [line] as drawn: every advance and the spacing between
/// glyphs, but neither the blanks at its ends nor the spacing after the
/// last glyph. Leading blanks are dropped from [line] in place, so the
/// line starts with what it draws.
double _lineWidth(List<(int, SdfGlyph?)> line, double spacing) {
  while (line.isNotEmpty && _blank(line.first)) {
    line.removeAt(0);
  }
  var end = line.length;
  while (end > 0 && _blank(line[end - 1])) {
    end--;
  }
  var width = 0.0;
  for (var i = 0; i < end; i++) {
    final glyph = line[i].$2;
    if (glyph != null) width += glyph.advance + spacing;
  }
  return end == 0 ? 0 : width - spacing;
}

/// Whether a line may end after [code] when the text has to wrap.
bool _breakable(int code) =>
    code == _space ||
    code == 0x26 || // &
    code == 0x28 || // (
    code == 0x29 || // )
    code == 0x2b || // +
    code == 0x2d || // hyphen-minus
    code == 0x2f || // slash
    code == 0xad || // soft hyphen
    code == 0xb7 || // middle dot
    code == _zeroWidthSpace ||
    code == 0x2010 || // hyphen
    code == 0x2013; // en dash

/// How much worse than its raggedness a break after [code], before
/// [next], is: an opening parenthesis left at the end of a line, or a
/// closing one starting the next, reads badly. A line break is forced.
double _penalty(int code, int next) {
  if (code == _newline) return -10000;
  var penalty = 0.0;
  if (code == 0x28) penalty += 50;
  if (next == 0x29) penalty += 50;
  return penalty;
}

/// Splits [run] into lines, at every `\n` and, for a [maxWidth], where
/// that balances them as [shapeGlyphs] describes.
List<List<(int, SdfGlyph?)>> _breakLines(
    List<(int, SdfGlyph?)> run, double spacing, double? maxWidth) {
  // The width every glyph takes, spaces included, for the target; and
  // per position the width before it without blanks, which lines are
  // judged by.
  var total = 0.0;
  final inked = Float64List(run.length + 1);
  for (var i = 0; i < run.length; i++) {
    final glyph = run[i].$2;
    final advance = glyph == null ? 0.0 : glyph.advance + spacing;
    total += advance;
    inked[i + 1] = inked[i] + (_blank(run[i]) ? 0 : advance);
  }
  // Break opportunities, as (position the next line starts at, penalty).
  final breaks = <(int, double)>[];
  for (var i = 0; i < run.length - 1; i++) {
    final code = run[i].$1;
    if (code == _newline || (maxWidth != null && _breakable(code))) {
      breaks.add((i + 1, _penalty(code, run[i + 1].$1)));
    }
  }
  if (breaks.isEmpty ||
      (maxWidth != null && total <= maxWidth && !breaks.any((b) => b.$2 < 0))) {
    return [run];
  }
  final target =
      maxWidth == null ? total : total / math.max(1, (total / maxWidth).ceil());

  double badness(double width, double penalty, bool last) {
    final d = width - target;
    final raggedness = d * d;
    if (last) return width < target ? raggedness / 2 : raggedness * 2;
    return raggedness + penalty.abs() * penalty;
  }

  // best[k]: the least bad way to set every line up to break k, where
  // break `breaks.length` is the end of the run; from[k] the break
  // before it (-1: the start). Ties go to the later break, as in
  // MapLibre.
  final n = breaks.length;
  final best = List<double>.filled(n + 1, 0);
  final from = List<int>.filled(n + 1, -1);
  for (var k = 0; k <= n; k++) {
    final last = k == n;
    final at = last ? run.length : breaks[k].$1;
    final penalty = last ? 0.0 : breaks[k].$2;
    best[k] = badness(inked[at], penalty, last);
    from[k] = -1;
    for (var j = 0; j < k; j++) {
      final b =
          best[j] + badness(inked[at] - inked[breaks[j].$1], penalty, last);
      if (b <= best[k]) {
        best[k] = b;
        from[k] = j;
      }
    }
  }
  final starts = <int>[];
  for (var k = from[n]; k >= 0; k = from[k]) {
    starts.add(breaks[k].$1);
  }
  final lines = <List<(int, SdfGlyph?)>>[];
  var start = 0;
  for (final next in starts.reversed) {
    lines.add(run.sublist(start, next));
    start = next;
  }
  lines.add(run.sublist(start));
  return lines;
}
