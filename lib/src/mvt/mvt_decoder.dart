import 'dart:convert';
import 'dart:typed_data';

import 'mvt_tile.dart';

/// Decodes Mapbox Vector Tile (MVT 2.1) protobuf bytes.
///
/// This is a purpose-built decoder for the fixed MVT schema — it avoids a
/// general protobuf dependency and decodes geometry directly into
/// `Float32List`s, which transfer cheaply between isolates.
MvtTile decodeMvt(Uint8List bytes) {
  final r = _Reader(bytes);
  final layers = <MvtLayer>[];
  while (!r.atEnd) {
    final tag = r.readVarint();
    final field = tag >> 3;
    final wire = tag & 0x7;
    if (field == 3 && wire == 2) {
      layers.add(_decodeLayer(r.readMessage()));
    } else {
      r.skip(wire);
    }
  }
  return MvtTile(layers);
}

MvtLayer _decodeLayer(_Reader r) {
  var name = '';
  var extent = 4096;
  final keys = <String>[];
  final values = <Object?>[];
  final featureSlices = <_Reader>[];
  while (!r.atEnd) {
    final tag = r.readVarint();
    switch (tag) {
      case 10: // field 1, wire 2 — name
        name = r.readString();
      case 18: // field 2, wire 2 — feature
        featureSlices.add(r.readMessage());
      case 26: // field 3, wire 2 — key
        keys.add(r.readString());
      case 34: // field 4, wire 2 — value
        values.add(_decodeValue(r.readMessage()));
      case 40: // field 5, wire 0 — extent
        extent = r.readVarint();
      case 120: // field 15, wire 0 — version
        r.readVarint();
      default:
        r.skip(tag & 0x7);
    }
  }
  final features = <MvtFeature>[];
  for (final slice in featureSlices) {
    final feature = _decodeFeature(slice);
    if (feature != null) features.add(feature);
  }
  return MvtLayer(
    name: name,
    extent: extent,
    keys: keys,
    values: values,
    features: features,
  );
}

Object? _decodeValue(_Reader r) {
  Object? value;
  while (!r.atEnd) {
    final tag = r.readVarint();
    switch (tag) {
      case 10: // field 1, wire 2
        value = r.readString();
      case 21: // field 2, wire 5
        value = r.readFloat();
      case 25: // field 3, wire 1
        value = r.readDouble();
      case 32: // field 4, wire 0
        value = r.readVarint();
      case 40: // field 5, wire 0
        value = r.readVarint();
      case 48: // field 6, wire 0
        value = _zigzag(r.readVarint());
      case 56: // field 7, wire 0
        value = r.readVarint() != 0;
      default:
        r.skip(tag & 0x7);
    }
  }
  return value;
}

MvtFeature? _decodeFeature(_Reader r) {
  var id = 0;
  var type = MvtGeomType.unknown;
  Uint32List tags = Uint32List(0);
  Uint32List geometry = Uint32List(0);
  while (!r.atEnd) {
    final tag = r.readVarint();
    switch (tag) {
      case 8: // field 1, wire 0
        id = r.readVarint();
      case 18: // field 2, wire 2
        tags = r.readPackedVarints();
      case 24: // field 3, wire 0
        final t = r.readVarint();
        type = t >= 0 && t < MvtGeomType.values.length
            ? MvtGeomType.values[t]
            : MvtGeomType.unknown;
      case 34: // field 4, wire 2
        geometry = r.readPackedVarints();
      default:
        r.skip(tag & 0x7);
    }
  }
  if (type == MvtGeomType.unknown || geometry.isEmpty) return null;
  return _decodeGeometry(id, type, tags, geometry);
}

const int _cmdMoveTo = 1;
const int _cmdLineTo = 2;
const int _cmdClosePath = 7;

