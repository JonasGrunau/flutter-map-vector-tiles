import 'dart:typed_data';

import 'package:flutter_map_vector_tiles/src/mvt/mvt_decoder.dart';
import 'package:flutter_map_vector_tiles/src/mvt/mvt_tile.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/mvt_builder.dart';

void _varint(BytesBuilder out, int value) {
  var v = value;
  while (v >= 0x80) {
    out.addByte((v & 0x7f) | 0x80);
    v ~/= 128; // not `>>= 7`: dart2js shifts truncate to 32 bits
  }
  out.addByte(v);
}

/// The 10-byte two's-complement varint of `-magnitude`, built digit-wise
/// (`2^64 - m == (2^64-1) - (m-1)`, and `2^64-1` is all-127 digits) so
/// the test itself stays exact under dart2js.
List<int> _negativeInt64Varint(int magnitude) {
  var rest = magnitude - 1;
  final bytes = <int>[];
  for (var k = 0; k < 9; k++) {
    bytes.add((127 - (rest % 128)) | 0x80);
    rest ~/= 128;
  }
  bytes.add(1 - rest);
  return bytes;
}

/// A one-layer tile whose single point feature carries one property
/// with a hand-encoded protobuf `Value` message payload.
Uint8List _tileWithRawValue(List<int> valueMessage) {
  final feature = BytesBuilder()
    ..add([0x12, 0x02, 0x00, 0x00]) // tags [0, 0]
    ..add([0x18, 0x01]) // type: point
    ..add([0x22, 0x03, 0x09, 0x00, 0x00]); // geometry: MoveTo(0, 0)
  final featureBytes = feature.toBytes();

  final layer = BytesBuilder()..add([0x0a, 0x01, 0x74]); // name: 't'
  layer.addByte(0x12); // field 2: feature
  _varint(layer, featureBytes.length);
  layer.add(featureBytes);
  layer.add([0x1a, 0x01, 0x6b]); // key: 'k'
  layer.addByte(0x22); // field 4: value
  _varint(layer, valueMessage.length);
  layer.add(valueMessage);
  layer.add([0x28, 0x80, 0x20]); // extent: 4096
  layer.add([0x78, 0x02]); // version: 2
  final layerBytes = layer.toBytes();

  final tile = BytesBuilder()..addByte(0x1a); // field 3: layer
  _varint(tile, layerBytes.length);
  tile.add(layerBytes);
  return tile.toBytes();
}

