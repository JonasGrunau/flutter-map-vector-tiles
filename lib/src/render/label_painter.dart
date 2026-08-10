import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:characters/characters.dart';
import 'package:flutter/painting.dart';

import '../cache/lru_cache.dart';
import '../style/expression.dart';
import '../style/sprite_atlas.dart';
import '../style/theme.dart';
import 'symbol_layouter.dart';

/// The affine transform from a display tile's logical coordinates to
/// screen pixels: uniform scale, rotation, translation. Lengths scale
/// by [scale]; angles shift by [rotation].
class TileTransform {
  final Offset origin;
  final double scale;
  final double rotation;
  final double _cosR;
  final double _sinR;

  TileTransform({
    required this.origin,
    required this.scale,
    required this.rotation,
  })  : _cosR = math.cos(rotation),
        _sinR = math.sin(rotation);

  Offset apply(Offset p) => Offset(
        origin.dx + (p.dx * _cosR - p.dy * _sinR) * scale,
        origin.dy + (p.dx * _sinR + p.dy * _cosR) * scale,
      );
}

/// A symbol candidate projected to screen coordinates.
class PlacedSymbol {
  final SymbolInstance instance;
  final Offset screenAnchor;

  /// Screen-space baseline angle for along-line labels (radians).
  final double screenAngle;

  /// Tile→screen transform, present for along-line symbols so curved
  /// text can project the line geometry.
  final TileTransform? transform;

  const PlacedSymbol({
    required this.instance,
    required this.screenAnchor,
    required this.screenAngle,
    this.transform,
  });
}

/// Draws all visible labels/icons in one screen-space pass per frame,
/// with global collision detection across tile borders. Text stays
/// crisp at fractional zoom and upright under rotation.
class LabelPainter {
  /// Cache capacities, sized to survive one dense-city screen of
  /// distinct labels: when the per-frame distinct-label count exceeds
  /// the cache, every frame evicts entries the same frame still needs
  /// and the whole screen re-lays-out every frame. The memory ceiling is
  /// only reached on screens that actually carry that many labels; if a
  /// byte budget is ever needed, `LruCache.maxCost` is the ready hook.
  static const int textCacheEntries = 2500;
  static const int glyphCacheEntries = 4000;

  /// Steps per zoom level for the label eval zoom. Labels are laid out
  /// in screen space, so between steps nothing visibly moves; typical
  /// `text-size` ramps drift ~0.1-0.2px per step — below the 0.1px
  /// rounding already applied in the text cache key.
  static const double _zoomStep = 8;

  late final _textCache = LruCache<String, _LaidOutText>(
      maxEntries: textCacheEntries,
      onEvict: (_, text) => _retired.add(text.dispose));
  late final _glyphCache = LruCache<String, _GlyphText>(
      maxEntries: glyphCacheEntries,
      onEvict: (_, glyph) => _retired.add(glyph.dispose));

  /// Evicted entries whose `TextPainter`s may still be referenced by
  /// symbols prepared earlier in the same frame — disposed at the start
  /// of the next [paint] instead of at eviction time.
  final _retired = <void Function()>[];

  void _disposeRetired() {
    for (final dispose in _retired) {
      dispose();
    }
    _retired.clear();
  }