MvtFeature? _decodeGeometry(
  int id,
  MvtGeomType type,
  Uint32List tags,
  Uint32List geometry,
) {
  final parts = <Float32List>[];
  final areas = <double>[];

  var x = 0;
  var y = 0;
  var i = 0;
  List<double>? current;

  void flush() {
    final c = current;
    current = null;
    if (c == null) return;
    // Points need 1 vertex, lines 2, rings 3.
    final minVertices = switch (type) {
      MvtGeomType.point => 1,
      MvtGeomType.lineString => 2,
      _ => 3,
    };
    if (c.length < minVertices * 2) return;
    final part = Float32List.fromList(c);
    if (type == MvtGeomType.polygon) {
      areas.add(_shoelace(part));
    }
    parts.add(part);
  }

  while (i < geometry.length) {
    final command = geometry[i++];
    final cmdId = command & 0x7;
    final count = command >> 3;
    switch (cmdId) {
      case _cmdMoveTo:
        for (var n = 0; n < count && i + 2 <= geometry.length; n++) {
          x += _zigzag(geometry[i++]);
          y += _zigzag(geometry[i++]);
          if (type == MvtGeomType.point) {
            (current ??= <double>[])
              ..add(x.toDouble())
              ..add(y.toDouble());
          } else {
            flush();
            current = <double>[x.toDouble(), y.toDouble()];
          }
        }
      case _cmdLineTo:
        final c = current;
        if (c == null) return null; // malformed: LineTo before MoveTo
        for (var n = 0; n < count && i + 2 <= geometry.length; n++) {
          x += _zigzag(geometry[i++]);
          y += _zigzag(geometry[i++]);
          c
            ..add(x.toDouble())
            ..add(y.toDouble());
        }
      case _cmdClosePath:
        // Rings are stored implicitly closed; nothing to append.
        break;
      default:
        return null; // malformed command
    }
  }
  flush();
  if (parts.isEmpty) return null;
  return MvtFeature(
    id: id,
    type: type,
    tags: tags,
    parts: parts,
    ringAreas: areas.isNotEmpty ? Float64List.fromList(areas) : Float64List(0),
  );
}

/// Shoelace area in y-down (screen) coordinates: positive for
/// clockwise-on-screen rings, i.e. MVT exterior rings.
double _shoelace(Float32List ring) {
  var sum = 0.0;
  final n = ring.length;
  for (var i = 0; i + 3 < n; i += 2) {
    sum += (ring[i] - ring[i + 2]) * (ring[i + 1] + ring[i + 3]);
  }
  // Closing segment back to the first vertex.
  sum += (ring[n - 2] - ring[0]) * (ring[n - 1] + ring[1]);
  return sum / 2;
}

int _zigzag(int value) => (value >> 1) ^ -(value & 1);

/// Minimal protobuf wire-format reader over a byte range.
class _Reader {
  final Uint8List _bytes;
  final ByteData _data;
  int _pos;
  final int _end;

  _Reader(Uint8List bytes, [int start = 0, int? end])
      : _bytes = bytes,
        _data = ByteData.sublistView(bytes),
        _pos = start,
        _end = end ?? bytes.length;

  bool get atEnd => _pos >= _end;

  int readVarint() {
    var result = 0;
    var shift = 0;
    while (true) {
      if (_pos >= _end) {
        throw const FormatException('truncated varint');
      }
      final byte = _bytes[_pos++];
      result |= (byte & 0x7f) << shift;
      if (byte & 0x80 == 0) break;
      shift += 7;
      if (shift > 63) throw const FormatException('varint too long');
    }
    return result;
  }

  double readFloat() {
    if (_pos + 4 > _end) throw const FormatException('truncated float');
    final v = _data.getFloat32(_pos, Endian.little);
    _pos += 4;
    return v;
  }

  double readDouble() {
    if (_pos + 8 > _end) throw const FormatException('truncated double');
    final v = _data.getFloat64(_pos, Endian.little);
    _pos += 8;
    return v;
  }

  String readString() {
    final len = readVarint();
    if (_pos + len > _end) throw const FormatException('truncated string');
    final s = utf8.decode(
      Uint8List.sublistView(_bytes, _pos, _pos + len),
      allowMalformed: true,
    );
    _pos += len;
    return s;
  }

  /// Reads a length-delimited sub-message as a scoped reader.
  _Reader readMessage() {
    final len = readVarint();
    if (_pos + len > _end) throw const FormatException('truncated message');
    final r = _Reader(_bytes, _pos, _pos + len);
    _pos += len;
    return r;
  }

  Uint32List readPackedVarints() {
    final len = readVarint();
    final end = _pos + len;
    if (end > _end) throw const FormatException('truncated packed field');
    // Upper bound: one varint per byte.
    final out = Uint32List(len);
    var n = 0;
    while (_pos < end) {
      var result = 0;
      var shift = 0;
      while (true) {
        final byte = _bytes[_pos++];
        result |= (byte & 0x7f) << shift;
        if (byte & 0x80 == 0) break;
        shift += 7;
      }
      out[n++] = result;
    }
    return Uint32List.sublistView(out, 0, n);
  }

  void skip(int wireType) {
    switch (wireType) {
      case 0:
        readVarint();
      case 1:
        _pos += 8;
      case 2:
        final len = readVarint();
        _pos += len;
      case 5:
        _pos += 4;
      default:
        throw FormatException('unsupported wire type $wireType');
    }
    if (_pos > _end) throw const FormatException('truncated field');
  }
}