void main() {
  test('decodes a layer with a point feature and properties', () {
    final bytes = MvtTileBuilder()
        .layer('poi')
        .feature(
          type: 1,
          id: 42,
          geometry: [cmd(1, 1), zig(100), zig(200)],
          properties: {'name': 'Berlin', 'rank': 3, 'capital': true},
        )
        .done()
        .build();

    final tile = decodeMvt(bytes);
    expect(tile.layers, hasLength(1));
    final layer = tile.layers.single;
    expect(layer.name, 'poi');
    expect(layer.extent, 4096);

    final feature = layer.features.single;
    expect(feature.id, 42);
    expect(feature.type, MvtGeomType.point);
    expect(feature.parts.single, [100.0, 200.0]);
    expect(feature.decodeProperties(layer),
        {'name': 'Berlin', 'rank': 3, 'capital': true});
  });

  test('decodes multipoint geometry', () {
    final bytes = MvtTileBuilder()
        .layer('poi')
        .feature(type: 1, geometry: [
          cmd(1, 2),
          zig(10),
          zig(10),
          zig(5),
          zig(-5),
        ])
        .done()
        .build();

    final feature = decodeMvt(bytes).layers.single.features.single;
    expect(feature.parts.single, [10.0, 10.0, 15.0, 5.0]);
  });

  test('decodes linestring with cumulative coordinates', () {
    final bytes = MvtTileBuilder()
        .layer('roads')
        .feature(type: 2, geometry: [
          cmd(1, 1), zig(2), zig(2), //
          cmd(2, 2), zig(10), zig(0), zig(0), zig(10),
        ])
        .done()
        .build();

    final feature = decodeMvt(bytes).layers.single.features.single;
    expect(feature.type, MvtGeomType.lineString);
    expect(feature.parts.single, [2.0, 2.0, 12.0, 2.0, 12.0, 12.0]);
  });

  test('decodes polygon rings with winding classification', () {
    // Exterior ring (CW in y-down space): positive area.
    final bytes = MvtTileBuilder()
        .layer('water')
        .feature(type: 3, geometry: [
          cmd(1, 1), zig(0), zig(0), //
          cmd(2, 3), zig(10), zig(0), zig(0), zig(10), zig(-10), zig(0),
          cmd(7, 1),
        ])
        .done()
        .build();

    final feature = decodeMvt(bytes).layers.single.features.single;
    expect(feature.type, MvtGeomType.polygon);
    expect(feature.parts.single, [0.0, 0.0, 10.0, 0.0, 10.0, 10.0, 0.0, 10.0]);
    expect(feature.ringAreas.single, greaterThan(0));
  });

  test('decodes multiple layers and double values', () {
    final bytes = MvtTileBuilder()
        .layer('a')
        .feature(
            type: 1,
            geometry: [cmd(1, 1), zig(1), zig(1)],
            properties: {'height': 12.5})
        .done()
        .layer('b', extent: 512)
        .feature(type: 1, geometry: [cmd(1, 1), zig(2), zig(2)])
        .done()
        .build();

    final tile = decodeMvt(bytes);
    expect(tile.layers.map((l) => l.name), ['a', 'b']);
    expect(tile.layer('b')!.extent, 512);
    final props =
        tile.layers.first.features.single.decodeProperties(tile.layers.first);
    expect(props['height'], 12.5);
  });

  // Regression: `_zigzag` used to be `(v >> 1) ^ -(v & 1)`, which dart2js
  // truncates to unsigned 32 bits — negative deltas decoded as ~4.29e9 on
  // web while native was correct. Runs on both vm and chrome by design.
  test('decodes negative coordinate deltas', () {
    final bytes = MvtTileBuilder()
        .layer('lines')
        .feature(
          type: 2,
          geometry: [
            cmd(1, 1), zig(100), zig(200), // MoveTo (100, 200)
            cmd(2, 3),
            zig(-50), zig(-75), // LineTo (50, 125)
            zig(-50), zig(25), // LineTo (0, 150)
            zig(-1), zig(-150), // LineTo (-1, 0)
          ],
        )
        .done()
        .build();

    final feature = decodeMvt(bytes).layers.single.features.single;
    expect(
      feature.parts.single,
      [100.0, 200.0, 50.0, 125.0, 0.0, 150.0, -1.0, 0.0],
    );
  });

  test('zigzag round-trips the full delta range', () {
    // One feature per delta keeps each case independent of the running
    // cursor, so a failure names the exact value that broke.
    // -2^30 keeps both the delta and its negation exact in the Float32List
    // output while its zigzag encoding crosses the JS ToInt32 boundary.
    const deltas = [
      -1, -2, -3, -8191, -8192, -1000000, -1073741824, //
      0, 1, 1000000,
    ];
    for (final delta in deltas) {
      final bytes = MvtTileBuilder()
          .layer('l')
          .feature(type: 1, geometry: [cmd(1, 1), zig(delta), zig(-delta)])
          .done()
          .build();
      final part = decodeMvt(bytes).layers.single.features.single.parts.single;
      expect(part, [delta.toDouble(), -delta.toDouble()],
          reason: 'delta $delta');
    }
  });

  test('decodes negative sint property values', () {
    final bytes = MvtTileBuilder()
        .layer('poi')
        .feature(
          type: 1,
          geometry: [cmd(1, 1), zig(10), zig(10)],
          properties: {'elevation': -42, 'rank': 3},
        )
        .done()
        .build();

    final layer = decodeMvt(bytes).layers.single;
    expect(
      layer.features.single.decodeProperties(layer),
      {'elevation': -42, 'rank': 3},
    );
  });

  test('tolerates malformed feature geometry without throwing', () {
    final bytes = MvtTileBuilder()
        .layer('bad')
        .feature(type: 2, geometry: [cmd(2, 1), zig(5), zig(5)]) // LineTo first
        .feature(type: 1, geometry: [cmd(1, 1), zig(7), zig(7)])
        .done()
        .build();

    final layer = decodeMvt(bytes).layers.single;
    // Malformed feature dropped, valid one kept.
    expect(layer.features, hasLength(1));
    expect(layer.features.single.parts.single, [7.0, 7.0]);
  });

  test('a packed field ending in a continuation byte fails loudly', () {
    // Regression: the packed-varint loop read past the declared slice —
    // silently consuming the next fields' bytes (corrupt geometry), or
    // crashing with a RangeError at the true end of the buffer.
    final feature = <int>[
      0x18, 0x01, // type: point
      0x22, 0x02, 0x09, 0x80, // geometry, len 2: [0x09, 0x80…] truncated
      0x18, 0x01, // trailing field the overrun used to swallow
    ];
    final layer = BytesBuilder()
      ..add([0x0a, 0x01, 0x74]) // name 't'
      ..addByte(0x12)
      ..addByte(feature.length)
      ..add(feature)
      ..add([0x78, 0x02]); // version
    final layerBytes = layer.toBytes();
    final tile = BytesBuilder()
      ..addByte(0x1a)
      ..addByte(layerBytes.length)
      ..add(layerBytes);

    expect(() => decodeMvt(tile.toBytes()), throwsFormatException);
  });

  test('decodes negative int_value properties (10-byte varints)', () {
    // Legal per spec, though most encoders zigzag negatives through
    // sint_value instead. Regression: under dart2js the unsigned
    // 2^64-range accumulation lost precision past 2^53, so -1 decoded
    // as ~1.8e19.
    for (final magnitude in [1, 42, 4294967296, 281474976710656]) {
      final tile =
          _tileWithRawValue([0x20, ..._negativeInt64Varint(magnitude)]);
      final layer = decodeMvt(tile).layers.single;
      expect(
        layer.features.single.decodeProperties(layer),
        {'k': -magnitude},
        reason: 'int_value -$magnitude must survive the wire exactly',
      );
    }
  });

  test('decodes large positive int_value properties unchanged', () {
    final value = BytesBuilder()..addByte(0x20);
    _varint(value, 1125899906842624); // 2^50 — an 8-byte varint
    final layer = decodeMvt(_tileWithRawValue(value.toBytes())).layers.single;
    expect(
        layer.features.single.decodeProperties(layer), {'k': 1125899906842624});
  });
}
