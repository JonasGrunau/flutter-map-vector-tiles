import 'package:sqlite3/sqlite3.dart';

import 'mbtiles_builder.dart';

/// Writes the archive with plain DDL against the MBTiles schema — never
/// by calling into `lib/src/provider/mbtiles/`.
void writeArchive({
  required String path,
  required Map<String, String> metadata,
  required List<MbTilesFixtureTile> tiles,
  required bool viewSchema,
}) {
  final database = sqlite3.open(path);
  try {
    database.execute('CREATE TABLE metadata (name text, value text);');
    for (final entry in metadata.entries) {
      database.execute('INSERT INTO metadata (name, value) VALUES (?, ?);',
          [entry.key, entry.value]);
    }
    if (viewSchema) {
      _writeViewSchema(database, tiles);
    } else {
      _writeFlatSchema(database, tiles);
    }
  } finally {
    database.dispose();
  }
}

void dropTilesTable(String path) {
  final database = sqlite3.open(path);
  try {
    database.execute('DROP TABLE tiles;');
  } finally {
    database.dispose();
  }
}

void _writeFlatSchema(Database database, List<MbTilesFixtureTile> tiles) {
  database.execute('CREATE TABLE tiles ('
      'zoom_level integer, tile_column integer, '
      'tile_row integer, tile_data blob);');
  database.execute('CREATE UNIQUE INDEX tile_index ON tiles '
      '(zoom_level, tile_column, tile_row);');
  for (final tile in tiles) {
    database.execute(
      'INSERT INTO tiles (zoom_level, tile_column, tile_row, tile_data) '
      'VALUES (?, ?, ?, ?);',
      [tile.z, tile.column, tile.tmsRow, tile.bytes],
    );
  }
}

void _writeViewSchema(Database database, List<MbTilesFixtureTile> tiles) {
  database.execute('CREATE TABLE map ('
      'zoom_level integer, tile_column integer, '
      'tile_row integer, tile_id text);');
  database.execute('CREATE TABLE images (tile_data blob, tile_id text);');
  database.execute('CREATE VIEW tiles AS SELECT '
      'map.zoom_level AS zoom_level, map.tile_column AS tile_column, '
      'map.tile_row AS tile_row, images.tile_data AS tile_data '
      'FROM map JOIN images ON images.tile_id = map.tile_id;');
  for (var i = 0; i < tiles.length; i++) {
    final tile = tiles[i];
    final id = 'tile$i';
    database.execute('INSERT INTO images (tile_id, tile_data) VALUES (?, ?);',
        [id, tile.bytes]);
    database.execute(
      'INSERT INTO map (zoom_level, tile_column, tile_row, tile_id) '
      'VALUES (?, ?, ?, ?);',
      [tile.z, tile.column, tile.tmsRow, id],
    );
  }
}
