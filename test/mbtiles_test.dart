@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_map_vector_tiles/src/core/cancellation.dart';
import 'package:flutter_map_vector_tiles/src/core/tile_key.dart';
import 'package:flutter_map_vector_tiles/src/pipeline/tile_processor.dart';
import 'package:flutter_map_vector_tiles/src/provider/mbtiles/mbtiles_metadata.dart';
import 'package:flutter_map_vector_tiles/src/provider/mbtiles/mbtiles_vector_tile_provider.dart';
import 'package:flutter_map_vector_tiles/src/provider/vector_tile_provider.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/mbtiles_builder.dart';
import 'fixtures/mvt_builder.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('fmvt_mbtiles'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  String write(MbTilesArchiveBuilder builder, {String name = 'a.mbtiles'}) {
    final path = '${dir.path}/$name';
    builder.build(path);
    return path;
  }

  /// An archive with one tile at each of z0 and z1. The z1 tile sits at
  /// TMS row 1, which is XYZ y=0.
  String standardArchive({bool viewSchema = false}) => write(
        MbTilesArchiveBuilder()
          ..viewSchema = viewSchema
          ..addTile(0, 0, 0, [0xa])
          ..addTile(1, 0, 1, [0xb]),
      );

  group('tile lookup', () {
    test('flips TMS rows to slippy-map y', () async {
      final provider = await MbTilesVectorTileProvider.open(standardArchive());
      addTearDown(provider.dispose);

      // Stored at z1 TMS row 1 → served as XYZ y=0, since
      // (1 << 1) - 1 - 0 == 1.
      final hit = await provider.load(const TileKey(1, 0, 0));
      expect((hit as TileResponseData).bytes, [0xb]);

      // …and emphatically not at the unflipped coordinate.
      expect(await provider.load(const TileKey(1, 0, 1)),
          isA<TileResponseNotFound>());
    });

    test('reads the deduplicating map/images view schema identically',
        () async {
      final provider = await MbTilesVectorTileProvider.open(
          standardArchive(viewSchema: true));
      addTearDown(provider.dispose);

      final hit = await provider.load(const TileKey(1, 0, 0));
      expect((hit as TileResponseData).bytes, [0xb]);
      expect(await provider.load(const TileKey(1, 1, 0)),
          isA<TileResponseNotFound>());
    });

    test('an absent tile is not found, not an error', () async {
      final provider = await MbTilesVectorTileProvider.open(standardArchive());
      addTearDown(provider.dispose);

      expect(await provider.load(const TileKey(1, 1, 1)),
          isA<TileResponseNotFound>());
    });

    test('zooms outside the range are not found without a query', () async {
      final provider = await MbTilesVectorTileProvider.open(
        standardArchive(),
        minimumZoom: 1,
        maximumZoom: 1,
      );
      addTearDown(provider.dispose);

      expect(await provider.load(const TileKey(0, 0, 0)),
          isA<TileResponseNotFound>());
      expect(await provider.load(const TileKey(2, 0, 0)),
          isA<TileResponseNotFound>());
      // The archive itself still has the z0 tile — only the override hid it.
      expect(provider.minimumZoom, 1);
    });

    test('an empty blob counts as absence, never as empty data', () async {
      final path = write(MbTilesArchiveBuilder()..addTile(0, 0, 0, []));
      final provider = await MbTilesVectorTileProvider.open(path);
      addTearDown(provider.dispose);

      expect(await provider.load(const TileKey(0, 0, 0)),
          isA<TileResponseNotFound>());
    });

    test('concurrent loads of one tile coalesce', () async {
      final provider = await MbTilesVectorTileProvider.open(standardArchive());
      addTearDown(provider.dispose);

      final first = provider.load(const TileKey(0, 0, 0));
      final second = provider.load(const TileKey(0, 0, 0));
      expect(identical(first, second), isTrue);
      expect(((await first) as TileResponseData).bytes, [0xa]);
    });
  });

  group('zoom range', () {
    test('comes from the metadata table', () async {
      final builder = MbTilesArchiveBuilder()..addTile(0, 0, 0, [1]);
      builder.metadata['minzoom'] = '3';
      builder.metadata['maxzoom'] = '11';
      final provider = await MbTilesVectorTileProvider.open(write(builder));
      addTearDown(provider.dispose);

      expect(provider.minimumZoom, 3);
      expect(provider.maximumZoom, 11);
    });

    test('is derived from the tiles when the metadata omits it', () async {
      final builder = MbTilesArchiveBuilder()
        ..addTile(4, 0, 0, [1])
        ..addTile(7, 0, 0, [1]);
      builder.metadata.remove('minzoom');
      builder.metadata.remove('maxzoom');
      final provider = await MbTilesVectorTileProvider.open(write(builder));
      addTearDown(provider.dispose);

      expect(provider.minimumZoom, 4);
      expect(provider.maximumZoom, 7);
    });

    test('constructor arguments win over both', () async {
      final provider = await MbTilesVectorTileProvider.open(
        standardArchive(),
        minimumZoom: 5,
        maximumZoom: 9,
      );
      addTearDown(provider.dispose);

      expect(provider.minimumZoom, 5);
      expect(provider.maximumZoom, 9);
    });

    test('an archive with no metadata table still opens', () async {
      final builder = MbTilesArchiveBuilder()..addTile(2, 1, 1, [7]);
      builder.metadata.clear();
      final provider = await MbTilesVectorTileProvider.open(write(builder));
      addTearDown(provider.dispose);

      expect(provider.minimumZoom, 2);
      expect(provider.maximumZoom, 2);
      expect(provider.metadata.values, isEmpty);
      final hit = await provider.load(const TileKey(2, 1, 2));
      expect((hit as TileResponseData).bytes, [7]);
    });
  });

  group('compression', () {
    test('gzipped blobs stay compressed for the worker to inflate', () async {
      final mvt = MvtTileBuilder()
          .layer('water')
          .feature(type: 1, geometry: [cmd(1, 1), zig(5), zig(5)])
          .done()
          .build();
      final path =
          write(MbTilesArchiveBuilder()..addTile(0, 0, 0, gzip.encode(mvt)));
      final provider = await MbTilesVectorTileProvider.open(path);
      addTearDown(provider.dispose);

      final response = await provider.load(const TileKey(0, 0, 0));
      final bytes = (response as TileResponseData).bytes;
      expect(bytes.take(2), [0x1f, 0x8b],
          reason: 'the provider must not spend UI-isolate time inflating');

      // …and the pipeline stage that does inflate it decodes the tile.
      final prepared = prepareTileSync(PrepareInput(
        z: 0,
        x: 0,
        y: 0,
        bytes: Uint8List.fromList(bytes),
        layerProperties: const {'water': null},
      ));
      expect(prepared.layers['water']!.features, hasLength(1));
    });
  });

  group('cache identity', () {
    test('changes when the archive at a path is replaced', () async {
      final path = standardArchive();
      final first = await MbTilesVectorTileProvider.open(path);
      final firstKey = first.cacheKey;
      first.dispose();

      File(path).deleteSync();
      (MbTilesArchiveBuilder()
            ..addTile(0, 0, 0, [9, 9, 9, 9, 9, 9, 9, 9])
            ..addTile(1, 1, 1, [8]))
          .build(path);

      final second = await MbTilesVectorTileProvider.open(path);
      addTearDown(second.dispose);
      expect(second.cacheKey, isNot(firstKey));
      expect(second.cacheKey, startsWith('mbtiles:'));
    });

    test('an explicit key is used verbatim', () async {
      final provider = await MbTilesVectorTileProvider.open(standardArchive(),
          cacheKey: 'bundled-region');
      addTearDown(provider.dispose);

      expect(provider.cacheKey, 'bundled-region');
    });
  });

  group('lifecycle', () {
    test('a cancelled token resolves to cancelled, never an exception',
        () async {
      final provider = await MbTilesVectorTileProvider.open(standardArchive());
      addTearDown(provider.dispose);

      final token = CancellationToken()..cancel();
      expect(await provider.load(const TileKey(0, 0, 0), cancellation: token),
          isA<TileResponseCancelled>());
    });

    test('loads after dispose resolve to cancelled', () async {
      final provider = await MbTilesVectorTileProvider.open(standardArchive());
      provider.dispose();

      expect(await provider.load(const TileKey(0, 0, 0)),
          isA<TileResponseCancelled>());
    });

    test('dispose is idempotent', () async {
      final provider = await MbTilesVectorTileProvider.open(standardArchive());
      provider.dispose();
      expect(provider.dispose, returnsNormally);
    });

    test('opts out of the disk cache', () async {
      final provider = await MbTilesVectorTileProvider.open(standardArchive());
      addTearDown(provider.dispose);

      expect(provider.cacheBytesToDisk, isFalse);
    });
  });

  group('open failures', () {
    test('a missing file throws', () async {
      await expectLater(
        MbTilesVectorTileProvider.open('${dir.path}/absent.mbtiles'),
        throwsA(isA<MbTilesException>()),
      );
    });

    test('a file that is not a database throws', () async {
      final path = '${dir.path}/junk.mbtiles';
      File(path).writeAsBytesSync(List.filled(64, 0x42));

      await expectLater(
        MbTilesVectorTileProvider.open(path),
        throwsA(isA<MbTilesException>()),
      );
    });

    test('a database without a tiles table throws', () async {
      final path = '${dir.path}/empty.mbtiles';
      final builder = MbTilesArchiveBuilder();
      builder.build(path);
      // Drop the table the reader depends on, keeping the metadata.
      final stripped = '${dir.path}/stripped.mbtiles';
      File(path).copySync(stripped);
      dropTilesTable(stripped);

      await expectLater(
        MbTilesVectorTileProvider.open(stripped),
        throwsA(isA<MbTilesException>()),
      );
    });
  });

  group('metadata', () {
    test('is exposed for attribution and camera hints', () async {
      final builder = MbTilesArchiveBuilder()..addTile(0, 0, 0, [1]);
      builder.metadata['attribution'] = '© OpenStreetMap';
      builder.metadata['bounds'] = '-1,-2,3,4';
      final provider = await MbTilesVectorTileProvider.open(write(builder));
      addTearDown(provider.dispose);

      expect(provider.metadata.attribution, '© OpenStreetMap');
      expect(provider.metadata.isVector, isTrue);
      expect(provider.metadata.bounds!.north, closeTo(4, 1e-9));
    });
  });
}
