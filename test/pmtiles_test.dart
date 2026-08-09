import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_map_vector_tiles/src/core/cancellation.dart';
import 'package:flutter_map_vector_tiles/src/core/tile_key.dart';
import 'package:flutter_map_vector_tiles/src/provider/pmtiles/pmtiles_format.dart';
import 'package:flutter_map_vector_tiles/src/provider/pmtiles/pmtiles_vector_tile_provider.dart';
import 'package:flutter_map_vector_tiles/src/provider/vector_tile_provider.dart';
import 'package:flutter_map_vector_tiles/src/style/style_reader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures/pmtiles_builder.dart';

/// Serves [archive] honouring HTTP range requests, like a real blob host.
Future<http.Response> _serveRange(Uint8List archive, http.BaseRequest request,
    {void Function(int start, int end)? onRange}) async {
  final range = request.headers['range'];
  if (range == null) return http.Response.bytes(archive, 200);
  final match = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(range)!;
  final start = int.parse(match.group(1)!);
  var end = int.parse(match.group(2)!); // inclusive
  if (start >= archive.length) return http.Response('', 416);
  if (end >= archive.length) end = archive.length - 1;
  onRange?.call(start, end);
  return http.Response.bytes(archive.sublist(start, end + 1), 206);
}

MockClient _rangeServer(Uint8List archive,
        {void Function(int start, int end)? onRange}) =>
    MockClient((request) => _serveRange(archive, request, onRange: onRange));

