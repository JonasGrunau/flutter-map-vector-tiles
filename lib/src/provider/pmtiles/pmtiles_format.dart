import 'dart:typed_data';

/// PMTiles v3 binary format: header, directory entries and the
/// Hilbert-curve tile addressing scheme.
///
/// Everything here must stay web-safe: offsets and tile IDs routinely
/// exceed 2^32, so 64-bit values are assembled with multiply/add
/// arithmetic (exact up to 2^53 as JS doubles) — never with bitwise
/// operators, which dart2js truncates to 32 bits, and never with
/// `ByteData.getUint64`, which throws on the web.

/// Compression enum shared by the internal (directory/metadata) and
/// tile compression header fields.
abstract final class PmTilesCompression {
  static const unknown = 0;
  static const none = 1;
  static const gzip = 2;
  static const brotli = 3;
  static const zstd = 4;
}

class PmTilesException implements Exception {
  final String message;
  const PmTilesException(this.message);

  @override
  String toString() => 'PmTilesException: $message';
}

/// The fixed 127-byte archive header.
class PmTilesHeader {
  static const length = 127;

  final int rootDirectoryOffset;
  final int rootDirectoryLength;
  final int metadataOffset;
  final int metadataLength;
  final int leafDirectoriesOffset;
  final int leafDirectoriesLength;
  final int tileDataOffset;
  final int tileDataLength;
  final bool clustered;
  final int internalCompression;
  final int tileCompression;
  final int tileType;
  final int minZoom;
  final int maxZoom;

  const PmTilesHeader({
    required this.rootDirectoryOffset,
    required this.rootDirectoryLength,
    required this.metadataOffset,
    required this.metadataLength,
    required this.leafDirectoriesOffset,
    required this.leafDirectoriesLength,
    required this.tileDataOffset,
    required this.tileDataLength,
    required this.clustered,
    required this.internalCompression,
    required this.tileCompression,
    required this.tileType,
    required this.minZoom,
    required this.maxZoom,
  });

  static PmTilesHeader parse(Uint8List bytes) {
    if (bytes.length < length) {
      throw const PmTilesException('archive shorter than the 127-byte header');
    }
    const magic = [0x50, 0x4D, 0x54, 0x69, 0x6C, 0x65, 0x73]; // "PMTiles"
    for (var i = 0; i < magic.length; i++) {
      if (bytes[i] != magic[i]) {
        throw const PmTilesException('not a PMTiles archive (bad magic)');
      }
    }
    final version = bytes[7];
    if (version != 3) {
      throw PmTilesException('unsupported PMTiles version $version');
    }
    final data = ByteData.sublistView(bytes);
    // Web-safe u64: two little-endian u32 halves.
    int u64(int offset) =>
        data.getUint32(offset, Endian.little) +
        data.getUint32(offset + 4, Endian.little) * 4294967296;
    return PmTilesHeader(
      rootDirectoryOffset: u64(8),
      rootDirectoryLength: u64(16),
      metadataOffset: u64(24),
      metadataLength: u64(32),
      leafDirectoriesOffset: u64(40),
      leafDirectoriesLength: u64(48),
      tileDataOffset: u64(56),
      tileDataLength: u64(64),
      clustered: bytes[96] == 1,
      internalCompression: bytes[97],
      tileCompression: bytes[98],
      tileType: bytes[99],
      minZoom: bytes[100],
      maxZoom: bytes[101],
    );
  }
}

/// One directory entry: a tile blob (`runLength` >= 1, covering
/// `runLength` consecutive tile IDs) or a leaf directory
/// (`runLength` == 0).
class PmTilesEntry {
  final int tileId;
  final int offset;
  final int length;
  final int runLength;

  const PmTilesEntry({
    required this.tileId,
    required this.offset,
    required this.length,
    required this.runLength,
  });

  bool get isLeaf => runLength == 0;
}

