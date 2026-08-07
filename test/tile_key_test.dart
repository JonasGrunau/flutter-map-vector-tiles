import 'package:flutter_map_vector_tiles/src/core/tile_key.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ancestor computation', () {
    const key = TileKey(14, 8802, 5373);
    expect(key.ancestorAt(12), const TileKey(12, 2200, 1343));
    expect(key.parent, const TileKey(13, 4401, 2686));
  });

  test('wrapping normalizes x', () {
    expect(TileKey.wrapped(2, -1, 1), const TileKey(2, 3, 1));
    expect(TileKey.wrapped(2, 4, 1), const TileKey(2, 0, 1));
    expect(TileKey.wrapped(2, 2, 1), const TileKey(2, 2, 1));
  });

  test('fractionOf for direct child', () {
    const parent = TileKey(3, 2, 5);
    const child = TileKey(4, 5, 10);
    final f = child.fractionOf(parent);
    expect(f.scale, 0.5);
    expect(f.dx, 0.5);
    expect(f.dy, 0.0);
  });

  test('fractionOf across two levels', () {
    const ancestor = TileKey(2, 1, 1);
    const key = TileKey(4, 7, 6);
    final f = key.fractionOf(ancestor);
    expect(f.scale, 0.25);
    expect(f.dx, 0.75);
    expect(f.dy, 0.5);
  });

  test('fractionOf survives longitude wrap', () {
    // Unwrapped display tile at x=-1 (z2) corresponds to wrapped x=3,
    // whose parent at z1 is x=1.
    const display = TileKey(2, -1, 1);
    const data = TileKey(1, 1, 0);
    final f = display.fractionOf(data);
    expect(f.scale, 0.5);
    expect(f.dx, 0.5);
    expect(f.dy, 0.5);
  });

  test('validity check', () {
    expect(const TileKey(2, 0, 3).isValid, true);
    expect(const TileKey(2, 0, 4).isValid, false);
    expect(const TileKey(2, 0, -1).isValid, false);
  });
}
