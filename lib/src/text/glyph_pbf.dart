import 'dart:typed_data';

/// Size, in pixels, glyph PBFs render their glyphs at: one em of every
/// metric in a [SdfGlyph].
const double glyphPbfEm = 24;

/// Transparent border around every glyph bitmap, in [glyphPbfEm]
/// pixels: the room the distance field needs to fall off outside the
/// outline, and the most halo a glyph can carry.
const int glyphPbfBorder = 3;

/// One glyph of a glyph PBF range: its signed distance field and the
/// metrics to position it, all in [glyphPbfEm] pixels.
///
/// The bitmap is `(width + 2·border) × (height + 2·border)` bytes, one
/// per pixel: 192 (0.75) on the outline, rising inside and falling by
/// 32 per pixel outside it — MapLibre's encoding, which every glyph
/// server produces.
class SdfGlyph {
  /// The Unicode code point.
  final int id;
  final int width;
  final int height;

  /// Horizontal offset from the pen position to the bitmap's left
  /// edge, border excluded.
  final int left;

  /// How far the bitmap's top edge, border excluded, lies above the
  /// font's reference line (negative: below it). That line sits a fixed
  /// distance above the baseline for every glyph of a font — 26 px for
  /// Noto Sans — so a capital H of 17 px has a `top` of -9.
  final int top;
  final int advance;

  /// The distance field, or null for glyphs that draw nothing (spaces).
  final Uint8List? bitmap;

  /// Where [bitmap] sits on its range's SDF page, border included —
  /// set when the page is packed.
  int pageX = 0;
  int pageY = 0;

  SdfGlyph({
    required this.id,
    required this.width,
    required this.height,
    required this.left,
    required this.top,
    required this.advance,
    required this.bitmap,
  });

  /// Bitmap width, border included.
  int get bitmapWidth => width + 2 * glyphPbfBorder;

  /// Bitmap height, border included.
  int get bitmapHeight => height + 2 * glyphPbfBorder;

  /// Whether the glyph draws anything.
  bool get hasBitmap {
    final bitmap = this.bitmap;
    return bitmap != null &&
        width > 0 &&
        height > 0 &&
        bitmap.length >= bitmapWidth * bitmapHeight;
  }
}

/// Decodes a glyph PBF (`{fontstack}/{range}.pbf`): the glyphs of every
/// font stack it holds, keyed by code point. Servers send one stack per
/// file; if several arrive, later ones only fill gaps.
Map<int, SdfGlyph> decodeGlyphPbf(Uint8List bytes) {
  final glyphs = <int, SdfGlyph>{};
  final r = _PbfReader(bytes, 0, bytes.length);
  while (!r.atEnd) {
    final tag = r.varint();
    if (tag == 10) {
      // field 1, wire 2 — fontstack
      final stack = r.message();
      while (!stack.atEnd) {
        final t = stack.varint();
        if (t == 26) {
          // field 3, wire 2 — glyph
          final glyph = _decodeGlyph(stack.message());
          if (glyph != null) glyphs.putIfAbsent(glyph.id, () => glyph);
        } else {
          stack.skip(t & 7);
        }
      }
    } else {
      r.skip(tag & 7);
    }
  }
  return glyphs;
}

SdfGlyph? _decodeGlyph(_PbfReader r) {
  int? id;
  Uint8List? bitmap;
  var width = 0, height = 0, left = 0, top = 0, advance = 0;
  while (!r.atEnd) {
    final tag = r.varint();
    switch (tag) {
      case 8: // field 1, varint — id
        id = r.varint();
      case 18: // field 2, bytes — bitmap
        bitmap = r.bytes();
      case 24: // field 3 — width
        width = r.varint();
      case 32: // field 4 — height
        height = r.varint();
      case 40: // field 5, sint32 — left
        left = _zigzag(r.varint());
      case 48: // field 6, sint32 — top
        top = _zigzag(r.varint());
      case 56: // field 7 — advance
        advance = r.varint();
      default:
        r.skip(tag & 7);
    }
  }
  if (id == null) return null;
  return SdfGlyph(
    id: id,
    width: width,
    height: height,
    left: left,
    top: top,
    advance: advance,
    bitmap: bitmap,
  );
}

// Arithmetic rather than bitwise, as in the MVT decoder: the values here
// are small, but dart2js truncates bitwise operands to 32 bits.
int _zigzag(int value) {
  final sign = value % 2;
  final half = value ~/ 2;
  return half - (half + half + 1) * sign;
}

/// The protobuf wire format, as far as glyph PBFs use it.
class _PbfReader {
  final Uint8List _bytes;
  int _pos;
  final int _end;

  _PbfReader(this._bytes, this._pos, this._end);

  bool get atEnd => _pos >= _end;

  int varint() {
    var result = 0;
    var multiplier = 1;
    for (var i = 0; i < 10; i++) {
      if (_pos >= _end) throw const FormatException('truncated varint');
      final byte = _bytes[_pos++];
      result += (byte & 0x7f) * multiplier;
      if (byte & 0x80 == 0) return result;
      multiplier *= 128;
    }
    throw const FormatException('varint too long');
  }

  Uint8List bytes() {
    final length = varint();
    if (_pos + length > _end) throw const FormatException('truncated bytes');
    final view = Uint8List.sublistView(_bytes, _pos, _pos + length);
    _pos += length;
    return view;
  }

  _PbfReader message() {
    final length = varint();
    if (_pos + length > _end) {
      throw const FormatException('truncated message');
    }
    final reader = _PbfReader(_bytes, _pos, _pos + length);
    _pos += length;
    return reader;
  }

  void skip(int wire) {
    switch (wire) {
      case 0:
        varint();
      case 1:
        _pos += 8;
      case 2:
        // Read first: `_pos += varint()` would add the length to the
        // position from before the length's own bytes.
        final length = varint();
        _pos += length;
      case 5:
        _pos += 4;
      default:
        throw FormatException('unsupported wire type $wire');
    }
    if (_pos > _end) throw const FormatException('truncated field');
  }
}
