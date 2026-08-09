@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_map_vector_tiles/src/core/tile_key.dart';
import 'package:flutter_map_vector_tiles/src/provider/pmtiles/pmtiles_format.dart';
import 'package:flutter_map_vector_tiles/src/provider/pmtiles/pmtiles_vector_tile_provider.dart';
import 'package:flutter_map_vector_tiles/src/provider/vector_tile_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures/pmtiles_builder.dart';

MockClient _rangeServer(List<int> archive) => MockClient((request) async {
      final match =
          RegExp(r'bytes=(\d+)-(\d+)').firstMatch(request.headers['range']!)!;
      final start = int.parse(match.group(1)!);
      final end = int.parse(match.group(2)!) + 1;
      return http.Response.bytes(
          archive.sublist(start, end > archive.length ? archive.length : end),
          206);
    });

void main() {
  test('gzip-compressed directories and tiles are decompressed', () async {
    final tile = utf8.encode('gzipped tile payload');
    final archive = (PmTilesArchiveBuilder()
          ..maxZoom = 1
          ..compress = gzip.encode
          ..addTile(zxyToTileId(0, 0, 0), tile))
        .build();
    expect(PmTilesHeader.parse(archive).internalCompression,
        PmTilesCompression.gzip);

    final provider = await PmTilesVectorTileProvider.open(
      'https://tiles.example.com/planet.pmtiles',
      client: _rangeServer(archive),
    );
    final response = await provider.load(const TileKey(0, 0, 0));
    expect((response as TileResponseData).bytes, tile);
    provider.dispose();
  });

  test('gzip-compressed leaf directories are decompressed', () async {
    final tile = utf8.encode('leafy tile');
    final archive = (PmTilesArchiveBuilder()
          ..maxZoom = 1
          ..compress = gzip.encode
          ..leafSplit = 1
          ..addTile(zxyToTileId(0, 0, 0), tile)
          ..addTile(zxyToTileId(1, 0, 0), utf8.encode('other')))
        .build();

    final provider = await PmTilesVectorTileProvider.open(
      'https://tiles.example.com/planet.pmtiles',
      client: _rangeServer(archive),
    );
    final response = await provider.load(const TileKey(0, 0, 0));
    expect((response as TileResponseData).bytes, tile);
    provider.dispose();
  });

  test('brotli/zstd archives are rejected with a clear error', () async {
    final archive = (PmTilesArchiveBuilder()..addTile(0, [1])).build()
      ..[97] = PmTilesCompression.zstd; // patch internal compression
    await expectLater(
      PmTilesVectorTileProvider.open(
        'https://tiles.example.com/planet.pmtiles',
        client: _rangeServer(archive),
      ),
      throwsA(isA<PmTilesException>()),
    );
  });
}