/// A decoded (decompressed) directory.
class PmTilesDirectory {
  final List<PmTilesEntry> entries;
  const PmTilesDirectory(this.entries);

  /// Decodes the five serialized sections: entry count, delta-encoded
  /// tile IDs, run lengths, lengths, and offsets (where `0` means
  /// "contiguous with the previous entry").
  static PmTilesDirectory decode(Uint8List bytes) {
    final reader = _VarintReader(bytes);
    final count = reader.read();
    final tileIds = List<int>.filled(count, 0);
    var lastId = 0;
    for (var i = 0; i < count; i++) {
      lastId += reader.read();
      tileIds[i] = lastId;
    }
    final runLengths = [for (var i = 0; i < count; i++) reader.read()];
    final lengths = [for (var i = 0; i < count; i++) reader.read()];
    final entries = <PmTilesEntry>[];
    var offset = 0;
    for (var i = 0; i < count; i++) {
      final value = reader.read();
      offset = value == 0 && i > 0
          ? entries[i - 1].offset + entries[i - 1].length
          : value - 1;
      entries.add(PmTilesEntry(
        tileId: tileIds[i],
        offset: offset,
        length: lengths[i],
        runLength: runLengths[i],
      ));
    }
    return PmTilesDirectory(entries);
  }

  /// Finds the entry serving [tileId]: an exact or run-length-window
  /// tile entry, or the leaf directory covering the ID range. Returns
  /// null when the tile is absent.
  PmTilesEntry? find(int tileId) {
    var low = 0;
    var high = entries.length - 1;
    while (low <= high) {
      final mid = (low + high) ~/ 2;
      final cmp = tileId - entries[mid].tileId;
      if (cmp > 0) {
        low = mid + 1;
      } else if (cmp < 0) {
        high = mid - 1;
      } else {
        return entries[mid];
      }
    }
    if (high >= 0) {
      final entry = entries[high];
      if (entry.isLeaf) return entry;
      if (tileId - entry.tileId < entry.runLength) return entry;
    }
    return null;
  }
}

class _VarintReader {
  final Uint8List _bytes;
  var _pos = 0;
  _VarintReader(this._bytes);

  int read() {
    var value = 0;
    var multiplier = 1;
    while (true) {
      if (_pos >= _bytes.length) {
        throw const PmTilesException('truncated directory (varint overrun)');
      }
      final b = _bytes[_pos++];
      value += (b & 0x7f) * multiplier;
      if (b < 0x80) return value;
      multiplier *= 128;
    }
  }
}

/// Highest zoom whose tile IDs stay exactly representable as JS doubles
/// (z=27 IDs would exceed 2^53).
const pmTilesMaxAddressableZoom = 26;

/// Maps z/x/y to the cumulative Hilbert-curve tile ID used by PMTiles:
/// all tiles of zooms below [z] first, then the position of (x, y) on
/// the zoom-[z] Hilbert curve.
int zxyToTileId(int z, int x, int y) {
  if (z < 0 || z > pmTilesMaxAddressableZoom) {
    throw PmTilesException('zoom $z outside the addressable range');
  }
  var acc = 0;
  var n = 1; // 2^i in the loop, 2^z after it
  for (var i = 0; i < z; i++) {
    acc += n * n; // 4^i tiles at zoom i
    n *= 2;
  }
  var tx = x;
  var ty = y;
  var d = 0;
  // s < 2^26, so per-step bitwise tests stay within 32 bits; only the
  // accumulator d needs (and gets) arithmetic-only handling.
  for (var s = n ~/ 2; s > 0; s = s ~/ 2) {
    final rx = (tx & s) > 0 ? 1 : 0;
    final ry = (ty & s) > 0 ? 1 : 0;
    d += s * s * ((3 * rx) ^ ry);
    if (ry == 0) {
      if (rx == 1) {
        tx = s - 1 - tx;
        ty = s - 1 - ty;
      }
      final t = tx;
      tx = ty;
      ty = t;
    }
  }
  return acc + d;
}
