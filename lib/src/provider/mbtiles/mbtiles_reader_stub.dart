import 'mbtiles_reader.dart';

/// Web has no filesystem and no `dart:ffi`, so there is nothing to open.
///
/// This half of the conditional import exists to keep the package's web
/// platform support: nothing reachable from a browser compile may touch
/// `package:sqlite3`. Callers on web should use `PmTilesVectorTileProvider`
/// (HTTP range requests) or `MemoryVectorTileProvider` instead.
Future<MbTilesReader> openMbTilesReader(String path) => throw UnsupportedError(
      'MBTiles archives are not supported on web: they are SQLite files read '
      'through dart:ffi. Use PMTiles over HTTP range requests instead.',
    );