  /// [styleZoom] is the fractional style zoom used for size expressions.
  ///
  /// Returns the symbols that survived collision and were drawn, in
  /// draw order — useful for tests and future hit-testing.
  /// [symbols] is sorted in place into placement-priority order; the
  /// caller rebuilds the list per frame, so a defensive copy here would
  /// only add allocation to the hottest per-frame path.
  /// [devicePixelRatio] only sharpens SDF icon edges; it does not scale
  /// anything, so 1 is a safe default.
  List<PlacedSymbol> paint({
    required Canvas canvas,
    required Size screenSize,
    required double styleZoom,
    required List<PlacedSymbol> symbols,
    SpriteAtlas? sprites,
    double devicePixelRatio = 1,
  }) {
    _disposeRetired();
    // Quantize the eval zoom to [_zoomStep] steps: the per-instance
    // memo, the zoom-only expression memos and the text/glyph cache
    // keys all compare against the exact zoom, so evaluating at the raw
    // fractional zoom would miss every one of them on every frame of a
    // pinch. Integer zooms are fixed points of the rounding.
    final zoom = (styleZoom * _zoomStep).round() / _zoomStep;
    final collision = _CollisionIndex(screenSize);
    // Placement priority: topmost style layers first (they win space),
    // then by symbol-sort-key, then stable by y for determinism.
    final candidates = symbols
      ..sort((a, b) {
        final byLayer = b.instance.layerIndex - a.instance.layerIndex;
        if (byLayer != 0) return byLayer;
        final bySortKey = a.instance.sortKey.compareTo(b.instance.sortKey);
        if (bySortKey != 0) return bySortKey;
        return a.screenAnchor.dy.compareTo(b.screenAnchor.dy);
      });

    final toDraw = <_DrawableSymbol>[];
    for (final candidate in candidates) {
      final drawable =
          _prepare(candidate, zoom, collision, sprites, screenSize);
      if (drawable != null) toDraw.add(drawable);
    }
    // Draw bottom style layers first so upper layers paint on top.
    toDraw.sort((a, b) =>
        a.symbol.instance.layerIndex.compareTo(b.symbol.instance.layerIndex));
    final drawn = <PlacedSymbol>[];
    for (final drawable in toDraw) {
      drawable.draw(canvas, devicePixelRatio);
      drawn.add(drawable.symbol);
    }
    return drawn;
  }

  _DrawableSymbol? _prepare(
    PlacedSymbol placed,
    double styleZoom,
    _CollisionIndex collision,
    SpriteAtlas? sprites,
    Size screenSize,
  ) {
    final instance = placed.instance;
    final layer = instance.layer;

    // Cull far off-screen anchors before any evaluation work.
    final anchor = placed.screenAnchor;
    if (anchor.dx < -150 ||
        anchor.dy < -150 ||
        anchor.dx > screenSize.width + 150 ||
        anchor.dy > screenSize.height + 150) {
      return null;
    }

    final ctx = EvalContext(
      zoom: styleZoom,
      properties: instance.properties,
      geometryType: instance.geometryType,
      featureId: instance.featureId,
    );

    // A label the style has faded out is skipped rather than laid out:
    // reserving collision space for invisible text would suppress the
    // visible labels around it.
    _LaidOutText? text;
    if (instance.text.isNotEmpty && layer.textOpacity.eval(ctx) > 0) {
      text = _layoutText(instance, layer, ctx);
    }

    _DrawableIcon? icon;
    final iconName = instance.iconName;
    if (iconName != null && sprites != null) {
      final sprite = sprites[iconName];
      if (sprite != null) {
        final iconSize = layer.iconSize.eval(ctx);
        final opacity = layer.iconOpacity.eval(ctx).clamp(0.0, 1.0);
        if (iconSize > 0 && opacity > 0) {
          final w = sprite.width / sprite.pixelRatio * iconSize;
          final h = sprite.height / sprite.pixelRatio * iconSize;
          final offset = layer.iconOffset.eval(ctx);
          final dx = offset.isNotEmpty ? offset[0] * iconSize : 0.0;
          final dy = offset.length > 1 ? offset[1] * iconSize : 0.0;
          final rect = _anchoredRect(
              layer.iconAnchor.eval(ctx), anchor + Offset(dx, dy), w, h);
          icon = _DrawableIcon(
            atlas: sprites,
            sprite: sprite,
            rect: rect,
            opacity: opacity,
            // Only SDF sheets are recolourable; ordinary sprites already
            // carry their own colours.
            tint: sprite.sdf ? layer.iconColor.eval(ctx) : null,
            haloColor: sprite.sdf ? layer.iconHaloColor.eval(ctx) : null,
            haloWidth: sprite.sdf ? layer.iconHaloWidth.eval(ctx) : 0,
            iconSize: iconSize,
          );
        }
      }
    }

    if (text == null && icon == null) return null;

    // Variable anchors: try each candidate until one fits.
    final variableAnchors = text != null && !instance.alongLine
        ? layer.textVariableAnchor?.eval(ctx)
        : null;
    if (text != null && variableAnchors != null && variableAnchors.isNotEmpty) {
      return _prepareVariableAnchor(
          placed, layer, ctx, text, icon, variableAnchors, collision);
    }

    // Along-line text follows the line glyph by glyph, unless the style
    // pins it to the viewport or the script needs shaping we can't
    // preserve per-glyph.
    var lineTextAngle = 0.0;
    if (text != null && instance.alongLine) {
      if (layer.textRotationAlignment.eval(ctx) != 'viewport') {
        if (instance.path != null &&
            placed.transform != null &&
            instance.curveSafe) {
          return _prepareCurved(placed, layer, ctx, text, icon, collision);
        }
        lineTextAngle = _uprightAngle(placed.screenAngle);
      }
    }

    // Compute collision boxes.
    final boxes = <Rect>[];
    var textRect = Rect.zero;
    var angle = 0.0;
    if (text != null) {
      final padding = layer.textPadding.eval(ctx);
      final offset = layer.textOffset.eval(ctx);
      final em = text.fontSize;
      final shifted = anchor +
          Offset(
            offset.isNotEmpty ? offset[0] * em : 0,
            offset.length > 1 ? offset[1] * em : 0,
          );
      textRect = _anchoredRect(layer.textAnchor.eval(ctx), shifted,
          text.size.width, text.size.height);
      if (instance.alongLine) {
        angle = lineTextAngle;
        // Along-line text is centered on the anchor.
        textRect = Rect.fromCenter(
            center: anchor, width: text.size.width, height: text.size.height);
        boxes.add(_rotatedBounds(textRect, anchor, angle).inflate(padding));
      } else {
        boxes.add(textRect.inflate(padding));
      }
    }
    if (icon != null) {
      boxes.add(icon.rect.inflate(2));
    }

    final allowOverlap = text != null
        ? layer.textAllowOverlap.eval(ctx)
        : layer.iconAllowOverlap.eval(ctx);
    if (!allowOverlap && !collision.tryPlaceAll(boxes)) {
      // Icon may still be placed when text is optional.
      if (icon != null &&
          text != null &&
          layer.textOptional.eval(ctx) &&
          collision.tryPlaceAll([icon.rect.inflate(2)])) {
        return _DrawableSymbol(placed, icon: icon);
      }
      return null;
    }

    return _DrawableSymbol(
      placed,
      icon: icon,
      text: text,
      textRect: textRect,
      textAngle: angle,
    );
  }

