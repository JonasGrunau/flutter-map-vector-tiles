import 'dart:typed_data';

import 'mbtiles_metadata.dart';
import 'mbtiles_reader_stub.dart' if (dart.library.io) 'mbtiles_reader_io.dart'
    as impl;

/// An open MBTiles archive, read off the UI isolate.
///
/// The archive is SQLite, and `package:sqlite3` is synchronous — a cold
/// lookup on a large archive costs milliseconds, which on the UI isolate
/// is a dropped frame. Implementations therefore keep the database handle
/// on a worker and answer over a port.
///
/// Web has no implementation: the stub throws [UnsupportedError]. This is
/// what keeps `dart:ffi` out of a web compile, mirroring
/// `cache/cache_resolver.dart`.
abstract class MbTilesReader {
  /// The archive's `metadata` table. Empty when it has none.
  MbTilesMetadata get metadata;

  /// Zoom levels the archive actually serves: from [metadata] when it
  /// declares them, otherwise derived from the tile table at open time.
  int get minZoom;
  int get maxZoom;

  /// Distinguishes this archive from another at the same path — the file
  /// path together with its size and modification time.
  ///
  /// Cache identity depends on it: an archive swapped out for a different
  /// one in place must not inherit the previous one's cached tiles.
  String get identity;

  /// The blob at [z]/[x]/[tmsY], or null when the archive has no such
  /// tile. [tmsY] is a TMS row — the caller flips it.
  ///
  /// Blobs are returned exactly as stored, still gzip-compressed for the
  /// `pbf` archives the spec describes; inflating belongs downstream,
  /// off the UI isolate.
  Future<Uint8List?> tile(int z, int x, int tmsY);

  /// Releases the database handle and stops the worker. Idempotent.
  /// Reads still in flight complete with an error.
  Future<void> close();

  /// Opens the archive at [path].
  ///
  /// Throws [MbTilesException] when the file is missing, is not a SQLite
  /// database, or has no `tiles` table or view.
  static Future<MbTilesReader> open(String path) =>
      impl.openMbTilesReader(path);
}
