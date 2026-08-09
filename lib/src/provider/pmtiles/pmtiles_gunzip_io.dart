import 'dart:io';
import 'dart:typed_data';

/// Native gunzip via `dart:io`'s zlib bindings.
Future<Uint8List> gunzip(Uint8List bytes) async {
  final decoded = gzip.decode(bytes);
  return decoded is Uint8List ? decoded : Uint8List.fromList(decoded);
}
