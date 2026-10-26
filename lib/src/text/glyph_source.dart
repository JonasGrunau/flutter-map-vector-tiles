import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import '../core/redact.dart';
import '../logger.dart';
import 'glyph_pbf.dart';

/// Loads the glyph PBF holding code points [start] to `start + 255` of
/// [fontstack] — the font names of a `text-font` value joined by
/// commas, as MapLibre requests them.
typedef GlyphRangeLoader = Future<Uint8List> Function(
    String fontstack, int start);

/// A style's `glyphs`: the font the style was designed with, served as
/// signed-distance-field glyph PBFs in ranges of 256 code points
/// (`{fontstack}/{range}.pbf`), which is what MapLibre draws labels from.
///
/// Pass it to `VectorTileLayer.glyphs` — `StyleReader` builds one for
/// every style that declares `glyphs` (as `Style.glyphs`) — and labels
/// whose text needs no complex shaping are drawn from these glyphs in
/// the style's own fonts. Everything else (right-to-left and Indic
/// scripts, CJK, emoji, combining marks, a font stack the server does
/// not have) keeps the platform's text renderer and system fonts.
///
/// Ranges load on first use, about 75–130 KB each for the Latin ones,
/// and a tile's labels wait for the ranges they need rather than switch
/// fonts once they arrive. A range that fails to load is not retried
/// for the life of this object; its labels use the platform renderer.
///
/// Owns GPU textures (one per loaded range): call [dispose] once no
/// layer uses it any more — `Style.dispose` does for the one it built.
class GlyphSource {
  /// A glyph source reading ranges through [load] — from assets, a
  /// local archive or a custom endpoint. [signature] identifies the
  /// glyphs' content for caches that outlive a map (finished tiles with
  /// their labels drawn in): two sources with one signature must draw
  /// identical glyphs.
  ///
  /// [onDispose] runs when this source is disposed — to close a client
  /// [load] uses, say.
  GlyphSource({
    required GlyphRangeLoader load,
    required this.signature,
    Logger logger = const Logger.noop(),
    void Function()? onDispose,
  })  : _load = load,
        _logger = logger,
        _onDispose = onDispose;

  /// A glyph source fetching `urlTemplate` with `{fontstack}` and
  /// `{range}` substituted (`https://…/fonts/{fontstack}/{range}.pbf`),
  /// without a disk cache. `StyleReader` adds one for the glyphs of the
  /// styles it reads, so they are there offline.
  ///
  /// [httpClient] is used as given and not closed; without one the
  /// source makes its own and closes it on [dispose].
  factory GlyphSource.network(
    String urlTemplate, {
    Map<String, String> headers = const {},
    http.Client? httpClient,
    Logger logger = const Logger.noop(),
  }) {
    final client = httpClient ?? http.Client();
    return GlyphSource(
      load: (fontstack, start) async {
        final url = glyphRangeUrl(urlTemplate, fontstack, start);
        final response = await client.get(Uri.parse(url), headers: headers);
        if (response.statusCode != 200) {
          throw http.ClientException(
              'HTTP ${response.statusCode} for ${redactKeys(url)}');
        }
        return response.bodyBytes;
      },
      signature: urlTemplate,
      logger: logger,
      onDispose: httpClient == null ? client.close : null,
    );
  }

  /// [urlTemplate] for one range: the font stack URL-encoded except for
  /// its commas, which glyph servers split stacks at.
  static String glyphRangeUrl(
          String urlTemplate, String fontstack, int start) =>
      urlTemplate
          .replaceAll('{fontstack}',
              Uri.encodeComponent(fontstack).replaceAll('%2C', ','))
          .replaceAll('{range}', '$start-${start + 255}');

  /// Identifies the glyphs' content, for cache keys.
  final String signature;

  final GlyphRangeLoader _load;
  final Logger _logger;
  final void Function()? _onDispose;
  final _ranges = <(String, int), _Range>{};
  var _disposed = false;

  /// The loaded range of [fontstack] starting at [start], or null while
  /// it is loading, after it failed, or before anyone asked for it.
  @internal
  GlyphRange? rangeOf(String fontstack, int start) =>
      _ranges[(fontstack, start)]?.ready;

  /// Whether [fontstack]'s range at [start] has been asked for and is
  /// still on its way.
  @internal
  bool isLoading(String fontstack, int start) {
    final range = _ranges[(fontstack, start)];
    return range != null && !range.settled;
  }