  /// `text-variable-anchor` placement: anchors are tried in style order;
  /// the first whose boxes fit the collision index wins. `text-offset`
  /// is ignored in this mode; `text-radial-offset` applies per anchor.
  _DrawableSymbol? _prepareVariableAnchor(
    PlacedSymbol placed,
    SymbolThemeLayer layer,
    EvalContext ctx,
    _LaidOutText text,
    _DrawableIcon? icon,
    List<String> anchors,
    _CollisionIndex collision,
  ) {
    final padding = layer.textPadding.eval(ctx);
    final radial = layer.textRadialOffset.eval(ctx) * text.fontSize;
    final allowOverlap = layer.textAllowOverlap.eval(ctx);
    for (final anchorName in anchors) {
      final shifted = placed.screenAnchor + _radialShift(anchorName, radial);
      final textRect =
          _anchoredRect(anchorName, shifted, text.size.width, text.size.height);
      final boxes = [
        textRect.inflate(padding),
        if (icon != null) icon.rect.inflate(2),
      ];
      if (allowOverlap || collision.tryPlaceAll(boxes)) {
        return _DrawableSymbol(placed,
            icon: icon, text: text, textRect: textRect);
      }
    }
    if (icon != null &&
        layer.textOptional.eval(ctx) &&
        collision.tryPlaceAll([icon.rect.inflate(2)])) {
      return _DrawableSymbol(placed, icon: icon);
    }
    return null;
  }

