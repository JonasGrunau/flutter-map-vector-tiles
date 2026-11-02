import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/painting.dart';
import 'package:meta/meta.dart';

import '../core/tile_key.dart';
import '../core/tile_zoom.dart';
import '../grid/raster_tile_store.dart';
import '../logger.dart';
import '../style/expression.dart';
import '../style/theme.dart';
import '../tile_providers.dart';
import 'display_tile_data.dart';

/// The two compiled hillshade shaders (`shaders/` in this package).
///
/// Loaded once per process ([load]); the rasterizer reads [loaded]
/// synchronously, so the layer awaits [load] before it renders a tile
/// that has a hillshade in it.
class HillshadePrograms {
  final ui.FragmentProgram prepare;
  final ui.FragmentProgram shade;

  const HillshadePrograms._(this.prepare, this.shade);

  static Future<HillshadePrograms?>? _loading;
  static HillshadePrograms? _loaded;

  /// The programs, once [load] has finished; null before, and for good
  /// where fragment programs are unavailable.
  static HillshadePrograms? get loaded => _loaded;

  /// Loads both programs, once per process. Resolves to null — after
  /// logging why — where they cannot load: Flutter's retired HTML web
  /// renderer has no fragment programs, and a hillshade then simply
  /// does not draw.
  static Future<HillshadePrograms?> load([
    Logger logger = const Logger.noop(),
  ]) =>
      _loading ??= _load(logger);

  static Future<HillshadePrograms?> _load(Logger logger) async {
    try {
      final prepare = await _program('hillshade_prepare.frag');
      final shade = await _program('hillshade.frag');
      return _loaded = HillshadePrograms._(prepare, shade);
    } catch (e) {
      logger.warn('hillshade layers are not drawn: their shaders did not '
          'load ($e)');
      return null;
    }
  }

  /// A dependent app bundles this package's shaders under its
  /// `packages/` prefix; the package's own tests run it as the root
  /// package, which bundles them without one.
  static Future<ui.FragmentProgram> _program(String name) async {
    try {
      return await ui.FragmentProgram.fromAsset(
          'packages/flutter_map_vector_tiles/shaders/$name');
    } catch (_) {
      return ui.FragmentProgram.fromAsset('shaders/$name');
    }
  }

  /// Forgets the programs, so that the next [load] starts over. For
  /// tests that exercise the not-yet-loaded path.
  @visibleForTesting
  static void debugReset() {
    _loading = null;
    _loaded = null;
  }
}

/// Draws `hillshade` layers: terrain shading from a `raster-dem`
/// source, computed on the GPU in MapLibre's two steps.
///
/// Per DEM tile, a *prepare* pass turns elevations into slopes — one
/// texel per DEM texel, plus a one-texel border — from a copy of the
/// tile with a two-texel border borrowed from its eight neighbours, so
/// that slopes are continuous across tile edges. The *shade* pass then
/// colours every pixel of the tile's area from slopes interpolated
/// between texels, with the layer's illumination, colours and method.
/// The bordered copy and the slopes are small offscreen snapshots at
/// the DEM's own resolution (260 and 258 texels square for a 256 px
/// source); the shading is recorded into the display tile's picture like
/// any other layer, so it is rasterized once with the tile and never per
/// frame.
class HillshadeRenderer {
  HillshadeRenderer._();

  /// Paints [layer] for the display tile [data] onto [canvas], in
  /// logical tile coordinates. Returns whether anything was drawn —
  /// nothing is when the shaders are not loaded, the source is not a
  /// `raster-dem` source, no DEM tile is at hand, or the exaggeration
  /// is zero (MapLibre skips such a layer too).
  static bool paint(
    Canvas canvas,
    HillshadeThemeLayer layer,
    DisplayTileData data,
    EvalContext zoomCtx,
  ) {
    final programs = HillshadePrograms.loaded;
    final source = layer.source;
    final encoding = data.demEncodings[source];
    if (programs == null || encoding == null) return false;
    final primary = data.rasters[source];
    final tiles = primary != null
        ? [primary]
        : data.descendantRasters[source] ?? const <RasterTile>[];
    if (tiles.isEmpty) return false;
    final exaggeration = layer.exaggeration.eval(zoomCtx).clamp(0.0, 1.0);
    if (exaggeration <= 0) return false;

    // Every DEM tile at hand, for the border lookups: a descendant's
    // neighbours are often its siblings.
    final byKey = <TileKey, ui.Image>{
      for (final tile in tiles) tile.key: tile.image,
      for (final tile in data.neighbourRasters[source] ?? const <RasterTile>[])
        tile.key: tile.image,
    };
    final shade = _ShadeParameters(layer, zoomCtx, exaggeration);
    var painted = false;
    for (final tile in tiles) {
      final slopes = _slopes(programs, tile, encoding, (dx, dy) {
        final key = neighbourKey(tile.key, dx, dy);
        return key == null ? null : byKey[key];
      });
      if (slopes == null) continue;
      _shade(canvas, programs, tile.key, slopes, data.displayKey, shade);
      // The recorded draw holds its own reference to the pixels.
      slopes.dispose();
      painted = true;
    }
    return painted;
  }