  /// Starts loading every range in [ranges] not asked for before, and
  /// returns a future that completes once all of them have either
  /// loaded or failed — or null when they all already have. Never
  /// completes with an error.
  @internal
  Future<void>? ensure(Iterable<(String, int)> ranges) {
    List<Future<void>>? pending;
    for (final key in ranges) {
      final range = _ranges[key] ??= _start(key.$1, key.$2);
      if (!range.settled) (pending ??= []).add(range.done.future);
    }
    if (pending == null) return null;
    return pending.length == 1 ? pending.first : Future.wait(pending);
  }

  _Range _start(String fontstack, int start) {
    final range = _Range();
    if (_disposed) {
      range.settle(null);
      return range;
    }
    unawaited(() async {
      try {
        final glyphs = decodeGlyphPbf(await _load(fontstack, start));
        final loaded = await GlyphRange._build(glyphs);
        if (_disposed) {
          loaded?.dispose();
          range.settle(null);
        } else {
          range.settle(loaded);
        }
      } catch (e) {
        _logger.warn('glyphs "$fontstack" $start-${start + 255} '
            'unavailable, drawn with system fonts: $e');
        range.settle(null);
      }
    }());
    return range;
  }

  /// Releases every loaded range's texture. Labels already shaped from
  /// them must not be drawn afterwards.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final range in _ranges.values) {
      range.ready?.dispose();
    }
    _ranges.clear();
    _onDispose?.call();
  }
}

class _Range {
  final done = Completer<void>();
  GlyphRange? ready;
  bool settled = false;

  void settle(GlyphRange? range) {
    ready = range;
    settled = true;
    done.complete();
  }
}

/// One loaded glyph range: its glyphs, and their distance fields packed
/// onto one GPU texture (alpha = distance; colour irrelevant).
@internal
class GlyphRange {
  final Map<int, SdfGlyph> glyphs;
  final ui.Image page;

  GlyphRange._(this.glyphs, this.page);

  /// Packs [glyphs]' bitmaps onto one page and uploads it. Null when no
  /// glyph has a bitmap (a range of spaces).
  static Future<GlyphRange?> _build(Map<int, SdfGlyph> glyphs) async {
    final drawn = [
      for (final glyph in glyphs.values)
        if (glyph.hasBitmap) glyph
    ]..sort((a, b) => b.bitmapHeight - a.bitmapHeight);
    if (drawn.isEmpty) {
      // Nothing to upload, but the metrics (advances) still serve.
      final empty = await _upload(Uint8List(4), 1, 1);
      return GlyphRange._(glyphs, empty);
    }
    // Shelf packing, tallest first; a 1 px gap keeps bilinear sampling
    // of one glyph from reading its neighbour.
    const gap = 1;
    final area = drawn.fold<int>(
        0, (sum, g) => sum + (g.bitmapWidth + gap) * (g.bitmapHeight + gap));
    final width =
        math.max(64, math.min(2048, _nextPowerOfTwo(math.sqrt(area))));
    var x = 0, y = 0, rowHeight = 0;
    for (final glyph in drawn) {
      if (x + glyph.bitmapWidth > width) {
        x = 0;
        y += rowHeight + gap;
        rowHeight = 0;
      }
      glyph
        ..pageX = x
        ..pageY = y;
      x += glyph.bitmapWidth + gap;
      rowHeight = math.max(rowHeight, glyph.bitmapHeight);
    }
    final height = y + rowHeight;
    final rgba = Uint8List(width * height * 4);
    for (final glyph in drawn) {
      final bitmap = glyph.bitmap!;
      final w = glyph.bitmapWidth;
      for (var row = 0; row < glyph.bitmapHeight; row++) {
        var o = ((glyph.pageY + row) * width + glyph.pageX) * 4;
        var i = row * w;
        for (var col = 0; col < w; col++) {
          // Premultiplied white: every channel the distance. Only alpha
          // is read, through a colour matrix, but this keeps the pixels
          // valid whichever way the engine takes them.
          final d = bitmap[i++];
          rgba[o] = d;
          rgba[o + 1] = d;
          rgba[o + 2] = d;
          rgba[o + 3] = d;
          o += 4;
        }
      }
    }
    return GlyphRange._(glyphs, await _upload(rgba, width, height));
  }

  static int _nextPowerOfTwo(double v) {
    var p = 1;
    while (p < v) {
      p *= 2;
    }
    return p;
  }

  static Future<ui.Image> _upload(Uint8List rgba, int width, int height) {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
        rgba, width, height, ui.PixelFormat.rgba8888, completer.complete);
    return completer.future;
  }

  void dispose() => page.dispose();
}