  /// Shift that moves the text box away from the anchor point by
  /// [r] pixels, in the direction implied by the anchor name.
  static Offset _radialShift(String anchorName, double r) {
    if (r == 0) return Offset.zero;
    const d = 0.7071067811865476; // 1/sqrt(2)
    return switch (anchorName) {
      'top' => Offset(0, r),
      'bottom' => Offset(0, -r),
      'left' => Offset(r, 0),
      'right' => Offset(-r, 0),
      'top-left' => Offset(r * d, r * d),
      'top-right' => Offset(-r * d, r * d),
      'bottom-left' => Offset(r * d, -r * d),
      'bottom-right' => Offset(-r * d, -r * d),
      _ => Offset.zero, // center
    };
  }

  /// Curved line text: each glyph cluster is placed and rotated
  /// individually along the projected line. Labels that don't fit their
  /// line or bend sharper than `text-max-angle` are not placed, matching
  /// MapLibre.
  _DrawableSymbol? _prepareCurved(
    PlacedSymbol placed,
    SymbolThemeLayer layer,
    EvalContext ctx,
    _LaidOutText text,
    _DrawableIcon? icon,
    _CollisionIndex collision,
  ) {
    final instance = placed.instance;
    final path = instance.path!;
    final transform = placed.transform!;
    final clusters = text.clusters;
    if (clusters.isEmpty) return null;

    _DrawableSymbol? iconFallback() {
      if (icon != null &&
          layer.textOptional.eval(ctx) &&
          collision.tryPlaceAll([icon.rect.inflate(2)])) {
        return _DrawableSymbol(placed, icon: icon);
      }
      return null;
    }

    // The label occupies [d0, d1] along the path, in logical units.
    final scale = transform.scale;
    final halfW = text.size.width / 2 / scale;
    final d0 = instance.pathDistance - halfW;
    final d1 = instance.pathDistance + halfW;
    if (d0 < 0 || d1 > path.length) return iconFallback();

    // Reading direction: walk the path backwards when the label would
    // come out upside-down on screen.
    final s0 = transform.apply(path.pointAt(d0));
    final s1 = transform.apply(path.pointAt(d1));
    final reversed = layer.textKeepUpright.eval(ctx) && s1.dx < s0.dx;

    final offset = layer.textOffset.eval(ctx);
    final perp = offset.length > 1 ? offset[1] * text.fontSize : 0.0;
    final maxAngle = layer.textMaxAngle.eval(ctx) * math.pi / 180;

    final placements =
        <({String grapheme, Offset pos, double angle, double width})>[];
    var previousAngle = double.nan;
    var maxDeviation = 0.0;
    double? firstAngle;
    for (final cluster in clusters) {
      final d =
          reversed ? d1 - cluster.center / scale : d0 + cluster.center / scale;
      var angle = path.angleAt(d) + transform.rotation;
      if (reversed) angle += math.pi;
      angle = _foldAngle(angle);
      if (!previousAngle.isNaN &&
          _foldAngle(angle - previousAngle).abs() > maxAngle) {
        return iconFallback(); // line bends too sharply for this label
      }
      previousAngle = angle;
      firstAngle ??= angle;
      maxDeviation =
          math.max(maxDeviation, _foldAngle(angle - firstAngle).abs());
      var pos = transform.apply(path.pointAt(d));
      if (perp != 0) {
        pos += Offset(-math.sin(angle), math.cos(angle)) * perp;
      }
      placements.add((
        grapheme: cluster.grapheme,
        pos: pos,
        angle: angle,
        width: cluster.width,
      ));
    }
    if (placements.isEmpty) return null;

    final padding = layer.textPadding.eval(ctx);
    final allowOverlap = layer.textAllowOverlap.eval(ctx);

    // The window under the label is essentially straight: draw it as a
    // single rotated string, which is much cheaper.
    if (maxDeviation < 0.02 && perp == 0) {
      final angle = _uprightAngle(placed.screenAngle);
      final textRect = Rect.fromCenter(
          center: placed.screenAnchor,
          width: text.size.width,
          height: text.size.height);
      final boxes = [
        _rotatedBounds(textRect, placed.screenAnchor, angle).inflate(padding),
        if (icon != null) icon.rect.inflate(2),
      ];
      if (!allowOverlap && !collision.tryPlaceAll(boxes)) {
        return iconFallback();
      }
      return _DrawableSymbol(placed,
          icon: icon, text: text, textRect: textRect, textAngle: angle);
    }

    // Per-glyph collision boxes.
    final glyphHeight = text.fontSize * 1.2;
    final boxes = <Rect>[
      for (final p in placements)
        _rotatedBounds(
                Rect.fromCenter(
                    center: p.pos, width: p.width, height: glyphHeight),
                p.pos,
                p.angle)
            .inflate(padding),
      if (icon != null) icon.rect.inflate(2),
    ];
    if (!allowOverlap && !collision.tryPlaceAll(boxes)) {
      return iconFallback();
    }

    final glyphs = [
      for (final p in placements)
        _CurvedGlyph(
          painters: _glyphPainters(p.grapheme, text),
          position: p.pos,
          angle: p.angle,
        ),
    ];
    return _DrawableSymbol(placed, icon: icon, curvedGlyphs: glyphs);
  }