  /// The tile [dx], [dy] steps from [key] (each −1, 0 or 1), wrapping
  /// around the antimeridian; null past a pole.
  static TileKey? neighbourKey(TileKey key, int dx, int dy) {
    final n = 1 << key.z;
    final y = key.y + dy;
    if (y < 0 || y >= n) return null;
    return TileKey(key.z, (key.x + dx) % n, y);
  }

  /// The edges and corners of data tile [dataKey] that display tile
  /// [displayKey] touches, as (dx, dy) steps to the neighbours its
  /// hillshade borrows from — all eight unless the display tile lies
  /// inside a bigger data tile (overzoom), where only those it touches.
  static List<(int, int)> neighboursNeeded(
      TileKey displayKey, TileKey dataKey) {
    var left = true, right = true, top = true, bottom = true;
    if (dataKey.z < displayKey.z) {
      final frac = displayKey.fractionOf(dataKey);
      left = frac.dx == 0;
      top = frac.dy == 0;
      right = frac.dx + frac.scale >= 1;
      bottom = frac.dy + frac.scale >= 1;
    }
    return [
      for (final dy in const [-1, 0, 1])
        for (final dx in const [-1, 0, 1])
          if ((dx != 0 || dy != 0) &&
              (dx >= 0 || left) &&
              (dx <= 0 || right) &&
              (dy >= 0 || top) &&
              (dy <= 0 || bottom))
            (dx, dy),
    ];
  }

  /// What the prepare pass multiplies a Sobel sum of elevations (metres)
  /// by: one over eight texel widths in metres — the kernel weighs each
  /// side 4× over 2 texels — times MapLibre's zoom-dependent
  /// exaggeration, which steepens slopes below zoom 15 so that terrain
  /// stays visible from far out. [zoom] is the DEM tile's, [dim] its
  /// width in texels.
  @visibleForTesting
  static double slopeScale(int zoom, int dim) {
    final z = zoom.toDouble();
    final factor = z < 2
        ? 0.4
        : z < 4.5
            ? 0.35
            : 0.3;
    final exaggeration = z < 15 ? (z - 15) * factor : 0.0;
    // log2 of the Web Mercator world's width in metres, plus 3 for the
    // kernel's eight.
    const log2WorldWidth = 25.2562;
    return dim / math.pow(2, exaggeration + 3 + log2WorldWidth - z);
  }

  /// Latitude in degrees of the top edge of row [y] at zoom [z].
  @visibleForTesting
  static double latitudeOf(int z, int y) {
    final n = math.pi - 2 * math.pi * y / (1 << z);
    return math.atan(0.5 * (math.exp(n) - math.exp(-n))) * 180 / math.pi;
  }

  /// The slope image of [tile]: (dim + 2)² texels, null for a tile that
  /// is not square.
  static ui.Image? _slopes(
    HillshadePrograms programs,
    RasterTile tile,
    DemEncoding encoding,
    ui.Image? Function(int dx, int dy) neighbour,
  ) {
    final dem = tile.image;
    final dim = dem.width;
    if (dem.height != dim || dim < 2) return null;
    final bordered = _bordered(dem, neighbour);
    final size = dim + 2;
    final shader = programs.prepare.fragmentShader()
      ..setFloat(0, encoding.redFactor)
      ..setFloat(1, encoding.greenFactor)
      ..setFloat(2, encoding.blueFactor)
      ..setFloat(3, 0)
      ..setFloat(4, (dim + 4).toDouble())
      ..setFloat(5, slopeScale(tile.key.z, dim))
      ..setImageSampler(0, bordered);
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(
      Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
      Paint()
        ..shader = shader
        ..blendMode = BlendMode.src
        ..isAntiAlias = false,
    );
    final picture = recorder.endRecording();
    final slopes = picture.toImageSync(size, size);
    picture.dispose();
    shader.dispose();
    bordered.dispose();
    return slopes;
  }

