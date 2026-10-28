import 'dart:io';
import 'dart:typed_data';

/// [file] from `test/scripts/fonts/`. `flutter test` runs from the
/// package root.
Future<ByteData> fontBytes(String file) async =>
    ByteData.sublistView(await File('test/scripts/fonts/$file').readAsBytes());

/// [file] from `test/scripts/glyphs/`: glyph PBF subsets for the
/// glyph-drawn scripts (see `script_glyphs_test.dart`).
Future<ByteData> glyphBytes(String file) async =>
    ByteData.sublistView(await File('test/scripts/glyphs/$file').readAsBytes());

/// Nothing to do on the VM: `flutter test` uses any font a test loads.
void allowLoadedFonts() {}
