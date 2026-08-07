import 'package:flutter_map_vector_tiles/src/core/tile_key.dart';
import 'package:flutter_map_vector_tiles/src/grid/tile_retention.dart';
import 'package:flutter_test/flutter_test.dart';

CurrentTileStatus _tile(
  TileKey key, {
  bool isLoading = false,
  bool hasSymbols = true,
  bool isFadedIn = true,
}) =>
    (
      key: key,
      isLoading: isLoading,
      hasSymbols: hasSymbols,
      isFadedIn: isFadedIn,
    );

void main() {
  group('tilesOverlap', () {
    test('same zoom: only the identical tile overlaps', () {
      const a = TileKey(14, 100, 100);
      expect(tilesOverlap(a, const TileKey(14, 100, 100)), isTrue);
      expect(tilesOverlap(a, const TileKey(14, 101, 100)), isFalse);
      expect(tilesOverlap(a, const TileKey(14, 100, 101)), isFalse);
    });

    test('a parent overlaps each of its four children', () {
      const parent = TileKey(14, 100, 100);
      for (final child in [
        const TileKey(15, 200, 200),
        const TileKey(15, 201, 200),
        const TileKey(15, 200, 201),
        const TileKey(15, 201, 201),
      ]) {
        expect(tilesOverlap(parent, child), isTrue, reason: '$child');
        // The relation is symmetric.
        expect(tilesOverlap(child, parent), isTrue, reason: '$child reversed');
      }
    });

    test('a parent does not overlap a neighbour\'s children', () {
      const parent = TileKey(14, 100, 100);
      expect(tilesOverlap(parent, const TileKey(15, 202, 200)), isFalse);
      expect(tilesOverlap(parent, const TileKey(15, 199, 200)), isFalse);
      expect(tilesOverlap(parent, const TileKey(15, 200, 202)), isFalse);
    });

    test('overlap holds across a multi-level gap', () {
      // Zooming several levels at once still keeps the ancestor visible.
      const ancestor = TileKey(12, 10, 20);
      expect(
          tilesOverlap(ancestor, const TileKey(16, 10 * 16, 20 * 16)), isTrue);
      expect(
          tilesOverlap(ancestor, const TileKey(16, 10 * 16 + 15, 20 * 16 + 15)),
          isTrue);
      expect(tilesOverlap(ancestor, const TileKey(16, 10 * 16 - 1, 20 * 16)),
          isFalse);
    });
  });

  group('currentLevelReady', () {
    const key = TileKey(15, 200, 200);

    test('a still-loading tile holds the previous level', () {
      expect(currentLevelReady([_tile(key, isLoading: true)]), isFalse);
    });

    test('a mid-fade tile holds the previous level', () {
      // This is the 0.4.1 blink: dropping the old level while the new
      // one is only part-way faded in dips to the background colour.
      expect(currentLevelReady([_tile(key, isFadedIn: false)]), isFalse);
    });

    test('the previous level goes once every tile is loaded and faded in', () {
      expect(
          currentLevelReady([
            _tile(const TileKey(15, 200, 200)),
            _tile(const TileKey(15, 201, 200)),
          ]),
          isTrue);
    });

    test('one unfinished tile among many is enough to hold it', () {
      expect(
          currentLevelReady([
            _tile(const TileKey(15, 200, 200)),
            _tile(const TileKey(15, 201, 200), isFadedIn: false),
            _tile(const TileKey(15, 202, 200)),
          ]),
          isFalse);
    });
  });

  group('retainedSymbolsNeeded', () {
    const retained = TileKey(14, 100, 100);
    // The four children of `retained` at the incoming zoom level.
    const childA = TileKey(15, 200, 200);
    const childB = TileKey(15, 201, 200);

    test('a retained tile with no labels is never needed', () {
      expect(
          retainedSymbolsNeeded(
            retainedKey: retained,
            hasSymbols: false,
            current: [_tile(childA, hasSymbols: false, isLoading: true)],
          ),
          isFalse);
    });

    test('needed while an overlapping tile is still loading its labels', () {
      expect(
          retainedSymbolsNeeded(
            retainedKey: retained,
            hasSymbols: true,
            current: [_tile(childA, hasSymbols: false, isLoading: true)],
          ),
          isTrue,
          reason: 'otherwise every label blinks out during the zoom');
    });

    test('dropped once the overlapping tile has its own labels', () {
      expect(
          retainedSymbolsNeeded(
            retainedKey: retained,
            hasSymbols: true,
            current: [_tile(childA, hasSymbols: true, isLoading: true)],
          ),
          isFalse,
          reason: 'provisional symbols already cover this ground');
    });

    test('dropped once the overlapping tile has finished loading', () {
      // Loaded but genuinely label-free ground (e.g. open countryside)
      // must not resurrect the old level's labels forever.
      expect(
          retainedSymbolsNeeded(
            retainedKey: retained,
            hasSymbols: true,
            current: [_tile(childA, hasSymbols: false, isLoading: false)],
          ),
          isFalse);
    });

    test('needed when nothing of the current level overlaps it', () {
      // Panning during a zoom change can leave retained ground that the
      // new grid does not cover yet.
      expect(
          retainedSymbolsNeeded(
            retainedKey: retained,
            hasSymbols: true,
            current: [_tile(const TileKey(15, 400, 400))],
          ),
          isTrue);
    });

    test('needed when an empty current grid leaves it uncovered', () {
      expect(
          retainedSymbolsNeeded(
            retainedKey: retained,
            hasSymbols: true,
            current: const [],
          ),
          isTrue);
    });

    test('one loading child is enough, even if its sibling is ready', () {
      expect(
          retainedSymbolsNeeded(
            retainedKey: retained,
            hasSymbols: true,
            current: [
              _tile(childA, hasSymbols: true, isLoading: false),
              _tile(childB, hasSymbols: false, isLoading: true),
            ],
          ),
          isTrue);
    });

    test('non-overlapping loading tiles do not keep it alive', () {
      // A tile loading elsewhere on screen says nothing about this
      // retained tile's ground.
      expect(
          retainedSymbolsNeeded(
            retainedKey: retained,
            hasSymbols: true,
            current: [
              _tile(childA, hasSymbols: true, isLoading: false),
              _tile(const TileKey(15, 400, 400),
                  hasSymbols: false, isLoading: true),
            ],
          ),
          isFalse);
    });
  });
}
