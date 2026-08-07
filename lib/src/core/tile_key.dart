import 'package:meta/meta.dart';

/// Identifies a slippy-map tile by zoom and grid position.
///
/// [x] is always normalized to `0 <= x < 2^z` (the world wraps in
/// longitude); [y] is expected to be within `0 <= y < 2^z`.
@immutable
class TileKey {
  final int z;
  final int x;
  final int y;

  const TileKey(this.z, this.x, this.y);

  /// Creates a key with [x] wrapped into the valid range for [z].
  factory TileKey.wrapped(int z, int x, int y) {
    final n = 1 << z;
    var wx = x % n;
    if (wx < 0) wx += n;
    return TileKey(z, wx, y);
  }

  /// Whether [y] lies inside the world grid at this zoom.
  bool get isValid => z >= 0 && y >= 0 && y < (1 << z);

  /// The ancestor of this tile at [ancestorZoom], which must be `<= z`.
  TileKey ancestorAt(int ancestorZoom) {
    assert(ancestorZoom <= z);
    final shift = z - ancestorZoom;
    return TileKey(ancestorZoom, x >> shift, y >> shift);
  }

  TileKey get parent => ancestorAt(z - 1);

  /// This tile's position within its ancestor at [ancestorZoom], in
  /// fractional tile units of the ancestor (0..1 origin, size `2^-shift`).
  ///
  /// Used to render the correct sub-region of an overzoomed data tile.
  /// Robust against longitude wrapping: this key may be unwrapped
  /// (x outside `0..2^z`) while [ancestor] is wrapped.
  ({double dx, double dy, double scale}) fractionOf(TileKey ancestor) {
    assert(ancestor.z <= z);
    final shift = z - ancestor.z;
    final n = 1 << shift;
    // Dart's % always returns a non-negative result here.
    final dxTiles = (x - (ancestor.x << shift)) % (1 << z);
    return (
      dx: dxTiles / n,
      dy: (y - (ancestor.y << shift)) / n,
      scale: 1.0 / n,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is TileKey && other.z == z && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(z, x, y);

  @override
  String toString() => 'TileKey($z/$x/$y)';
}
