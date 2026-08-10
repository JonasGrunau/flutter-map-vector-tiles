@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_map_vector_tiles/src/core/tile_key.dart';
import 'package:flutter_map_vector_tiles/src/pipeline/tile_processor.dart';
import 'package:flutter_map_vector_tiles/src/provider/pmtiles/pmtiles_format.dart';
import 'package:flutter_map_vector_tiles/src/provider/pmtiles/pmtiles_vector_tile_provider.dart';
import 'package:flutter_map_vector_tiles/src/provider/vector_tile_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures/mvt_builder.dart';
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
  test(
      'gzip directories are decompressed; tile blobs pass through '
      'compressed for the worker to inflate (native)', () async {
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
    final bytes = (response as TileResponseData).bytes;
    // Still compressed: inflating on the UI isolate would block a frame.
    expect(bytes.take(2), [0x1f, 0x8b]);
    expect(gzip.decode(bytes), tile);
    provider.dispose();
  });

  test('gzip-compressed leaf directories are decompressed at fetch', () async {
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
    // Resolving through the leaf directory works; the blob itself stays
    // compressed as above.
    final response = await provider.load(const TileKey(0, 0, 0));
    expect(gzip.decode((response as TileResponseData).bytes), tile);
    provider.dispose();
  });

  test('prepareTileSync inflates gzip-compressed MVT bytes', () {
    final mvt = MvtTileBuilder()
        .layer('water')
        .feature(type: 1, geometry: [cmd(1, 1), zig(5), zig(5)])
        .done()
        .build();
    final prepared = prepareTileSync(PrepareInput(
      z: 0,
      x: 0,
      y: 0,
      bytes: Uint8List.fromList(gzip.encode(mvt)),
      layerProperties: const {'water': null},
    ));
    expect(prepared.layers['water']!.features, hasLength(1));
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