void main() {
  group('zxyToTileId', () {
    test('matches the spec anchors', () {
      expect(zxyToTileId(0, 0, 0), 0);
      expect(zxyToTileId(1, 0, 0), 1);
      expect(zxyToTileId(1, 0, 1), 2);
      expect(zxyToTileId(1, 1, 1), 3);
      expect(zxyToTileId(1, 1, 0), 4);
      expect(zxyToTileId(2, 0, 0), 5);
      expect(zxyToTileId(12, 3423, 1763), 19078479);
    });

    test('is a bijection onto the zoom range for z <= 4', () {
      var rangeStart = 0;
      for (var z = 0; z <= 4; z++) {
        final n = 1 << z;
        final seen = <int>{};
        for (var x = 0; x < n; x++) {
          for (var y = 0; y < n; y++) {
            final id = zxyToTileId(z, x, y);
            expect(id, inInclusiveRange(rangeStart, rangeStart + n * n - 1));
            expect(seen.add(id), isTrue, reason: 'duplicate id $id');
          }
        }
        rangeStart += n * n;
      }
    });

    test('stays exact at high zoom (web-safe arithmetic)', () {
      // z22 corner: the largest id of the zoom must be acc(23) - 1.
      var acc = 0;
      for (var z = 0; z <= 22; z++) {
        acc += (1 << z) * (1 << z);
      }
      // This Hilbert orientation ends each zoom at (n-1, 0) — the z1
      // spec table ends at (1, 0).
      expect(zxyToTileId(22, (1 << 22) - 1, 0), acc - 1);
      expect(() => zxyToTileId(27, 0, 0), throwsA(isA<PmTilesException>()));
    });
  });

  group('directory', () {
    test('decodes fixture-encoded entries including contiguous offsets', () {
      final builder = PmTilesArchiveBuilder()
        ..addTile(5, List.filled(42, 1))
        ..addTile(6, List.filled(10, 2))
        ..addTile(100, List.filled(7, 3));
      final archive = builder.build();
      final header = PmTilesHeader.parse(archive);
      final directory = PmTilesDirectory.decode(Uint8List.sublistView(
          archive,
          header.rootDirectoryOffset,
          header.rootDirectoryOffset + header.rootDirectoryLength));

      expect(directory.entries, hasLength(3));
      expect(directory.entries[0].tileId, 5);
      expect(directory.entries[0].offset, 0);
      expect(directory.entries[0].length, 42);
      expect(directory.entries[1].offset, 42); // contiguous, encoded as 0
      expect(directory.entries[2].tileId, 100);
      expect(directory.entries[2].offset, 52);
    });

    test('find honours exact hits, run-length windows and leaves', () {
      const directory = PmTilesDirectory([
        PmTilesEntry(tileId: 5, offset: 0, length: 10, runLength: 3),
        PmTilesEntry(tileId: 20, offset: 10, length: 10, runLength: 1),
        PmTilesEntry(tileId: 30, offset: 20, length: 10, runLength: 0),
      ]);
      expect(directory.find(5)!.offset, 0);
      expect(directory.find(7)!.offset, 0); // inside the run of 3
      expect(directory.find(8), isNull); // past the run
      expect(directory.find(20)!.offset, 10);
      expect(directory.find(21), isNull);
      expect(directory.find(4), isNull); // before the first entry
      expect(directory.find(35)!.isLeaf, isTrue); // leaf covers onwards
    });
  });

  test('header round-trips through the fixture builder', () {
    final archive = (PmTilesArchiveBuilder()
          ..minZoom = 2
          ..maxZoom = 9
          ..addTile(0, [1, 2, 3]))
        .build();
    final header = PmTilesHeader.parse(archive);
    expect(header.minZoom, 2);
    expect(header.maxZoom, 9);
    expect(header.internalCompression, PmTilesCompression.none);
    expect(header.tileCompression, PmTilesCompression.none);
    expect(header.tileType, 1);
    expect(header.clustered, isTrue);
    expect(header.rootDirectoryOffset, 127);
  });

  group('provider', () {
    final z1Tile = utf8.encode('tile z1 0/0');
    final z0Tile = utf8.encode('tile z0');

    Uint8List archive({int leafSplit = 0}) => (PmTilesArchiveBuilder()
          ..maxZoom = 1
          ..leafSplit = leafSplit
          ..addTile(zxyToTileId(0, 0, 0), z0Tile)
          ..addTile(zxyToTileId(1, 0, 0), z1Tile))
        .build();

    Future<PmTilesVectorTileProvider> open(Uint8List bytes,
            {void Function(int, int)? onRange}) =>
        PmTilesVectorTileProvider.open(
          'https://tiles.example.com/planet.pmtiles',
          client: _rangeServer(bytes, onRange: onRange),
        );

    test('loads tiles from an uncompressed archive', () async {
      final provider = await open(archive());
      expect(provider.minimumZoom, 0);
      expect(provider.maximumZoom, 1);

      final z0 = await provider.load(const TileKey(0, 0, 0));
      expect((z0 as TileResponseData).bytes, z0Tile);
      final z1 = await provider.load(const TileKey(1, 0, 0));
      expect((z1 as TileResponseData).bytes, z1Tile);
      provider.dispose();
    });

    test('absent tiles and out-of-range zooms are NotFound', () async {
      final provider = await open(archive());
      expect(await provider.load(const TileKey(1, 1, 1)),
          isA<TileResponseNotFound>());
      expect(await provider.load(const TileKey(2, 0, 0)),
          isA<TileResponseNotFound>());
      provider.dispose();
    });

    test('tiles inside leaf directories load and the leaf is cached', () async {
      final requests = <(int, int)>[];
      final provider = await open(archive(leafSplit: 1),
          onRange: (s, e) => requests.add((s, e)));
      requests.clear(); // drop the open() prefix fetch

      final z0 = await provider.load(const TileKey(0, 0, 0));
      expect((z0 as TileResponseData).bytes, z0Tile);
      expect(requests, hasLength(2)); // leaf directory + tile blob

      requests.clear();
      final z1 = await provider.load(const TileKey(1, 0, 0));
      expect((z1 as TileResponseData).bytes, z1Tile);
      // Different leaf (split size 1): again two requests, but the
      // z0 leaf stayed cached — no third fetch for it.
      expect(requests, hasLength(2));
      provider.dispose();
    });

    test('concurrent requests for the same tile are coalesced', () async {
      final requests = <(int, int)>[];
      final provider =
          await open(archive(), onRange: (s, e) => requests.add((s, e)));
      requests.clear();

      final results = await Future.wait([
        provider.load(const TileKey(0, 0, 0)),
        provider.load(const TileKey(0, 0, 0)),
      ]);
      expect(results.whereType<TileResponseData>(), hasLength(2));
      expect(requests, hasLength(1));
      provider.dispose();
    });

    test('cancellation is a state, not an exception', () async {
      final provider = await open(archive());
      final token = CancellationToken()..cancel();
      expect(await provider.load(const TileKey(0, 0, 0), cancellation: token),
          isA<TileResponseCancelled>());

      provider.dispose();
      expect(await provider.load(const TileKey(0, 0, 0)),
          isA<TileResponseCancelled>());
    });

    test('open rejects non-PMTiles data', () async {
      final bogus = Uint8List.fromList(utf8.encode('<html>not tiles</html>'));
      await expectLater(
        PmTilesVectorTileProvider.open('https://x.example.com/a.pmtiles',
            client: _rangeServer(bogus)),
        throwsA(isA<PmTilesException>()),
      );
    });
  });

  group('style reader', () {
    test('pmtiles:// sources produce a PmTilesVectorTileProvider', () async {
      final archive = (PmTilesArchiveBuilder()
            ..maxZoom = 5
            ..addTile(0, [1]))
          .build();
      const styleUrl = 'https://maps.example.com/style.json';
      final client = MockClient((request) async {
        if (request.url.path.endsWith('style.json')) {
          return http.Response(
              jsonEncode({
                'version': 8,
                'sources': {
                  'protomaps': {
                    'type': 'vector',
                    'url': 'pmtiles://https://tiles.example.com/planet.pmtiles',
                  },
                },
                'layers': [
                  {
                    'id': 'bg',
                    'type': 'background',
                    'paint': {'background-color': '#fff'},
                  },
                ],
              }),
              200);
        }
        return _serveRange(archive, request);
      });

      final style =
          await StyleReader(uri: styleUrl, httpClient: client, cache: false)
              .read();
      final provider = style.providers.providers['protomaps'];
      expect(provider, isA<PmTilesVectorTileProvider>());
      expect((provider as PmTilesVectorTileProvider).maximumZoom, 5);
      style.dispose();
    });

    test('source minzoom/maxzoom override the archive header', () async {
      final archive = (PmTilesArchiveBuilder()
            ..maxZoom = 14
            ..addTile(0, [1]))
          .build();
      final client = MockClient((request) async {
        if (request.url.path.endsWith('style.json')) {
          return http.Response(
              jsonEncode({
                'version': 8,
                'sources': {
                  'protomaps': {
                    'type': 'vector',
                    'url': 'pmtiles://https://tiles.example.com/planet.pmtiles',
                    'minzoom': 2,
                    'maxzoom': 7,
                  },
                },
                'layers': [
                  {
                    'id': 'bg',
                    'type': 'background',
                    'paint': {'background-color': '#fff'},
                  },
                ],
              }),
              200);
        }
        return _serveRange(archive, request);
      });

      final style = await StyleReader(
              uri: 'https://maps.example.com/style.json',
              httpClient: client,
              cache: false)
          .read();
      final provider =
          style.providers.providers['protomaps']! as PmTilesVectorTileProvider;
      expect(provider.minimumZoom, 2);
      expect(provider.maximumZoom, 7);
      style.dispose();
    });
  });
}
