import 'package:flutter/painting.dart';
import 'package:flutter_map_vector_tiles/src/render/glyph_atlas.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  void dot(Canvas canvas) =>
      canvas.drawRect(const Rect.fromLTWH(0, 0, 4, 4), Paint());

  test('cells do not overlap and keep a gap', () {
    final atlas = GlyphAtlas(pageSize: 64);
    addTearDown(atlas.clear);
    final rects = [
      for (var i = 0; i < 12; i++) atlas.reserve(i, 10, 14, dot)!.rect,
    ];
    for (var i = 0; i < rects.length; i++) {
      for (var j = i + 1; j < rects.length; j++) {
        expect(rects[i].inflate(1).overlaps(rects[j]), isFalse);
      }
    }
    atlas.flush();
    expect(atlas.imageOf(atlas.lookup(0)!), isNotNull);
  });

  test('a lookup returns the reserved cell', () {
    final atlas = GlyphAtlas(pageSize: 64);
    addTearDown(atlas.clear);
    final cell = atlas.reserve(('a', true, 128), 8, 8, dot);
    expect(atlas.lookup(('a', true, 128)), same(cell));
    expect(atlas.reserve(('a', true, 128), 8, 8, dot), same(cell));
  });

  test('a glyph larger than a page is refused', () {
    final atlas = GlyphAtlas(pageSize: 64);
    expect(atlas.reserve(0, 80, 8, dot), isNull);
  });

  test('a full atlas evicts the least recently used page', () {
    final atlas = GlyphAtlas(pageSize: 32, maxPages: 2);
    addTearDown(atlas.clear);
    // One 30×30 cell (plus gap) fills a 32px page.
    atlas.beginFrame();
    atlas.reserve('old', 30, 30, dot);
    atlas.beginFrame();
    atlas.reserve('recent', 30, 30, dot);
    atlas.flush();
    atlas.beginFrame();
    atlas.lookup('recent');
    expect(atlas.reserve('new', 30, 30, dot), isNotNull);
    expect(atlas.debugPageCount, 2);
    expect(atlas.lookup('old'), isNull, reason: 'its page was reused');
    expect(atlas.lookup('recent'), isNotNull);
  });

  test('pages used this frame are never evicted', () {
    final atlas = GlyphAtlas(pageSize: 32, maxPages: 1);
    addTearDown(atlas.clear);
    atlas.beginFrame();
    atlas.reserve('a', 30, 30, dot);
    expect(atlas.reserve('b', 30, 30, dot), isNull,
        reason: 'the only page holds a glyph this frame draws');
    expect(atlas.lookup('a'), isNotNull);
  });

  test('clear drops every cell', () {
    final atlas = GlyphAtlas(pageSize: 64);
    atlas.reserve(0, 8, 8, dot);
    atlas.flush();
    atlas.clear();
    expect(atlas.debugPageCount, 0);
    expect(atlas.lookup(0), isNull);
  });
}