  /// [dem] with a two-texel border: its neighbours' nearest texels where
  /// [neighbour] has them, and its own edge texels repeated where it
  /// does not — a flat border, as MapLibre leaves it until a neighbour
  /// arrives.
  static ui.Image _bordered(
    ui.Image dem,
    ui.Image? Function(int dx, int dy) neighbour,
  ) {
    final dim = dem.width;
    final d = dim.toDouble();
    final size = dim + 4;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)
      ..clipRect(Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()));
    // Exact copies: no blending with what is below, no filtering.
    final paint = Paint()
      ..blendMode = BlendMode.src
      ..filterQuality = FilterQuality.none
      ..isAntiAlias = false;
    void stretch(Rect src, Rect dst) =>
        canvas.drawImageRect(dem, src, dst, paint);
    // Edges, then corners, each one source texel wide stretched to two.
    stretch(Rect.fromLTWH(0, 0, 1, d), Rect.fromLTWH(0, 2, 2, d));
    stretch(Rect.fromLTWH(d - 1, 0, 1, d), Rect.fromLTWH(d + 2, 2, 2, d));
    stretch(Rect.fromLTWH(0, 0, d, 1), Rect.fromLTWH(2, 0, d, 2));
    stretch(Rect.fromLTWH(0, d - 1, d, 1), Rect.fromLTWH(2, d + 2, d, 2));
    stretch(const Rect.fromLTWH(0, 0, 1, 1), const Rect.fromLTWH(0, 0, 2, 2));
    stretch(Rect.fromLTWH(d - 1, 0, 1, 1), Rect.fromLTWH(d + 2, 0, 2, 2));
    stretch(Rect.fromLTWH(0, d - 1, 1, 1), Rect.fromLTWH(0, d + 2, 2, 2));
    stretch(
        Rect.fromLTWH(d - 1, d - 1, 1, 1), Rect.fromLTWH(d + 2, d + 2, 2, 2));
    canvas.drawImage(dem, const Offset(2, 2), paint);
    // Each neighbour drawn whole at its place; the clip keeps the two
    // texels of it that border this tile.
    for (final dy in const [-1, 0, 1]) {
      for (final dx in const [-1, 0, 1]) {
        if (dx == 0 && dy == 0) continue;
        final image = neighbour(dx, dy);
        if (image == null || image.width != dim || image.height != dim) {
          continue;
        }
        canvas.drawImage(image, Offset(2 + dx * d, 2 + dy * d), paint);
      }
    }
    final picture = recorder.endRecording();
    final image = picture.toImageSync(size, size);
    picture.dispose();
    return image;
  }

  /// Records the shade pass for DEM tile [demKey] into [canvas] — the
  /// part of it covering display tile [displayKey].
  static void _shade(
    Canvas canvas,
    HillshadePrograms programs,
    TileKey demKey,
    ui.Image slopes,
    TileKey displayKey,
    _ShadeParameters shade,
  ) {
    const tileSize = displayTileSize;
    final Rect rect;
    final double tile0x, tile0y, tileScale;
    if (demKey.z <= displayKey.z) {
      // The DEM tile is the display tile's own or an ancestor's: the
      // display tile shows the sub-square (dx, dy, scale) of it.
      final frac = displayKey.fractionOf(demKey);
      rect = const Rect.fromLTWH(0, 0, tileSize, tileSize);
      tile0x = frac.dx;
      tile0y = frac.dy;
      tileScale = frac.scale / tileSize;
    } else {
      // A descendant standing in on zoom-out fills its sub-square.
      final frac = demKey.fractionOf(displayKey);
      rect = Rect.fromLTWH(frac.dx * tileSize, frac.dy * tileSize,
          frac.scale * tileSize, frac.scale * tileSize);
      tile0x = 0;
      tile0y = 0;
      tileScale = 1 / rect.width;
    }
    final shader = programs.shade.fragmentShader();
    var i = 0;
    void vec4(double x, double y, double z, double w) {
      shader
        ..setFloat(i++, x)
        ..setFloat(i++, y)
        ..setFloat(i++, z)
        ..setFloat(i++, w);
    }

    void color(Color c) => vec4(c.r * c.a, c.g * c.a, c.b * c.a, c.a);

    final lights = shade.lights;
    double at(List<double> values, int j) => values[math.min(j, lights - 1)];
    vec4(at(shade.azimuths, 0), at(shade.azimuths, 1), at(shade.azimuths, 2),
        at(shade.azimuths, 3));
    vec4(at(shade.altitudes, 0), at(shade.altitudes, 1), at(shade.altitudes, 2),
        at(shade.altitudes, 3));
    color(shade.accent);
    for (var j = 0; j < HillshadeThemeLayer.maxLights; j++) {
      color(shade.shadows[math.min(j, lights - 1)]);
    }
    for (var j = 0; j < HillshadeThemeLayer.maxLights; j++) {
      color(shade.highlights[math.min(j, lights - 1)]);
    }
    shader
      // uOrigin, uTile0, uTileScale
      ..setFloat(i++, rect.left)
      ..setFloat(i++, rect.top)
      ..setFloat(i++, tile0x)
      ..setFloat(i++, tile0y)
      ..setFloat(i++, tileScale)
      ..setFloat(i++, tileScale)
      // uLatRange
      ..setFloat(i++, latitudeOf(demKey.z, demKey.y))
      ..setFloat(i++, latitudeOf(demKey.z, demKey.y + 1))
      // uSlopeSize, uMethod, uExaggeration, uNearest, uLights
      ..setFloat(i++, slopes.width.toDouble())
      ..setFloat(i++, shade.method.toDouble())
      ..setFloat(i++, shade.exaggeration)
      ..setFloat(i++, shade.nearest ? 1 : 0)
      ..setFloat(i++, lights.toDouble())
      ..setImageSampler(0, slopes);
    final paint = Paint()
      ..shader = shader
      ..isAntiAlias = false;
    if (!kIsWeb) {
      canvas.drawRect(rect, paint);
      // The recorded draw took a copy of the uniforms.
      shader.dispose();
      return;
    }
    // CanvasKit records a pointer to the shader's uniforms, not a copy,
    // and disposing the shader frees them: a draw recorded into the
    // tile, rasterized only once the tile is complete, would read freed
    // memory — garbage once something reused it. So on the web the
    // shade pass is rasterized on its own first, which `toImageSync`
    // does there at once, and the tile records the image. Never
    // disposing the shader instead would leak its uniforms.
    final scale = canvas.getTransform()[0];
    final width = math.max(1, (rect.width * scale).ceil());
    final height = math.max(1, (rect.height * scale).ceil());
    final recorder = ui.PictureRecorder();
    Canvas(recorder)
      ..scale(scale)
      ..translate(-rect.left, -rect.top)
      ..drawRect(rect, paint);
    final picture = recorder.endRecording();
    final image = picture.toImageSync(width, height);
    picture.dispose();
    shader.dispose();
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      rect,
      Paint()..filterQuality = FilterQuality.none,
    );
    image.dispose();
  }
}

