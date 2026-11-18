/// [text] in upper case, for `text-transform: uppercase` and the
/// `upcase` expression — except Georgian, which is left as it is.
///
/// Georgian is written in one case, Mkhedruli. Since Unicode 11 its
/// letters have upper-case forms, Mtavruli (U+1C90–U+1CBF), used only
/// for emphasis, and the glyph PBFs styles are served with do not carry
/// them (OpenFreeMap's range 7168–7423 holds the Vedic extensions and
/// nothing else). JavaScript's `toUpperCase`, which `String.toUpperCase`
/// is on the web, maps Mkhedruli to Mtavruli all the same, so there an
/// upper-cased Georgian name left the style's font for the platform's:
/// boxes until Flutter had fetched a fallback font, and a different
/// font from every other label after — while MapLibre GL JS, which
/// skips the glyphs its ranges lack, draws nothing at all. The Dart
/// VM's mapping predates Mtavruli and leaves Georgian alone; this does
/// the same on every platform, so the name is drawn as written, from
/// the style's glyphs.
String upperCaseLabel(String text) {
  var georgian = -1;
  for (var i = 0; i < text.length; i++) {
    if (_isMkhedruli(text.codeUnitAt(i))) {
      georgian = i;
      break;
    }
  }
  if (georgian < 0) return text.toUpperCase();
  final out = StringBuffer(text.substring(0, georgian).toUpperCase());
  var start = georgian;
  var inGeorgian = true;
  for (var i = georgian + 1; i <= text.length; i++) {
    final atEnd = i == text.length;
    if (!atEnd && _isMkhedruli(text.codeUnitAt(i)) == inGeorgian) continue;
    final run = text.substring(start, i);
    out.write(inGeorgian ? run : run.toUpperCase());
    start = i;
    inGeorgian = !inGeorgian;
  }
  return out.toString();
}

/// The Georgian block's Mkhedruli letters, which upper-case to Mtavruli
/// (U+10D0–U+10FF; the two in it that do not are left alone either
/// way). Asomtavruli and Nuskhuri, the ecclesiastical scripts, keep the
/// platform's mapping.
bool _isMkhedruli(int c) => c >= 0x10d0 && c <= 0x10ff;
