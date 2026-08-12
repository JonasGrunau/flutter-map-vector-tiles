import 'mbtiles_builder.dart';

const _reason = 'MBTiles fixtures need dart:io and package:sqlite3; the '
    'tests that use them are @TestOn("vm").';

Never writeArchive({
  required String path,
  required Map<String, String> metadata,
  required List<MbTilesFixtureTile> tiles,
  required bool viewSchema,
}) =>
    throw UnsupportedError(_reason);

Never dropTilesTable(String path) => throw UnsupportedError(_reason);
