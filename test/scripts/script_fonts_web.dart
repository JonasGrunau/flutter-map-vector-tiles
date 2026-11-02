import 'dart:typed_data';
import 'dart:ui_web' as ui_web;

import 'package:http/http.dart' as http;

/// [file] from `test/scripts/fonts/`, which `flutter test --platform
/// chrome` serves at the root of its server along with the rest of
/// `test/`.
Future<ByteData> fontBytes(String file) async {
  final url = Uri.base.resolve('/scripts/fonts/$file');
  final response = await http.get(url);
  if (response.statusCode != 200) {
    throw StateError('$url: HTTP ${response.statusCode}');
  }
  return ByteData.sublistView(response.bodyBytes);
}

/// The browser test environment draws every family in the box-glyph
/// test font, whatever a test loads. This keeps the rest of that
/// environment — font fallback included, which would fetch fonts from
/// the network — and lets the loaded fonts draw.
void allowLoadedFonts() {
  ui_web.TestEnvironment.setUp(const ui_web.TestEnvironment(
    ignorePlatformMessages: true,
    disableFontFallbacks: true,
    keepSemanticsDisabledOnUpdate: true,
    defaultToTestUrlStrategy: true,
  ));
}