  /// Folds an angle into (-π, π].
  static double _foldAngle(double angle) {
    var a = angle;
    while (a <= -math.pi) {
      a += 2 * math.pi;
    }
    while (a > math.pi) {
      a -= 2 * math.pi;
    }
    return a;
  }

  _LaidOutText _layoutText(
    SymbolInstance instance,
    SymbolThemeLayer layer,
    EvalContext ctx,
  ) {
    // The ~8 style evaluations below depend only on (zoom, feature) —
    // both fixed for a given instance while the zoom is unchanged — so
    // the computed cache key is memoized on the instance. Only the key:
    // the laid-out text itself belongs to the LRU, which may evict and
    // dispose it.
    final memoKey = instance.textCacheKey;
    if (memoKey != null && instance.textCacheZoom == ctx.zoom) {
      final memoized = _textCache.get(memoKey);
      if (memoized != null) return memoized;
    }

    final fontSize = layer.textSize.eval(ctx).clamp(4.0, 96.0);
    // `text-opacity` is folded into the colours, so it lands in the
    // cache key below along with them.
    final opacity = layer.textOpacity.eval(ctx).clamp(0.0, 1.0);
    final color = _withOpacity(layer.textColor.eval(ctx), opacity);
    final haloColor = _withOpacity(layer.textHaloColor.eval(ctx), opacity);
    final haloWidth = layer.textHaloWidth.eval(ctx).clamp(0.0, 8.0);
    final fonts = layer.textFont.eval(ctx);
    final letterSpacingEm = layer.textLetterSpacing.eval(ctx);
    final maxWidthEm = layer.textMaxWidth.eval(ctx);
    // Along-line labels never wrap.
    final singleLine = instance.alongLine;

    final styleKey = '${fontSize.toStringAsFixed(1)}|'
        '${color.toARGB32()}|${haloColor.toARGB32()}|$haloWidth|'
        '${fonts.join(',')}|$letterSpacingEm';
    final cacheKey = '${instance.text}|$styleKey|$maxWidthEm|$singleLine';
    instance.textCacheKey = cacheKey;
    instance.textCacheZoom = ctx.zoom;
    final cached = _textCache.get(cacheKey);
    if (cached != null) return cached;

    final maxLines = singleLine ? 1 : 4;
    final maxWidth = singleLine
        ? double.infinity
        : math.max(fontSize * maxWidthEm, fontSize * 2);
    final style = _textStyle(fonts, fontSize, letterSpacingEm, color);
    final fill = TextPainter(
      text: TextSpan(text: instance.text, style: style),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
      maxLines: maxLines,
    )..layout(maxWidth: maxWidth);

    TextPainter? halo;
    TextStyle? haloStyle;
    if (haloWidth > 0 && haloColor.a > 0) {
      haloStyle = style.copyWith(
        foreground: Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = haloWidth * 2
          ..strokeJoin = StrokeJoin.round
          ..color = haloColor,
      );
      halo = TextPainter(
        text: TextSpan(text: instance.text, style: haloStyle),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center,
        maxLines: maxLines,
      )..layout(maxWidth: maxWidth);
    }

    final laidOut = _LaidOutText(
      text: instance.text,
      fill: fill,
      halo: halo,
      size: fill.size,
      fontSize: fontSize,
      styleKey: styleKey,
      fillStyle: style,
      haloStyle: haloStyle,
    );
    _textCache.put(cacheKey, laidOut);
    return laidOut;
  }

