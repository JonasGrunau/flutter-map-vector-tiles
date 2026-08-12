import 'package:flutter_map_vector_tiles/src/provider/mbtiles/mbtiles_metadata.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MbTilesMetadata', () {
    test('reads the entries the spec gives meaning to', () {
      final metadata = MbTilesMetadata.parse(const {
        'name': 'Bavaria',
        'format': 'pbf',
        'compression': 'gzip',
        'attribution': '<a href="https://osm.org">OpenStreetMap</a>',
        'description': 'Extract',
        'minzoom': '4',
        'maxzoom': '14',
        'bounds': '8.9,47.2,13.9,50.6',
        'center': '11.5,48.1,10',
      });

      expect(metadata.name, 'Bavaria');
      expect(metadata.format, 'pbf');
      expect(metadata.isVector, isTrue);
      expect(metadata.compression, 'gzip');
      expect(metadata.attribution, contains('OpenStreetMap'));
      expect(metadata.description, 'Extract');
      expect(metadata.minZoom, 4);
      expect(metadata.maxZoom, 14);
      expect(metadata.bounds!.south, closeTo(47.2, 1e-9));
      expect(metadata.bounds!.west, closeTo(8.9, 1e-9));
      expect(metadata.bounds!.north, closeTo(50.6, 1e-9));
      expect(metadata.bounds!.east, closeTo(13.9, 1e-9));
      expect(metadata.center!.latitude, closeTo(48.1, 1e-9));
      expect(metadata.center!.longitude, closeTo(11.5, 1e-9));
      expect(metadata.centerZoom, 10);
    });

    test('keeps every row readable, including unmodelled ones', () {
      final metadata = MbTilesMetadata.parse(const {
        'name': 'x',
        'json': '{"vector_layers":[]}',
        'scheme': 'tms',
      });

      expect(metadata.values['json'], '{"vector_layers":[]}');
      expect(metadata.values['scheme'], 'tms');
      expect(() => metadata.values['name'] = 'y', throwsUnsupportedError);
    });

    test('degrades to null rather than throwing on malformed values', () {
      final metadata = MbTilesMetadata.parse(const {
        'minzoom': 'low',
        'maxzoom': '',
        'bounds': '8.9,47.2,not-a-number,50.6',
        'center': 'somewhere',
      });

      expect(metadata.minZoom, isNull);
      expect(metadata.maxZoom, isNull);
      expect(metadata.bounds, isNull);
      expect(metadata.center, isNull);
      expect(metadata.centerZoom, isNull);
    });

    test('rejects bounds that are out of range or inverted', () {
      boundsOf(String raw) => MbTilesMetadata.parse({'bounds': raw}).bounds;

      expect(boundsOf('8.9,50.6,13.9,47.2'), isNull, reason: 'south > north');
      expect(boundsOf('8.9,-91,13.9,50.6'), isNull);
      expect(boundsOf('8.9,47.2,181,50.6'), isNull);
      expect(boundsOf('8.9,47.2,13.9'), isNull, reason: 'too few');
      expect(boundsOf('-180,-90,180,90'), isNotNull);
    });

    test('an empty metadata table yields empty defaults, not an error', () {
      final metadata = MbTilesMetadata.parse(const {});

      expect(metadata.name, '');
      expect(metadata.format, '');
      expect(metadata.isVector, isFalse);
      expect(metadata.compression, isNull);
      expect(metadata.minZoom, isNull);
      expect(metadata.bounds, isNull);
    });

    test('format is lowercased and mvt counts as vector', () {
      expect(MbTilesMetadata.parse(const {'format': 'PNG'}).format, 'png');
      expect(MbTilesMetadata.parse(const {'format': 'PNG'}).isVector, isFalse);
      expect(MbTilesMetadata.parse(const {'format': 'MVT'}).isVector, isTrue);
    });
  });
}
