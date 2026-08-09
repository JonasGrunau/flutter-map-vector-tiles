@TestOn('browser')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_map_vector_tiles/src/provider/pmtiles/pmtiles_gunzip_web.dart';
import 'package:flutter_test/flutter_test.dart';

/// `gzip.compress(b'pmtiles web gunzip test payload', mtime=0)`.
const _gzipBlob = [
  31, 139, 8, 0, 0, 0, 0, 0, 2, 255, 43, 200, 45, 201, 204, 73, 45, 86, //
  40, 79, 77, 82, 72, 47, 205, 171, 202, 44, 80, 40, 73, 45, 46, 81, 40,
  72, 172, 204, 201, 79, 76, 1, 0, 229, 188, 110, 10, 31, 0, 0, 0,
];

void main() {
  test('DecompressionStream gunzip round-trips a known blob', () async {
    final decoded = await gunzip(Uint8List.fromList(_gzipBlob));
    expect(utf8.decode(decoded), 'pmtiles web gunzip test payload');
  });
}