  /// Painters for a single glyph cluster, cached across labels — the
  /// same characters repeat constantly in map text.
  _GlyphText _glyphPainters(String grapheme, _LaidOutText text) {
    final key = '${text.styleKey}#$grapheme';
    final cached = _glyphCache.get(key);
    if (cached != null) return cached;

    final fill = TextPainter(
      text: TextSpan(text: grapheme, style: text.fillStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    TextPainter? halo;
    if (text.haloStyle != null) {
      halo = TextPainter(
        text: TextSpan(text: grapheme, style: text.haloStyle),
        textDirection: TextDirection.ltr,
      )..layout();
    }
    final glyph = _GlyphText(fill: fill, halo: halo);
    _glyphCache.put(key, glyph);
    return glyph;
  }

  static TextStyle _textStyle(
    List<String> fonts,
    double fontSize,
    double letterSpacingEm,
    ui.Color color,
  ) {
    final joined = fonts.join(' ').toLowerCase();
    var weight = FontWeight.w400;
    if (joined.contains('extrabold') || joined.contains('extra bold')) {
      weight = FontWeight.w800;
    } else if (joined.contains('semibold') || joined.contains('semi bold')) {
      weight = FontWeight.w600;
    } else if (joined.contains('bold')) {
      weight = FontWeight.w700;
    } else if (joined.contains('medium')) {
      weight = FontWeight.w500;
    } else if (joined.contains('light')) {
      weight = FontWeight.w300;
    } else if (joined.contains('thin')) {
      weight = FontWeight.w200;
    }
    return TextStyle(
      fontSize: fontSize,
      fontWeight: weight,
      fontStyle:
          joined.contains('italic') ? FontStyle.italic : FontStyle.normal,
      letterSpacing: letterSpacingEm == 0 ? null : letterSpacingEm * fontSize,
      color: color,
      height: 1.15,
    );
  }

  /// Positions a box of [width]x[height] relative to [anchor] per the
  /// MapLibre anchor semantics ("top" = box hangs below the anchor).
  static Rect _anchoredRect(
      String anchorName, Offset anchor, double width, double height) {
    final dx = switch (anchorName) {
      'left' || 'top-left' || 'bottom-left' => 0.0,
      'right' || 'top-right' || 'bottom-right' => -width,
      _ => -width / 2,
    };
    final dy = switch (anchorName) {
      'top' || 'top-left' || 'top-right' => 0.0,
      'bottom' || 'bottom-left' || 'bottom-right' => -height,
      _ => -height / 2,
    };
    return Rect.fromLTWH(anchor.dx + dx, anchor.dy + dy, width, height);
  }

  /// Keeps along-line text upright: angles are folded into
  /// (-π/2, π/2].
  static double _uprightAngle(double angle) {
    var a = _foldAngle(angle);
    if (a > math.pi / 2) a -= math.pi;
    if (a <= -math.pi / 2) a += math.pi;
    return a;
  }

  static Color _withOpacity(Color color, double opacity) =>
      opacity >= 1 ? color : color.withValues(alpha: color.a * opacity);

  static Rect _rotatedBounds(Rect rect, Offset pivot, double angle) {
    final cosA = math.cos(angle).abs();
    final sinA = math.sin(angle).abs();
    final w = rect.width * cosA + rect.height * sinA;
    final h = rect.width * sinA + rect.height * cosA;
    return Rect.fromCenter(center: rect.center, width: w, height: h);
  }

  void dispose() {
    _textCache.clear();
    _glyphCache.clear();
    _disposeRetired();
  }
}

class _LaidOutText {
  final String text;
  final TextPainter fill;
  final TextPainter? halo;
  final Size size;
  final double fontSize;
  final String styleKey;
  final TextStyle fillStyle;
  final TextStyle? haloStyle;

  List<_Cluster>? _clusters;

  _LaidOutText({
    required this.text,
    required this.fill,
    required this.halo,
    required this.size,
    required this.fontSize,
    required this.styleKey,
    required this.fillStyle,
    required this.haloStyle,
  });

  /// Grapheme clusters with their advance-centre x positions in the
  /// laid-out string — spacing and kerning come from the full layout,
  /// so curved glyphs keep the string's metrics. Whitespace clusters
  /// are omitted (their advance still separates the neighbours).
  List<_Cluster> get clusters => _clusters ??= _computeClusters();

  void dispose() {
    fill.dispose();
    halo?.dispose();
  }

  List<_Cluster> _computeClusters() {
    final result = <_Cluster>[];
    var start = 0;
    for (final grapheme in text.characters) {
      final end = start + grapheme.length;
      if (grapheme.trim().isNotEmpty) {
        final boxes = fill.getBoxesForSelection(
            TextSelection(baseOffset: start, extentOffset: end));
        if (boxes.isNotEmpty) {
          var left = double.infinity;
          var right = -double.infinity;
          for (final box in boxes) {
            left = math.min(left, box.left);
            right = math.max(right, box.right);
          }
          result.add(_Cluster(grapheme, (left + right) / 2, right - left));
        }
      }
      start = end;
    }
    return result;
  }
}

class _Cluster {
  final String grapheme;

  /// Centre of the cluster's advance, from the string's left edge.
  final double center;
  final double width;

  const _Cluster(this.grapheme, this.center, this.width);
}

class _GlyphText {
  final TextPainter fill;
  final TextPainter? halo;

  const _GlyphText({required this.fill, required this.halo});

  void dispose() {
    fill.dispose();
    halo?.dispose();
  }
}

class _CurvedGlyph {
  final _GlyphText painters;
  final Offset position;
  final double angle;

  const _CurvedGlyph({
    required this.painters,
    required this.position,
    required this.angle,
  });
}

class _DrawableIcon {
  /// MapLibre's `symbol_sdf` encoding: the alpha channel ramps across 8
  /// atlas texels and the shape's edge sits at 6/8 of the range. A halo
  /// of width `w` (in `icon-size` units) simply moves the cutoff `w`
  /// texels further out.
  static const double _sdfTexels = 8;
  static const double _sdfEdge = 6 / _sdfTexels;

  final SpriteAtlas atlas;
  final Sprite sprite;
  final Rect rect;
  final double opacity;

  /// `icon-color`, for SDF sprites only; null draws the sprite as-is.
  final Color? tint;
  final Color? haloColor;
  final double haloWidth;

  /// `icon-size`, which `icon-halo-width` is measured relative to.
  final double iconSize;

  const _DrawableIcon({
    required this.atlas,
    required this.sprite,
    required this.rect,
    required this.opacity,
    this.tint,
    this.haloColor,
    this.haloWidth = 0,
    this.iconSize = 1,
  });

  void draw(Canvas canvas, double devicePixelRatio) {
    final color = tint;
    if (color == null) {
      canvas.drawImageRect(
        atlas.image,
        sprite.sourceRect,
        rect,
        Paint()
          ..filterQuality = FilterQuality.medium
          ..color = Color.fromRGBO(255, 255, 255, opacity),
      );
      return;
    }
    final halo = haloColor;
    if (halo != null && halo.a > 0 && haloWidth > 0) {
      canvas.drawImageRect(
        atlas.image,
        sprite.sourceRect,
        rect,
        _sdfPaint(
          halo,
          ((6 - haloWidth / iconSize) / _sdfTexels).clamp(0.0, _sdfEdge),
          devicePixelRatio,
        ),
      );
    }
    canvas.drawImageRect(atlas.image, sprite.sourceRect, rect,
        _sdfPaint(color, _sdfEdge, devicePixelRatio));
  }

  /// Thresholds the distance field at [edge] and tints what survives
  /// with [color]. A colour matrix is applied *after* texture sampling,
  /// so the threshold lands on interpolated distances and the edge stays
  /// crisp at any scale — the same reason MapLibre does this in a
  /// fragment shader. The ramp is steepened to span roughly one device
  /// pixel at the size this icon is drawn, which is what antialiases it.
  Paint _sdfPaint(Color color, double edge, double devicePixelRatio) {
    final drawnPerTexel = rect.width * devicePixelRatio / sprite.width;
    final slope = (_sdfTexels * drawnPerTexel).clamp(4.0, 128.0);
    final shift = 0.5 - edge * slope;
    return Paint()
      // Bilinear only: mipmaps blur the field, which erodes the shape.
      ..filterQuality = FilterQuality.low
      ..color =
          Color.fromRGBO(255, 255, 255, (opacity * color.a).clamp(0.0, 1.0))
      ..colorFilter = ColorFilter.matrix(<double>[
        0, 0, 0, 0, color.r * 255, //
        0, 0, 0, 0, color.g * 255, //
        0, 0, 0, 0, color.b * 255, //
        0, 0, 0, slope, shift * 255, //
      ]);
  }
}

class _DrawableSymbol {
  final PlacedSymbol symbol;
  final _DrawableIcon? icon;
  final _LaidOutText? text;
  final Rect textRect;
  final double textAngle;
  final List<_CurvedGlyph>? curvedGlyphs;

  const _DrawableSymbol(
    this.symbol, {
    this.icon,
    this.text,
    this.textRect = Rect.zero,
    this.textAngle = 0,
    this.curvedGlyphs,
  });

  void draw(Canvas canvas, double devicePixelRatio) {
    icon?.draw(canvas, devicePixelRatio);
    final glyphs = curvedGlyphs;
    if (glyphs != null) {
      // All halos first: a glyph's halo must never cut into its
      // neighbour's fill.
      for (var pass = 0; pass < 2; pass++) {
        for (final glyph in glyphs) {
          final painter = pass == 0 ? glyph.painters.halo : glyph.painters.fill;
          if (painter == null) continue;
          canvas.save();
          canvas.translate(glyph.position.dx, glyph.position.dy);
          canvas.rotate(glyph.angle);
          painter.paint(
              canvas, Offset(-painter.width / 2, -painter.height / 2));
          canvas.restore();
        }
      }
      return;
    }
    final t = text;
    if (t == null) return;
    if (textAngle != 0) {
      canvas.save();
      canvas.translate(symbol.screenAnchor.dx, symbol.screenAnchor.dy);
      canvas.rotate(textAngle);
      final topLeft = Offset(-t.size.width / 2, -t.size.height / 2);
      t.halo?.paint(canvas, topLeft);
      t.fill.paint(canvas, topLeft);
      canvas.restore();
    } else {
      t.halo?.paint(canvas, textRect.topLeft);
      t.fill.paint(canvas, textRect.topLeft);
    }
  }
}

/// Grid-bucketed screen-space collision index.
class _CollisionIndex {
  static const double _cellSize = 128;
  final Map<int, List<Rect>> _cells = {};
  final int _columns;

  _CollisionIndex(Size screenSize)
      : _columns = math.max(1, (screenSize.width / _cellSize).ceil() + 4);

  bool tryPlaceAll(List<Rect> rects) {
    for (final rect in rects) {
      if (_collides(rect)) return false;
    }
    for (final rect in rects) {
      _insert(rect);
    }
    return true;
  }

  // The cell walks are inlined in both callers: a sync* generator here
  // allocated an iterator per collision box per frame in the hottest
  // label loop.

  bool _collides(Rect rect) {
    final minX = ((rect.left + 512) / _cellSize).floor();
    final maxX = ((rect.right + 512) / _cellSize).floor();
    final minY = ((rect.top + 512) / _cellSize).floor();
    final maxY = ((rect.bottom + 512) / _cellSize).floor();
    for (var y = minY; y <= maxY; y++) {
      for (var x = minX; x <= maxX; x++) {
        final rects = _cells[y * _columns + x];
        if (rects == null) continue;
        for (final other in rects) {
          if (rect.overlaps(other)) return true;
        }
      }
    }
    return false;
  }

  void _insert(Rect rect) {
    final minX = ((rect.left + 512) / _cellSize).floor();
    final maxX = ((rect.right + 512) / _cellSize).floor();
    final minY = ((rect.top + 512) / _cellSize).floor();
    final maxY = ((rect.bottom + 512) / _cellSize).floor();
    for (var y = minY; y <= maxY; y++) {
      for (var x = minX; x <= maxX; x++) {
        (_cells[y * _columns + x] ??= []).add(rect);
      }
    }
  }
}
