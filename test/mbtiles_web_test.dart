@TestOn('browser')
library;

import 'package:flutter_map_vector_tiles/src/provider/mbtiles/mbtiles_vector_tile_provider.dart';
import 'package:flutter_test/flutter_test.dart';

/// The web degradation contract, and the reason it is a test rather than a
/// comment: this file only compiles for the browser if nothing reachable
/// from the provider touches `package:sqlite3` or `dart:ffi`. A conditional
/// import that regressed to the `_io` half would fail to compile here long
/// before it cost the package its web platform tag on pub.dev.
void main() {
  test('opening an archive on web is unsupported, not a crash at import',
      () async {
    await expectLater(
      MbTilesVectorTileProvider.open('/tiles/bavaria.mbtiles'),
      throwsUnsupportedError,
    );
  });
}
