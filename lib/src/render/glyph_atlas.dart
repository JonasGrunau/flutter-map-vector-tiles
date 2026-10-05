import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:meta/meta.dart';

/// Pre-rasterized glyphs for curved text, packed onto a few GPU pages so
/// a whole curved label draws in one `drawRawAtlas` call per pass.
///
/// Curved text places every grapheme on its own, and drawn as paragraphs
/// each one costs a save, translate, rotate, scale, paint and restore,
/// once for its halo and once for its fill. On a label-dense screen that
/// was thousands of canvas calls a frame, most of the label draw time on
/// the UI thread, and one text entity per glyph on the raster thread.
/// Here a glyph is rasterized once per style, grapheme and device size,
/// and every later frame only pays for its transform.
///
/// Pages are immutable `ui.Image`s. [reserve] hands out a cell and
/// queues its paint; [flush] re-records each page that gained cells,
/// copying the old image and adding the new glyphs, so a frame that
/// meets many new glyphs costs one snapshot per page, not one per glyph.
/// When every page is full the least recently used page is emptied and
/// reused, unless the current frame drew from it.
///
/// The pages come from `Picture.toImageSync` and are exposed to the
/// same revoked-context hazard as tile rasters after an iOS
/// backgrounding, so the layer [clear]s the atlas in its resume
/// recovery and does not let it rasterize while the app is away.
class GlyphAtlas {
  GlyphAtlas({this.pageSize = 1024, this.maxPages = 6});

  /// Edge length of a page, in device pixels.
  final int pageSize;

  /// Upper bound on resident pages; 4 MiB of GPU memory each at 1024².
  final int maxPages;

  /// Transparent margin around every cell, so bilinear sampling at the
  /// edge of one glyph never reads its neighbour.
  static const int _gap = 1;

  final _pages = <_AtlasPage>[];
  final _cells = <Object, GlyphAtlasCell>{};
  var _frame = 0;

  @visibleForTesting
  int get debugPageCount => _pages.length;

  @visibleForTesting
  int get debugCellCount => _cells.length;

  /// Starts a frame; pages read after this are pinned against eviction
  /// until the next call.
  void beginFrame() => _frame++;

  /// The cell for [key], or null when it was never reserved or its page
  /// has since been evicted. Marks the page as used this frame.
  GlyphAtlasCell? lookup(Object key) {
    final cell = _cells[key];
    if (cell != null) _pages[cell.page].lastUsed = _frame;
    return cell;
  }

  /// Allocates a [width]×[height] device-pixel cell for [key] and queues
  /// [paint] to draw into it at the next [flush], with the canvas origin
  /// at the cell's top-left. Returns null when the glyph is larger than a
  /// page, or every page is full and pinned by this frame.
  GlyphAtlasCell? reserve(
    Object key,
    int width,
    int height,
    void Function(Canvas canvas) paint,
  ) {
    final existing = lookup(key);
    if (existing != null) return existing;
    final w = width + 2 * _gap;
    final h = height + 2 * _gap;
    if (w > pageSize || h > pageSize) return null;
    for (var i = 0; i < _pages.length; i++) {
      final cell = _place(i, key, w, h, paint);
      if (cell != null) return cell;
    }
    if (_pages.length < maxPages) {
      _pages.add(_AtlasPage());
      return _place(_pages.length - 1, key, w, h, paint);
    }
    var victim = -1;
    for (var i = 0; i < _pages.length; i++) {
      final page = _pages[i];
      if (page.lastUsed == _frame) continue;
      if (victim < 0 || page.lastUsed < _pages[victim].lastUsed) victim = i;
    }
    if (victim < 0) return null;
    _evict(victim);
    return _place(victim, key, w, h, paint);
  }

  GlyphAtlasCell? _place(
    int index,
    Object key,
    int w,
    int h,
    void Function(Canvas canvas) paint,
  ) {
    final page = _pages[index];
    // Shelf packing: glyphs of one size have near-equal heights, so a
    // row per shelf wastes little and needs no search.
    if (page.x + w > pageSize) {
      page.y += page.rowHeight;
      page.x = 0;
      page.rowHeight = 0;
    }
    if (page.y + h > pageSize) return null;
    final rect = Rect.fromLTWH(
        (page.x + _gap).toDouble(),
        (page.y + _gap).toDouble(),
        (w - 2 * _gap).toDouble(),
        (h - 2 * _gap).toDouble());
    page.x += w;
    page.rowHeight = math.max(page.rowHeight, h);
    final cell = GlyphAtlasCell._(index, rect);
    page.keys.add(key);
    page.pending.add((rect.topLeft, paint));
    page.lastUsed = _frame;
    _cells[key] = cell;
    return cell;
  }

  void _evict(int index) {
    final page = _pages[index];
    for (final key in page.keys) {
      _cells.remove(key);
    }
    page.image?.dispose();
    _pages[index] = _AtlasPage();
  }

  /// Rasterizes every queued cell into its page.
  void flush() {
    for (final page in _pages) {
      if (page.pending.isEmpty) continue;
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      final old = page.image;
      if (old != null) canvas.drawImage(old, Offset.zero, Paint());
      for (final (origin, paint) in page.pending) {
        canvas.save();
        canvas.translate(origin.dx, origin.dy);
        paint(canvas);
        canvas.restore();
      }
      page.pending.clear();
      final picture = recorder.endRecording();
      // Only the used rows: a fresh page needs no full-size texture.
      final height = math.min(pageSize, page.y + page.rowHeight);
      page.image = picture.toImageSync(pageSize, height);
      picture.dispose();
      // Draw calls already recorded this frame hold their own reference
      // to the image they sampled.
      old?.dispose();
    }
  }

  /// The image backing [cell], or null when it has not been flushed.
  ui.Image? imageOf(GlyphAtlasCell cell) => _pages[cell.page].image;

  /// Drops every page, e.g. after the GPU context may have been revoked.
  void clear() {
    for (final page in _pages) {
      page.image?.dispose();
    }
    _pages.clear();
    _cells.clear();
  }
}

/// Where one glyph lives: a page index and its pixel rect on that page.
class GlyphAtlasCell {
  final int page;
  final Rect rect;

  const GlyphAtlasCell._(this.page, this.rect);
}

class _AtlasPage {
  ui.Image? image;
  var x = 0;
  var y = 0;
  var rowHeight = 0;
  var lastUsed = 0;
  final keys = <Object>[];
  final pending = <(Offset, void Function(Canvas))>[];
}
