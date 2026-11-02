/// Whether [text] can be drawn from glyph PBFs — one glyph per code
/// point, advanced left to right with no shaping — and still read the
/// way the platform's shaper would draw it.
///
/// That holds for scripts whose letters never change shape or position
/// with their neighbours: Latin (precomposed, as names in map tiles
/// are), Greek, Cyrillic, Armenian, Georgian, digits and the common
/// punctuation and symbols around them. Everything else keeps the
/// platform's `Paragraph` path, which shapes with HarfBuzz and system
/// fonts:
///
/// * right-to-left scripts and bidi controls (Hebrew, Arabic, Syriac,
///   Thaana, N'Ko), whose order and joining a glyph run cannot express;
/// * every script with conjuncts, reordering or stacking (all Indic
///   scripts, Sinhala, Thai, Lao, Tibetan, Myanmar, Khmer, Mongolian);
/// * combining marks, which glyph PBFs carry as standalone glyphs with
///   nothing to attach them to;
/// * CJK, kana and Hangul — as in MapLibre, whose default draws
///   ideographs from a local font rather than fetch ranges of
///   150–190 KB each, several per screen of place names;
/// * emoji, variation selectors, joiners and everything outside the
///   Basic Multilingual Plane, which glyph ranges do not cover.
///
/// Conservative by design: a code point is routed to glyphs only when it
/// is known to be safe, so a script this list has not thought of falls
/// back to the platform rather than drawing wrongly.
bool isGlyphShapeable(String text) {
  for (var i = 0; i < text.length; i++) {
    if (!_simple(text.codeUnitAt(i))) return false;
  }
  return true;
}

bool _simple(int c) {
  if (c < 0x0300) {
    // ASCII, Latin-1, Latin Extended-A/B, IPA, spacing modifiers. Of
    // the controls only the line feed, which breaks a line.
    return c >= 0x20 ? c != 0x7f && (c < 0x80 || c >= 0xa0) : c == 0x0a;
  }
  if (c < 0x0370) return false; // combining diacritical marks
  if (c < 0x0483) return true; // Greek and Coptic, Cyrillic
  if (c < 0x048a) return false; // combining Cyrillic marks
  if (c < 0x0590) return true; // Cyrillic, Cyrillic Supplement, Armenian
  if (c < 0x10a0) return false; // RTL, Indic, Sinhala, Thai, Lao, Tibetan…
  if (c < 0x1100) return true; // Georgian
  if (c >= 0x1c90 && c < 0x1cc0) return true; // Georgian Extended
  if (c < 0x1e00) return false; // Hangul Jamo, Ethiopic, Khmer, Mongolian…
  if (c < 0x2000) return true; // Latin Extended Additional, Greek Extended
  if (c < 0x2070) {
    // General punctuation, without the joiners, directional marks and
    // embeddings, separators and invisible operators.
    return !(c >= 0x200c && c <= 0x200f) &&
        !(c >= 0x2028 && c <= 0x202e) &&
        c < 0x2060;
  }
  if (c < 0x20d0) return true; // super/subscripts, currency
  if (c < 0x2100) return false; // combining marks for symbols
  if (c < 0x2600) {
    // Letterlike symbols, number forms, arrows, maths, technical,
    // enclosed alphanumerics, box drawing, shapes — but not the few
    // whose default presentation is emoji.
    return !(c >= 0x2194 && c <= 0x21aa) &&
        !(c >= 0x231a && c <= 0x23ff) &&
        c != 0x24c2 &&
        !(c >= 0x25aa && c <= 0x25fe);
  }
  if (c < 0x2c60) return false; // symbols and dingbats (emoji), Glagolitic
  if (c < 0x2c80) return true; // Latin Extended-C
  if (c >= 0x2d00 && c < 0x2d30) return true; // Georgian Supplement
  if (c >= 0xa720 && c < 0xa800) return true; // Latin Extended-D
  if (c >= 0xab30 && c < 0xab70) return true; // Latin Extended-E
  if (c >= 0xfb00 && c < 0xfb07) return true; // Latin ligatures
  return false;
}
