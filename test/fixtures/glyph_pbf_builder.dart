import 'dart:math' as math;
import 'dart:typed_data';

/// A minimal glyph PBF encoder, written from the glyph PBF schema
/// (`glyphs` → repeated `fontstack` { name = 1, range = 2, repeated
/// `glyph` = 3 } → `glyph` { id = 1, bitmap = 2, width = 3, height = 4,
/// left = 5 (sint32), top = 6 (sint32), advance = 7 }) — independently
/// of `lib/src/text/glyph_pbf.dart`, for the same reason the MVT builder
/// is independent of the MVT decoder.
class GlyphPbfBuilder {
  final _stacks = <List<int>>[];

  /// Adds a font stack holding [glyphs]. [extraFields] are written
  /// before the glyphs as unknown fields a decoder must skip: each entry
  /// is (field number, value), a value being an int (varint) or a
  /// `List<int>` (length-delimited).
  GlyphPbfBuilder stack(
    String name,
    String range,
    List<TestGlyph> glyphs, {
    List<(int, Object)> extraFields = const [],
  }) {
    final out = <int>[];
    _bytesField(out, 1, name.codeUnits);
    _bytesField(out, 2, range.codeUnits);
    for (final (field, value) in extraFields) {
      if (value is int) {
        _varintField(out, field, value);
      } else {
        _bytesField(out, field, value as List<int>);
      }
    }
    for (final glyph in glyphs) {
      _bytesField(out, 3, glyph.encode());
    }
    _stacks.add(out);
    return this;
  }

  Uint8List build() {
    final out = <int>[];
    for (final stack in _stacks) {
      _bytesField(out, 1, stack);
    }
    return Uint8List.fromList(out);
  }
}

/// One glyph to encode. [bitmap] defaults to the distance field of a
/// solid box filling the glyph's [width]×[height] (see [boxField]).
class TestGlyph {
  final int id;
  final int width;
  final int height;
  final int left;
  final int top;
  final int advance;
  final List<int>? bitmap;

  TestGlyph(
    this.id, {
    this.width = 10,
    this.height = 14,
    this.left = 1,
    this.top = -10,
    this.advance = 12,
    List<int>? bitmap,
    bool blank = false,
  }) : bitmap = blank ? null : bitmap ?? boxField(width, height);

  List<int> encode() {
    final out = <int>[];
    _varintField(out, 1, id);
    if (bitmap != null) _bytesField(out, 2, bitmap!);
    _varintField(out, 3, width);
    _varintField(out, 4, height);
    _varintField(out, 5, _zigzag(left));
    _varintField(out, 6, _zigzag(top));
    _varintField(out, 7, advance);
    return out;
  }
}

/// The distance field glyph servers would emit for a solid
/// [width]×[height] box with the usual 3 px border: 192 on the outline,
/// 32 per pixel more inside and less outside, clamped to a byte.
List<int> boxField(int width, int height) {
  const border = 3;
  final w = width + 2 * border;
  final h = height + 2 * border;
  final out = List<int>.filled(w * h, 0);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      // Signed distance from the pixel centre to the box edge, positive
      // inside.
      final px = x + 0.5 - border;
      final py = y + 0.5 - border;
      final inside =
          math.min(math.min(px, width - px), math.min(py, height - py));
      final double d;
      if (inside >= 0) {
        d = inside;
      } else {
        final dx = math.max(0.0, math.max(-px, px - width));
        final dy = math.max(0.0, math.max(-py, py - height));
        d = -math.sqrt(dx * dx + dy * dy);
      }
      out[y * w + x] = (192 + d * 32).round().clamp(0, 255);
    }
  }
  return out;
}

int _zigzag(int v) => v >= 0 ? v * 2 : -v * 2 - 1;

void _varint(List<int> out, int value) {
  var v = value;
  while (v >= 0x80) {
    out.add(v % 0x80 + 0x80);
    v ~/= 0x80;
  }
  out.add(v);
}

void _varintField(List<int> out, int field, int value) {
  _varint(out, field * 8);
  _varint(out, value);
}

void _bytesField(List<int> out, int field, List<int> bytes) {
  _varint(out, field * 8 + 2);
  _varint(out, bytes.length);
  out.addAll(bytes);
}
