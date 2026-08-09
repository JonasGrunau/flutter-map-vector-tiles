import 'dart:convert';
import 'dart:typed_data';

/// Minimal MVT (protobuf) encoder for tests — the inverse of the
/// package's decoder, written independently against the MVT 2.1 spec.
class MvtTileBuilder {
  final List<Uint8List> _layers = [];

  MvtLayerBuilder layer(String name, {int extent = 4096}) =>
      MvtLayerBuilder._(this, name, extent);

  Uint8List build() {
    final out = BytesBuilder();
    for (final layer in _layers) {
      _writeTag(out, 3, 2);
      _writeVarint(out, layer.length);
      out.add(layer);
    }
    return out.toBytes();
  }
}

class MvtLayerBuilder {
  final MvtTileBuilder _tile;
  final String name;
  final int extent;
  final List<String> _keys = [];
  final List<Object?> _values = [];
  final List<Uint8List> _features = [];

  MvtLayerBuilder._(this._tile, this.name, this.extent);

  /// [geometry] is the raw command/parameter integer sequence.
  MvtLayerBuilder feature({
    required int type,
    required List<int> geometry,
    Map<String, Object?> properties = const {},
    int? id,
  }) {
    final tags = <int>[];
    properties.forEach((key, value) {
      var k = _keys.indexOf(key);
      if (k < 0) {
        _keys.add(key);
        k = _keys.length - 1;
      }
      var v = _values.indexOf(value);
      if (v < 0) {
        _values.add(value);
        v = _values.length - 1;
      }
      tags
        ..add(k)
        ..add(v);
    });

    final out = BytesBuilder();
    if (id != null) {
      _writeTag(out, 1, 0);
      _writeVarint(out, id);
    }
    if (tags.isNotEmpty) {
      _writeTag(out, 2, 2);
      _writePacked(out, tags);
    }
    _writeTag(out, 3, 0);
    _writeVarint(out, type);
    _writeTag(out, 4, 2);
    _writePacked(out, geometry);
    _features.add(out.toBytes());
    return this;
  }

  MvtTileBuilder done() {
    final out = BytesBuilder();
    _writeTag(out, 1, 2);
    _writeString(out, name);
    for (final feature in _features) {
      _writeTag(out, 2, 2);
      _writeVarint(out, feature.length);
      out.add(feature);
    }
    for (final key in _keys) {
      _writeTag(out, 3, 2);
      _writeString(out, key);
    }
    for (final value in _values) {
      final v = BytesBuilder();
      if (value is String) {
        _writeTag(v, 1, 2);
        _writeString(v, value);
      } else if (value is double) {
        _writeTag(v, 3, 1);
        final data = ByteData(8)..setFloat64(0, value, Endian.little);
        v.add(data.buffer.asUint8List());
      } else if (value is int) {
        if (value < 0) {
          // sint_value, as real encoders write negatives; also exercises
          // the decoder's second zigzag call site.
          _writeTag(v, 6, 0);
          _writeVarint(v, zig(value));
        } else {
          _writeTag(v, 4, 0);
          _writeVarint(v, value);
        }
      } else if (value is bool) {
        _writeTag(v, 7, 0);
        _writeVarint(v, value ? 1 : 0);
      }
      final bytes = v.toBytes();
      _writeTag(out, 4, 2);
      _writeVarint(out, bytes.length);
      out.add(bytes);
    }
    _writeTag(out, 5, 0);
    _writeVarint(out, extent);
    _writeTag(out, 15, 0);
    _writeVarint(out, 2);
    _tile._layers.add(out.toBytes());
    return _tile;
  }
}

/// Geometry command helpers.
int cmd(int id, int count) => (count << 3) | id;

/// Zigzag-encodes [v], the inverse of the decoder's `_zigzag`.
///
/// Arithmetic rather than `(v << 1) ^ (v >> 31)`: dart2js truncates those
/// bitwise ops to 32 bits, so the shift form encodes negative deltas wrongly
/// on web and the round-trip tests would pass for the wrong reason there.
int zig(int v) => v < 0 ? -2 * v - 1 : 2 * v;

void _writeTag(BytesBuilder out, int field, int wire) =>
    _writeVarint(out, (field << 3) | wire);

void _writeVarint(BytesBuilder out, int value) {
  var v = value;
  while (v >= 0x80) {
    out.addByte((v & 0x7f) | 0x80);
    v ~/= 128; // not `>>= 7`: dart2js shifts truncate to 32 bits
  }
  out.addByte(v);
}

void _writeString(BytesBuilder out, String s) {
  final bytes = utf8.encode(s);
  _writeVarint(out, bytes.length);
  out.add(bytes);
}

void _writePacked(BytesBuilder out, List<int> values) {
  final payload = BytesBuilder();
  for (final v in values) {
    _writeVarint(payload, v);
  }
  final bytes = payload.toBytes();
  _writeVarint(out, bytes.length);
  out.add(bytes);
}
