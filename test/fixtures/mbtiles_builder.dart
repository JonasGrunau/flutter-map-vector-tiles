import 'dart:typed_data';

import 'mbtiles_builder_stub.dart'
    if (dart.library.io) 'mbtiles_builder_io.dart' as impl;

/// Writes minimal MBTiles archives for tests.
///
/// Unlike `pmtiles_builder.dart` this cannot be an independent
/// implementation of the container — SQLite is the container, and only
/// SQLite writes it. The independence that matters is kept a level up:
/// fixtures are laid out with plain `CREATE TABLE` / `INSERT` against the
/// spec's schema, so the table shape and the TMS row convention under
/// test are written separately from the provider's read query.
///
/// The write itself sits behind a conditional import for the same reason
/// the provider's reader does. `@TestOn('vm')` gates when a test *runs*,
/// not whether it compiles: `dart:io` compiles for web (it exists in the
/// web SDK and merely throws), but `package:sqlite3` reaches `dart:ffi`,
/// which does not exist there. A direct import here would break
/// `flutter test --platform chrome` for the whole suite.
class MbTilesArchiveBuilder {
  /// Rows of the `metadata` table. Clear it to write an archive that has
  /// none.
  final Map<String, String> metadata = {
    'name': 'test',
    'format': 'pbf',
    'minzoom': '0',
    'maxzoom': '2',
  };

  /// When true the archive stores tiles the deduplicating way — a `map`
  /// table of coordinates plus an `images` table of blobs, with `tiles`
  /// as a view over the join. Plenty of real archives are built this way,
  /// and a reader that queries the underlying tables instead of `tiles`
  /// breaks on them.
  bool viewSchema = false;

  final _tiles = <MbTilesFixtureTile>[];

  /// Adds the blob at [z]/[column]/[tmsRow]. [tmsRow] is a **TMS** row,
  /// counted from the bottom — that is how MBTiles stores tiles, and the
  /// flip is the provider's job.
  void addTile(int z, int column, int tmsRow, List<int> bytes) => _tiles
      .add(MbTilesFixtureTile(z, column, tmsRow, Uint8List.fromList(bytes)));

  void build(String path) => impl.writeArchive(
        path: path,
        metadata: metadata,
        tiles: _tiles,
        viewSchema: viewSchema,
      );
}

/// One row destined for the archive.
class MbTilesFixtureTile {
  final int z;
  final int column;
  final int tmsRow;
  final Uint8List bytes;
  const MbTilesFixtureTile(this.z, this.column, this.tmsRow, this.bytes);
}

/// Removes the `tiles` relation from an existing archive, leaving a valid
/// SQLite database the provider must still reject.
void dropTilesTable(String path) => impl.dropTilesTable(path);
