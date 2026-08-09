@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_map_vector_tiles/src/style/style_reader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, Object?> _styleJson(String name) => {
      'version': 8,
      'name': name,
      'sources': {
        'openmaptiles': {
          'type': 'vector',
          'tiles': ['https://tiles.example.com/{z}/{x}/{y}.pbf'],
          'maxzoom': 14,
        },
      },
      'layers': [
        {
          'id': 'bg',
          'type': 'background',
          'paint': {'background-color': '#ffffff'},
        },
      ],
    };

MockClient _serving(String name, {void Function()? onRequest}) =>
    MockClient((request) async {
      onRequest?.call();
      return http.Response(jsonEncode(_styleJson(name)), 200,
          headers: {'content-type': 'application/json'});
    });

MockClient get _offline =>
    MockClient((request) async => http.Response('unavailable', 503));

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('fmvt_style');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  StyleReader reader(
    http.Client client, {
    bool cache = true,
    Duration refreshAfter = const Duration(hours: 12),
  }) =>
      StyleReader(
        uri: 'https://styles.example.com/streets/style.json?key={key}',
        apiKey: 'test-key',
        httpClient: client,
        cache: cache,
        refreshAfter: refreshAfter,
        cachePath: () async => dir.path,
      );

  test('fresh cache serves the style with no network at all', () async {
    final first = await reader(_serving('v1')).read();
    expect(first.name, 'v1');
    first.dispose();

    var requests = 0;
    final second =
        await reader(_serving('v2', onRequest: () => requests++)).read();
    expect(second.name, 'v1'); // served from disk, not refetched
    expect(requests, 0);
    second.dispose();
  });

  test('cached style keeps working when the network is down', () async {
    final first = await reader(_serving('v1')).read();
    first.dispose();

    final offline = await reader(_offline).read();
    expect(offline.name, 'v1');
    expect(offline.providers.providers, contains('openmaptiles'));
    offline.dispose();
  });

  test('without cache an offline start fails', () async {
    await expectLater(
      reader(_offline, cache: false).read(),
      throwsA(isA<StyleReaderException>()),
    );
  });

  test('offline start with an empty cache fails', () async {
    await expectLater(
      reader(_offline).read(),
      throwsA(isA<StyleReaderException>()),
    );
  });

  test('stale cache is served instantly and revalidated in background',
      () async {
    const stale = Duration(milliseconds: 1);
    final first = await reader(_serving('v1'), refreshAfter: stale).read();
    expect(first.name, 'v1');
    first.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    // Stale hit: v1 comes back immediately while v2 is fetched behind it.
    final second = await reader(_serving('v2'), refreshAfter: stale).read();
    expect(second.name, 'v1');
    second.dispose();

    // The background revalidation lands on disk shortly after.
    for (var attempt = 0;; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final next = await reader(_offline, refreshAfter: stale).read();
      final name = next.name;
      next.dispose();
      if (name == 'v2') break;
      if (attempt > 40) fail('background revalidation never landed');
    }
  });
}
