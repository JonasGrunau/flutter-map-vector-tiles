import 'package:flutter_map_vector_tiles/src/core/redact.dart';
import 'package:flutter_map_vector_tiles/src/core/tile_key.dart';
import 'package:flutter_map_vector_tiles/src/logger.dart';
import 'package:flutter_map_vector_tiles/src/provider/network_vector_tile_provider.dart';
import 'package:flutter_map_vector_tiles/src/provider/pmtiles/pmtiles_format.dart';
import 'package:flutter_map_vector_tiles/src/provider/pmtiles/pmtiles_vector_tile_provider.dart';
import 'package:flutter_map_vector_tiles/src/provider/vector_tile_provider.dart';
import 'package:flutter_map_vector_tiles/src/style/style_reader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures/pmtiles_builder.dart';

void main() {
  group('redactKeys', () {
    test('replaces the value and keeps the parameter name', () {
      expect(redactKeys('https://a/x?key=abc&z=1'), 'https://a/x?key=***&z=1');
      expect(redactKeys('https://a/x?z=1&key=abc'), 'https://a/x?z=1&key=***');
    });

    test('covers every credential parameter', () {
      for (final name in [
        'key',
        'apikey',
        'api_key',
        'access_token',
        'token'
      ]) {
        expect(redactKeys('https://a/x?$name=s3cret#frag'),
            'https://a/x?$name=***#frag');
      }
      expect(redactKeys('https://a/x?Key=s3cret'), 'https://a/x?Key=***');
    });

    test('leaves parameters that merely end in a credential name', () {
      const url = 'https://a/x?monkey=1&mykey=2&tokens=3';
      expect(redactKeys(url), url);
    });

    test('keeps the text after a URL inside a message', () {
      expect(redactKeys('failed: https://a/x?key=abc (boom)'),
          'failed: https://a/x?key=*** (boom)');
      expect(
          redactKeys('failed: https://a/x?key=abc (ClientException: HTTP 500, '
              'uri=https://a/x?key=abc)'),
          'failed: https://a/x?key=*** (ClientException: HTTP 500, '
          'uri=https://a/x?key=***)');
    });

    test('redacts every URL in a message', () {
      expect(redactKeys('a?key=1 b?access_token=2'),
          'a?key=*** b?access_token=***');
    });
  });

  group('Logger', () {
    test('custom callbacks receive redacted messages', () {
      final logs = <String>[];
      final warnings = <String>[];
      Logger.custom(onLog: logs.add, onWarn: warnings.add)
        ..log('fetched https://a/s.json?key=abc')
        ..warn('failed https://a/s.json?key=abc');
      expect(logs, ['fetched https://a/s.json?key=***']);
      expect(warnings, ['failed https://a/s.json?key=***']);
    });

    test('a warning without onWarn falls back to onLog, redacted', () {
      final logs = <String>[];
      Logger.custom(onLog: logs.add).warn('x?api_key=abc');
      expect(logs, ['x?api_key=***']);
    });
  });

  group('provider warnings carry no key', () {
    const template = 'https://tiles.example.com/{z}/{x}/{y}.pbf?key=s3cret';

    Future<List<String>> warningsFor(http.Client client) async {
      final warnings = <String>[];
      final provider = NetworkVectorTileProvider(
        urlTemplate: template,
        maxRetries: 0,
        client: client,
        logger: Logger.custom(onWarn: warnings.add),
      );
      addTearDown(provider.dispose);
      final response = await provider.load(const TileKey(1, 0, 0));
      expect(response, isA<TileResponseError>());
      return warnings;
    }

    test('HTTP 403', () async {
      final warnings = await warningsFor(
          MockClient((_) async => http.Response('forbidden', 403)));
      expect(warnings, hasLength(1));
      expect(warnings.single, isNot(contains('s3cret')));
      expect(warnings.single, contains('/1/0/0.pbf?key=***'));
    });

    test('HTTP 500', () async {
      final warnings =
          await warningsFor(MockClient((_) async => http.Response('', 500)));
      expect(warnings.single, isNot(contains('s3cret')));
      expect(warnings.single, contains('?key=***'));
    });

    test('a ClientException repeating the URL', () async {
      final warnings = await warningsFor(MockClient((request) async =>
          throw http.ClientException('connection reset', request.url)));
      expect(warnings.single, isNot(contains('s3cret')));
      expect(warnings.single, contains('uri=https://tiles.example.com'));
    });

    test('PMTiles range request failure', () async {
      const url = 'https://tiles.example.com/planet.pmtiles?key=s3cret';
      final archive = (PmTilesArchiveBuilder()
            ..addTile(zxyToTileId(0, 0, 0), [1, 2, 3, 4]))
          .build();
      var archiveServed = false;
      final warnings = <String>[];
      final provider = await PmTilesVectorTileProvider.open(
        url,
        maxRetries: 0,
        logger: Logger.custom(onWarn: warnings.add),
        client: MockClient((request) async {
          if (archiveServed) return http.Response('', 500);
          archiveServed = true;
          return http.Response.bytes(archive, 200);
        }),
      );
      addTearDown(provider.dispose);
      await provider.load(const TileKey(0, 0, 0));
      expect(warnings, isNotEmpty);
      for (final warning in warnings) {
        expect(warning, isNot(contains('s3cret')));
      }
    });
  });

  test('StyleReaderException names the URL with its key redacted', () async {
    await expectLater(
      StyleReader(
        uri: 'https://api.example.com/style.json?key=s3cret',
        httpClient: MockClient((_) async => http.Response('', 403)),
        cache: false,
      ).read(),
      throwsA(isA<StyleReaderException>().having((e) => e.message, 'message',
          'HTTP 403 for https://api.example.com/style.json?key=***')),
    );
  });
}
