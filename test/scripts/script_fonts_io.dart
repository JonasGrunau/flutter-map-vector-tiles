import 'dart:io';
import 'dart:typed_data';

/// [file] from `test/scripts/fonts/`. `flutter test` runs from the
/// package root.
Future<ByteData> fontBytes(String file) async =>
    ByteData.sublistView(await File('test/scripts/fonts/$file').readAsBytes());

/// Nothing to do on the VM: `flutter test` uses any font a test loads.
void allowLoadedFonts() {}
