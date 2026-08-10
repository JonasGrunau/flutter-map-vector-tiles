import 'dart:io';
import 'dart:typed_data';

/// Native gunzip via `dart:io`'s zlib bindings.
Future<Uint8List> gunzip(Uint8List bytes) async {
  final decoded = gzip.decode(bytes);
  return decoded is Uint8List ? decoded : Uint8List.fromList(decoded);
}

/// On native platforms, tile *blobs* are handed through compressed:
/// [gunzip] here is synchronous CPU work in an async wrapper, and
/// provider loads run on the UI isolate — the consumers inflate instead
/// (the prepare worker for vector tiles, the raster store before image
/// decode). Directories stay inflated at fetch: they are rare and
/// amortized over many tiles.
const bool deferTileGunzipToConsumer = true;
