import 'dart:developer' as developer;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:characters/characters.dart';
import 'package:flutter/painting.dart';
import 'package:meta/meta.dart';

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

  /// Fade-in opacity of the symbol's cohort (its tile's label fade),
  /// quantized by the caller so symbols group into few draw buckets.
  /// 1 in steady state. Fading symbols reserve collision space at full
  /// size — placements never shift when a fade completes.
  final double fadeOpacity;

  /// Insertion index within the frame's symbol list, the final
  /// placement tiebreaker: the caller adds current-level tiles before
  /// retained previous-level ones, so on an exact tie the current
  /// level's copy wins deterministically (`List.sort` is not stable).
  final int order;

  /// A label on its way out — the arriving zoom level has no counterpart
  /// for it, so it is fading rather than being placed. Ghosts are tested
  /// against the collision index but never inserted into it: a dying
  /// label must not block or displace a live one. If its space is
  /// already taken it is simply dropped, which costs nothing — it was
  /// leaving anyway.
  final bool ghost;

  const PlacedSymbol({
    required this.instance,
    required this.screenAnchor,
    required this.screenAngle,
    this.transform,
    this.fadeOpacity = 1,
    this.order = 0,
    this.ghost = false,
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

  /// Steps per zoom level for the label eval zoom. Between steps every
  /// per-instance memo and zoom-only expression memo hits, so a pinch
  /// frame costs no evaluation at all; at a step the evaluated sizes
  /// drift by ~0.1-0.2px for typical `text-size` ramps — invisible, and
  /// since text is shaped at [_shapeSize] and drawn scaled, a step never
  /// re-shapes anything either.
  static const double _zoomStep = 8;

  /// Reference font size all text is shaped at. Drawing applies
  /// `evaluated size / _shapeSize` through the canvas transform, so one
  /// shaped paragraph serves every zoom: layout inputs are em-based
  /// (`letterSpacing`, `maxWidth` scale with the font size) and glyphs
  /// rasterize at device scale under the transform, so scaled text is
  /// pixel-equivalent to re-shaping at the evaluated size — the "crisp
  /// at fractional zoom" contract holds.
  static const double _shapeSize = 16.0;

  /// Evaluated text below this size is skipped like the icon path's
  /// `iconSize > 0` guard, instead of being clamped up to a visible
  /// floor: a style that shrinks labels toward zero must not flood the
  /// collision grid with tiny-but-visible text.
  static const double _minVisibleTextSize = 1.0;

  /// Slack added to a fade layer's bounds, covering halo strokes and the
  /// widest text halo a style is likely to ask for.
  static const double _fadeLayerPadding = 16.0;

  /// Draw opacities are quantized to this many steps so translucent
  /// symbols group into a handful of `saveLayer` buckets instead of one
  /// per label.
  static const double _opacitySteps = 8;

  /// Width, in style zoom levels, of the ramp that fades a symbol out
  /// approaching a declared edge of its layer's zoom range.
  static const double _zoomFadeWindow = 0.25;

  /// Paragraph shapings performed (cache misses); for tests asserting
  /// that zoom motion does not re-shape text.
  @visibleForTesting
  int debugShapedTextCount = 0;

  @visibleForTesting
  int get debugTextCacheLength => _textCache.length;

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
    developer.Timeline.startSync('VT labels');
    try {
      return _paint(
          canvas, screenSize, styleZoom, symbols, sprites, devicePixelRatio);
    } finally {
      developer.Timeline.finishSync();
    }
  }

  List<PlacedSymbol> _paint(
    Canvas canvas,
    Size screenSize,
    double styleZoom,
    List<PlacedSymbol> symbols,
    SpriteAtlas? sprites,
    double devicePixelRatio,
  ) {
    _disposeRetired();
    // Quantize the eval zoom to [_zoomStep] steps: the per-instance
    // memo and the zoom-only expression memos compare against the exact
    // zoom, so evaluating at the raw fractional zoom would miss every
    // one of them on every frame of a pinch. Integer zooms are fixed
    // points of the rounding.
    final zoom = (styleZoom * _zoomStep).round() / _zoomStep;
    final collision = _CollisionIndex(screenSize);
    // Placement priority: topmost style layers first (they win space),
    // then by symbol-sort-key, then by y, then by insertion order — the
    // last term keeps the non-stable sort deterministic and lets
    // current-level tiles beat retained ones on exact ties.
    final candidates = symbols
      ..sort((a, b) {
        // Labels on their way out place last, whatever layer they are
        // on: a ghost reserves nothing, so testing it against the
        // finished live layout is what stops it drawing over the label
        // that is taking its place. Live always beats dying.
        if (a.ghost != b.ghost) return a.ghost ? 1 : -1;
        final byLayer = b.instance.layerIndex - a.instance.layerIndex;
        if (byLayer != 0) return byLayer;
        final bySortKey = a.instance.sortKey.compareTo(b.instance.sortKey);
        if (bySortKey != 0) return bySortKey;
        final byY = a.screenAnchor.dy.compareTo(b.screenAnchor.dy);
        if (byY != 0) return byY;
        return a.order - b.order;
      });

    final toDraw = <_DrawableSymbol>[];
    var anyFading = false;
    for (final candidate in candidates) {
      final drawable =
          _prepare(candidate, zoom, styleZoom, collision, sprites, screenSize);
      if (drawable != null) {
        // The cohort's fade-in and the layer's zoom-range ramp compound:
        // a tile that just published its labels near a layer's maxzoom
        // is subject to both.
        final ramp = zoomRangeOpacity(candidate.instance.layer, styleZoom);
        drawable.opacity =
            ramp <= 0 ? 0 : _quantizeOpacity(candidate.fadeOpacity * ramp);
        toDraw.add(drawable);
        anyFading |= drawable.opacity < 1;
      }
    }
    // Draw bottom style layers first so upper layers paint on top; the
    // insertion-order tiebreaker keeps draw order stable across frames.
    toDraw.sort((a, b) {
      final byLayer =
          a.symbol.instance.layerIndex.compareTo(b.symbol.instance.layerIndex);
      if (byLayer != 0) return byLayer;
      return a.symbol.order - b.symbol.order;
    });
    final drawn = <PlacedSymbol>[];
    if (!anyFading) {
      for (final drawable in toDraw) {
        drawable.draw(canvas, devicePixelRatio);
        drawn.add(drawable.symbol);
      }
      return drawn;
    }

    // Fading cohorts draw through one translucent layer per opacity
    // bucket instead of re-shaping text at each fade step: colours are
    // baked into the paragraphs, so per-label opacity would rotate the
    // text cache, while a saveLayer per bucket costs one render pass
    // for the few frames a fade is in flight. The caller quantizes
    // [PlacedSymbol.fadeOpacity], so the bucket count stays small.
    // Opaque symbols first (in layer order), fading cohorts on top.
    // A symbol the zoom ramp has retired keeps the collision space it
    // reserved in [_prepare] — placements stay put across the last step
    // of the ramp — but paints nothing.
    for (final drawable in toDraw) {
      if (drawable.opacity >= 1) {
        drawable.draw(canvas, devicePixelRatio);
        drawn.add(drawable.symbol);
      }
    }
    // Grouped in one pass, with each bucket's painted extent, so the
    // layer below covers only what it draws: an unbounded saveLayer
    // allocates a full-viewport offscreen target, and there is one per
    // bucket per frame for the whole fade.
    final buckets = <double, List<_DrawableSymbol>>{};
    for (final drawable in toDraw) {
      final opacity = drawable.opacity;
      if (opacity > 0 && opacity < 1) (buckets[opacity] ??= []).add(drawable);
    }
    for (final opacity in buckets.keys.toList()..sort()) {
      final bucket = buckets[opacity]!;
      var extent = bucket.first.bounds;
      for (final drawable in bucket.skip(1)) {
        extent = extent.expandToInclude(drawable.bounds);
      }
      canvas.saveLayer(
        // Padded for halo bleed: the bounds are tight, and a clipped
        // halo would be a visible artefact. The canvas intersects this
        // with the current clip, so no screen bound is needed here.
        extent.inflate(_fadeLayerPadding),
        Paint()..color = Color.fromRGBO(0, 0, 0, opacity),
      );
      for (final drawable in bucket) {
        drawable.draw(canvas, devicePixelRatio);
        drawn.add(drawable.symbol);
      }
      canvas.restore();
    }
    return drawn;
  }

  /// Opacity [layer]'s zoom range gives a symbol at [styleZoom]: 1
  /// everywhere except the last [_zoomFadeWindow] before a declared
  /// `maxzoom`, over which it ramps to 0. Zooming in past the threshold
  /// then dissolves the label instead of snapping it away, and because
  /// the ramp is a function of zoom alone it is exactly reversible —
  /// zoom back out and the label ramps in again — with no per-symbol
  /// history to keep.
  ///
  /// The ramp lives *inside* the range and reaches 0 at the threshold,
  /// so [ThemeLayer.coversZoom] stays the source of truth in [_prepare]
  /// and nothing paints outside `[minzoom, maxzoom)`.
  ///
  /// Only `maxzoom` ramps. It is exclusive, so the window covers zooms
  /// where the style is about to drop the label anyway. `minzoom` is
  /// inclusive: a symmetric ramp there would render a `minzoom: 14`
  /// layer *invisible* on a map resting at exactly zoom 14, which is
  /// both the common resting case and the first zoom the style asks for
  /// that label. The ramp may dim a symbol the style is about to
  /// remove, never one the style says is fully visible.
  ///
  /// [ThemeLayer.defaultMaxzoom] is what the reader substitutes for an
  /// absent bound — an absence, not an edge the style drew, so it never
  /// ramps.
  @visibleForTesting
  static double zoomRangeOpacity(ThemeLayer layer, double styleZoom) {
    if (layer.maxzoom >= ThemeLayer.defaultMaxzoom) return 1;
    final opacity = (layer.maxzoom - styleZoom) / _zoomFadeWindow;
    if (opacity >= 1) return 1;
    // Floored, so the ramp reaches exactly 0 at the threshold and hands
    // over to the hard cut instead of vanishing from a visible step.
    return (opacity.clamp(0.0, 1.0) * _opacitySteps).floor() / _opacitySteps;
  }

  /// Quantizes a draw opacity onto the [_opacitySteps] grid, keeping
  /// anything still visible at least one step above zero: only a symbol
  /// [zoomRangeOpacity] has fully retired draws at 0.
  static double _quantizeOpacity(double opacity) => opacity <= 0
      ? 0
      : math.max(1, (opacity * _opacitySteps).round()) / _opacitySteps;

  /// Shapes the text (and, for curved along-line labels, the per-glyph
  /// painters) of [symbols] into the caches ahead of the first frame
  /// that draws them. Called from the render pump when a tile's symbols
  /// are published, so the shaping cost lands in the budgeted tick
  /// instead of the paint phase. Best-effort: [paint] still shapes
  /// lazily on a cache miss.
  void prewarm(List<SymbolInstance> symbols, double styleZoom) {
    final zoom = (styleZoom * _zoomStep).round() / _zoomStep;
    for (final instance in symbols) {
      if (instance.text.isEmpty) continue;
      final layer = instance.layer;
      final ctx = EvalContext(
        zoom: zoom,
        properties: instance.properties,
        geometryType: instance.geometryType,
        featureId: instance.featureId,
      );
      if (layer.textOpacity.eval(ctx) <= 0) continue;
      final size = layer.textSize.eval(ctx);
      // Written as a positive test, like the one in [_prepare]: a NaN
      // size — a style expression dividing by zero — fails `>=` and is
      // skipped, where `if (size < min) continue` would let it through
      // to shaping, which throws when it rounds the halo ratio.
      if (size >= _minVisibleTextSize) {
        final fontSize = size.clamp(_minVisibleTextSize, 96.0);
        final text = _layoutText(instance, layer, ctx, fontSize);
        // The per-grapheme work is the expensive half for road labels.
        if (instance.alongLine && instance.curveSafe && instance.path != null) {
          for (final cluster in text.clusters) {
            _glyphPainters(cluster.grapheme, text);
          }
        }
      }
    }
  }

  /// [evalZoom] is quantized for the expression memos; [styleZoom] is
  /// the camera's exact fractional zoom and gates visibility, which is a
  /// discrete cut that must land where the style says it does.
  _DrawableSymbol? _prepare(
    PlacedSymbol placed,
    double evalZoom,
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

    // The layer's zoom range is continuous (MapLibre semantics), while
    // layout gates only per integer band: a symbol stops painting the
    // moment the fractional style zoom leaves [minzoom, maxzoom) —
    // including symbols from retained previous-level tiles. Gated on the
    // exact zoom, not the quantized one: rounding would move the cut by
    // up to half a step, so labels would appear or vanish up to 1/16 of
    // a level away from the threshold the style declares.
    if (!layer.coversZoom(styleZoom)) return null;

    final ctx = EvalContext(
      zoom: evalZoom,
      properties: instance.properties,
      geometryType: instance.geometryType,
      featureId: instance.featureId,
    );

    // A label the style has faded out is skipped rather than laid out:
    // reserving collision space for invisible text would suppress the
    // visible labels around it.
    _LaidOutText? text;
    var fontSize = _shapeSize;
    var textScale = 1.0;
    if (instance.text.isNotEmpty && layer.textOpacity.eval(ctx) > 0) {
      final size = layer.textSize.eval(ctx);
      if (size >= _minVisibleTextSize) {
        fontSize = size.clamp(_minVisibleTextSize, 96.0);
        textScale = fontSize / _shapeSize;
        text = _layoutText(instance, layer, ctx, fontSize);
      }
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
      return _prepareVariableAnchor(placed, layer, ctx, text, fontSize,
          textScale, icon, variableAnchors, collision);
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
          return _prepareCurved(
              placed, layer, ctx, text, fontSize, textScale, icon, collision);
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
      // Shaped at the reference size: screen dimensions carry the scale.
      final width = text.size.width * textScale;
      final height = text.size.height * textScale;
      final em = fontSize;
      final shifted = anchor +
          Offset(
            offset.isNotEmpty ? offset[0] * em : 0,
            offset.length > 1 ? offset[1] * em : 0,
          );
      textRect =
          _anchoredRect(layer.textAnchor.eval(ctx), shifted, width, height);
      if (instance.alongLine) {
        angle = lineTextAngle;
        // Along-line text is centered on the anchor.
        textRect =
            Rect.fromCenter(center: anchor, width: width, height: height);
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
    if (!allowOverlap && !collision.tryPlaceAll(boxes, ghost: placed.ghost)) {
      // Icon may still be placed when text is optional.
      if (icon != null &&
          text != null &&
          layer.textOptional.eval(ctx) &&
          collision.tryPlaceAll([icon.rect.inflate(2)], ghost: placed.ghost)) {
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
      textScale: textScale,
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
    double fontSize,
    double textScale,
    _DrawableIcon? icon,
    List<String> anchors,
    _CollisionIndex collision,
  ) {
    final padding = layer.textPadding.eval(ctx);
    final radial = layer.textRadialOffset.eval(ctx) * fontSize;
    final allowOverlap = layer.textAllowOverlap.eval(ctx);
    final width = text.size.width * textScale;
    final height = text.size.height * textScale;
    for (final anchorName in anchors) {
      final shifted = placed.screenAnchor + _radialShift(anchorName, radial);
      final textRect = _anchoredRect(anchorName, shifted, width, height);
      final boxes = [
        textRect.inflate(padding),
        if (icon != null) icon.rect.inflate(2),
      ];
      if (allowOverlap || collision.tryPlaceAll(boxes, ghost: placed.ghost)) {
        return _DrawableSymbol(placed,
            icon: icon, text: text, textRect: textRect, textScale: textScale);
      }
    }
    if (icon != null &&
        layer.textOptional.eval(ctx) &&
        collision.tryPlaceAll([icon.rect.inflate(2)], ghost: placed.ghost)) {
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
    double fontSize,
    double textScale,
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
          collision.tryPlaceAll([icon.rect.inflate(2)], ghost: placed.ghost)) {
        return _DrawableSymbol(placed, icon: icon);
      }
      return null;
    }

    // The label occupies [d0, d1] along the path, in logical units.
    // Cluster metrics are at the reference size; [textScale] converts
    // them to screen pixels before [scale] converts those to logical.
    final scale = transform.scale;
    final halfW = text.size.width * textScale / 2 / scale;
    final d0 = instance.pathDistance - halfW;
    final d1 = instance.pathDistance + halfW;
    if (d0 < 0 || d1 > path.length) return iconFallback();

    // Reading direction: walk the path backwards when the label would
    // come out upside-down on screen.
    final s0 = transform.apply(path.pointAt(d0));
    final s1 = transform.apply(path.pointAt(d1));
    final reversed = layer.textKeepUpright.eval(ctx) && s1.dx < s0.dx;

    final offset = layer.textOffset.eval(ctx);
    final perp = offset.length > 1 ? offset[1] * fontSize : 0.0;
    final maxAngle = layer.textMaxAngle.eval(ctx) * math.pi / 180;

    final placements =
        <({String grapheme, Offset pos, double angle, double width})>[];
    var previousAngle = double.nan;
    var maxDeviation = 0.0;
    double? firstAngle;
    for (final cluster in clusters) {
      final centre = cluster.center * textScale;
      final d = reversed ? d1 - centre / scale : d0 + centre / scale;
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
        width: cluster.width * textScale,
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
          width: text.size.width * textScale,
          height: text.size.height * textScale);
      final boxes = [
        _rotatedBounds(textRect, placed.screenAnchor, angle).inflate(padding),
        if (icon != null) icon.rect.inflate(2),
      ];
      if (!allowOverlap && !collision.tryPlaceAll(boxes, ghost: placed.ghost)) {
        return iconFallback();
      }
      return _DrawableSymbol(placed,
          icon: icon,
          text: text,
          textRect: textRect,
          textAngle: angle,
          textScale: textScale);
    }

    // Per-glyph collision boxes.
    final glyphHeight = fontSize * 1.2;
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
    if (!allowOverlap && !collision.tryPlaceAll(boxes, ghost: placed.ghost)) {
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
    return _DrawableSymbol(placed,
        icon: icon, curvedGlyphs: glyphs, textScale: textScale);
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

  /// Returns the shaped text for [instance], shaped at [_shapeSize]
  /// regardless of [fontSize] — the caller scales at draw time. The
  /// cache key therefore contains no font size, and `text-opacity` /
  /// `text-halo-width` enter it quantized: a `text-size` ramp reuses
  /// one shaped paragraph across the whole pinch, and opacity/halo
  /// ramps rotate the key a bounded number of times instead of per
  /// eval-zoom step.
  _LaidOutText _layoutText(
    SymbolInstance instance,
    SymbolThemeLayer layer,
    EvalContext ctx,
    double fontSize,
  ) {
    // Fast path: at an unchanged eval zoom the memoized key is valid
    // as-is. Only the key: the laid-out text itself belongs to the LRU,
    // which may evict and dispose it.
    final memo = instance.textStyleMemo;
    if (memo != null && memo.zoom == ctx.zoom) {
      final memoized = _textCache.get(memo.cacheKey);
      if (memoized != null) return memoized;
      return _shape(instance, memo);
    }

    // `text-opacity` is folded into the colours quantized to 1/32
    // steps (~3%, invisible on labels), so an opacity ramp rebuilds a
    // label's paragraphs at most 32 times ever instead of per step.
    final opacity =
        (layer.textOpacity.eval(ctx).clamp(0.0, 1.0) * 32).round() / 32;
    final color = _withOpacity(layer.textColor.eval(ctx), opacity);
    final haloColor = _withOpacity(layer.textHaloColor.eval(ctx), opacity);
    final haloWidth = layer.textHaloWidth.eval(ctx).clamp(0.0, 8.0);
    // The halo stroke is baked into the paragraph, so it must scale
    // with the drawn text: store it as a font-size ratio, quantized to
    // 1/128 em (≤0.06px error at 16px — imperceptible).
    final haloRatioQ =
        haloColor.a <= 0 ? 0 : (haloWidth / fontSize * 128).round();
    final fillArgb = color.toARGB32();
    final haloArgb = haloRatioQ == 0 ? 0 : haloColor.toARGB32();
    final fonts = layer.textFont.eval(ctx);
    final letterSpacingEm = layer.textLetterSpacing.eval(ctx);
    final maxWidthEm = layer.textMaxWidth.eval(ctx);

    // A zoom step rarely moves any quantized primitive: revalidate the
    // memo by value and reuse its key strings without rebuilding them.
    if (memo != null &&
        memo.matches(fillArgb, haloArgb, haloRatioQ, fonts, letterSpacingEm,
            maxWidthEm)) {
      memo.zoom = ctx.zoom;
      final memoized = _textCache.get(memo.cacheKey);
      if (memoized != null) return memoized;
      return _shape(instance, memo);
    }

    final styleKey =
        '$fillArgb|$haloArgb|$haloRatioQ|${fonts.join(',')}|$letterSpacingEm';
    // Along-line labels never wrap.
    final cacheKey =
        '${instance.text}|$styleKey|$maxWidthEm|${instance.alongLine}';
    final built = TextStyleMemo(
      fillArgb: fillArgb,
      haloArgb: haloArgb,
      haloRatioQ: haloRatioQ,
      fonts: fonts,
      letterSpacingEm: letterSpacingEm,
      maxWidthEm: maxWidthEm,
      styleKey: styleKey,
      cacheKey: cacheKey,
      zoom: ctx.zoom,
    );
    instance.textStyleMemo = built;
    final cached = _textCache.get(cacheKey);
    if (cached != null) return cached;
    return _shape(instance, built);
  }

  /// Shapes [instance]'s text at the reference size per [memo] and puts
  /// it in the text cache.
  _LaidOutText _shape(SymbolInstance instance, TextStyleMemo memo) {
    debugShapedTextCount++;
    final singleLine = instance.alongLine;
    final maxLines = singleLine ? 1 : 4;
    final maxWidth = singleLine
        ? double.infinity
        : math.max(_shapeSize * memo.maxWidthEm, _shapeSize * 2);
    final style = _textStyle(
        memo.fonts, _shapeSize, memo.letterSpacingEm, Color(memo.fillArgb));
    final fill = TextPainter(
      text: TextSpan(text: instance.text, style: style),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
      maxLines: maxLines,
    )..layout(maxWidth: maxWidth);

    TextPainter? halo;
    TextStyle? haloStyle;
    if (memo.haloRatioQ > 0) {
      haloStyle = style.copyWith(
        foreground: Paint()
          ..style = PaintingStyle.stroke
          // 2 · (haloRatioQ/128) · _shapeSize
          ..strokeWidth = memo.haloRatioQ / 4
          ..strokeJoin = StrokeJoin.round
          ..color = Color(memo.haloArgb),
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
      styleKey: memo.styleKey,
      fillStyle: style,
      haloStyle: haloStyle,
    );
    _textCache.put(memo.cacheKey, laidOut);
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

/// Text shaped at [LabelPainter._shapeSize]; every metric ([size],
/// cluster positions/widths) is in reference-size units and is scaled
/// by the evaluated `text-size / _shapeSize` at use sites.
class _LaidOutText {
  final String text;
  final TextPainter fill;
  final TextPainter? halo;
  final Size size;
  final String styleKey;
  final TextStyle fillStyle;
  final TextStyle? haloStyle;

  List<_Cluster>? _clusters;

  _LaidOutText({
    required this.text,
    required this.fill,
    required this.halo,
    required this.size,
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

  /// evaluated `text-size` / [LabelPainter._shapeSize]: paragraphs are
  /// shaped at the reference size and drawn through this scale, which
  /// keeps them vector-crisp (glyphs rasterize at device scale under
  /// the canvas transform).
  final double textScale;
  final List<_CurvedGlyph>? curvedGlyphs;

  /// Opacity this symbol actually draws at: its cohort's fade-in times
  /// its layer's zoom-range ramp, quantized. Assigned by [_paint] once
  /// the symbol has survived collision — every construction site would
  /// otherwise have to thread a value none of them computes.
  double opacity = 1;

  _DrawableSymbol(
    this.symbol, {
    this.icon,
    this.text,
    this.textRect = Rect.zero,
    this.textAngle = 0,
    this.textScale = 1,
    this.curvedGlyphs,
  });

  /// Screen extent of everything [draw] paints, for bounding the fade
  /// layer a cohort draws through. Rotated pieces contribute the circle
  /// they sweep, so the answer is conservative and never too small.
  Rect get bounds {
    Rect? result;
    void add(Rect rect) =>
        result = result == null ? rect : result!.expandToInclude(rect);

    Rect sweptCircle(Offset center, double width, double height) {
      final diagonal = math.sqrt(width * width + height * height);
      return Rect.fromCircle(center: center, radius: diagonal / 2 * textScale);
    }

    final icon = this.icon;
    if (icon != null) add(icon.rect);
    final glyphs = curvedGlyphs;
    final text = this.text;
    if (glyphs != null) {
      for (final glyph in glyphs) {
        final painter = glyph.painters.halo ?? glyph.painters.fill;
        add(sweptCircle(glyph.position, painter.width, painter.height));
      }
    } else if (text != null) {
      add(textAngle == 0
          ? textRect
          : sweptCircle(
              symbol.screenAnchor, text.size.width, text.size.height));
    }
    return result ?? Rect.zero;
  }

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
          if (textScale != 1) canvas.scale(textScale);
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
      if (textScale != 1) canvas.scale(textScale);
      final topLeft = Offset(-t.size.width / 2, -t.size.height / 2);
      t.halo?.paint(canvas, topLeft);
      t.fill.paint(canvas, topLeft);
      canvas.restore();
    } else if (textScale != 1) {
      canvas.save();
      canvas.translate(textRect.left, textRect.top);
      canvas.scale(textScale);
      t.halo?.paint(canvas, Offset.zero);
      t.fill.paint(canvas, Offset.zero);
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

  /// Space taken by labels fading out, kept apart from [_cells] so they
  /// reserve nothing against live labels while still excluding each
  /// other — see [tryPlaceAll].
  final Map<int, List<Rect>> _ghostCells = {};
  final int _columns;

  _CollisionIndex(Size screenSize)
      : _columns = math.max(1, (screenSize.width / _cellSize).ceil() + 4);

  /// Whether [rects] fit, reserving them when they do.
  ///
  /// A [ghost] reserves nothing that a live label can see, so a label on
  /// its way out never blocks one that outlives it. It is still placed
  /// against the other ghosts: a feature landing on a tile seam is
  /// claimed by both neighbours by design (see `symbol_layouter.dart`),
  /// and this pass is what suppresses the duplicate. Without a reservation
  /// of its own a departing label would draw twice over its own copy —
  /// visibly doubled, and doubly opaque, for the length of the fade.
  bool tryPlaceAll(List<Rect> rects, {bool ghost = false}) {
    for (final rect in rects) {
      if (_collides(rect)) return false;
    }
    if (ghost) {
      for (final rect in rects) {
        if (_collidesIn(_ghostCells, rect)) return false;
      }
    }
    final cells = ghost ? _ghostCells : _cells;
    for (final rect in rects) {
      _insertIn(cells, rect);
    }
    return true;
  }

  // The cell walks are inlined in both callers: a sync* generator here
  // allocated an iterator per collision box per frame in the hottest
  // label loop.

  bool _collides(Rect rect) => _collidesIn(_cells, rect);

  bool _collidesIn(Map<int, List<Rect>> cells, Rect rect) {
    final minX = ((rect.left + 512) / _cellSize).floor();
    final maxX = ((rect.right + 512) / _cellSize).floor();
    final minY = ((rect.top + 512) / _cellSize).floor();
    final maxY = ((rect.bottom + 512) / _cellSize).floor();
    for (var y = minY; y <= maxY; y++) {
      for (var x = minX; x <= maxX; x++) {
        final rects = cells[y * _columns + x];
        if (rects == null) continue;
        for (final other in rects) {
          if (rect.overlaps(other)) return true;
        }
      }
    }
    return false;
  }

  void _insertIn(Map<int, List<Rect>> cells, Rect rect) {
    final minX = ((rect.left + 512) / _cellSize).floor();
    final maxX = ((rect.right + 512) / _cellSize).floor();
    final minY = ((rect.top + 512) / _cellSize).floor();
    final maxY = ((rect.bottom + 512) / _cellSize).floor();
    for (var y = minY; y <= maxY; y++) {
      for (var x = minX; x <= maxX; x++) {
        (cells[y * _columns + x] ??= []).add(rect);
      }
    }
  }
}