/// A hillshade layer's paint properties evaluated at one zoom, in the
/// shade shader's terms.
class _ShadeParameters {
  /// Index into the shader's methods: standard, basic, combined, igor,
  /// multidirectional.
  final int method;
  final double exaggeration;
  final bool nearest;

  /// Lights drawn: 1, or up to [HillshadeThemeLayer.maxLights] for
  /// `multidirectional`.
  final int lights;

  /// Radians, with MapLibre's +π. One per light.
  final List<double> azimuths;

  /// Radians. One per light.
  final List<double> altitudes;
  final Color accent;
  final List<Color> shadows;
  final List<Color> highlights;

  factory _ShadeParameters(
    HillshadeThemeLayer layer,
    EvalContext ctx,
    double exaggeration,
  ) {
    final method = switch (layer.method.eval(ctx)) {
      'basic' => 1,
      'combined' => 2,
      'igor' => 3,
      'multidirectional' => 4,
      _ => 0,
    };
    final lights = method == 4
        ? [
            layer.directions.length,
            layer.altitudes.length,
            layer.shadowColors.length,
            layer.highlightColors.length,
          ].reduce(math.max).clamp(1, HillshadeThemeLayer.maxLights)
        : 1;
    List<T> padded<T>(List<T> values) => [
          for (var i = 0; i < lights; i++)
            values[math.min(i, values.length - 1)],
        ];
    const toRadians = math.pi / 180;
    return _ShadeParameters._(
      method: method,
      exaggeration: exaggeration,
      nearest: layer.resampling.eval(ctx) == 'nearest',
      lights: lights,
      azimuths: [
        for (final d in padded(layer.directions))
          d.eval(ctx) * toRadians + math.pi,
      ],
      altitudes: [
        for (final a in padded(layer.altitudes))
          a.eval(ctx).clamp(0.0, 90.0) * toRadians,
      ],
      accent: layer.accentColor.eval(ctx),
      shadows: [for (final c in padded(layer.shadowColors)) c.eval(ctx)],
      highlights: [for (final c in padded(layer.highlightColors)) c.eval(ctx)],
    );
  }

  const _ShadeParameters._({
    required this.method,
    required this.exaggeration,
    required this.nearest,
    required this.lights,
    required this.azimuths,
    required this.altitudes,
    required this.accent,
    required this.shadows,
    required this.highlights,
  });
}
