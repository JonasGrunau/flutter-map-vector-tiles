import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map_vector_tiles/src/render/label_painter.dart';
import 'package:flutter_map_vector_tiles/src/render/symbol_layouter.dart';
import 'package:flutter_map_vector_tiles/src/style/theme.dart';
import 'package:flutter_map_vector_tiles/src/style/theme_reader.dart';
import 'package:flutter_map_vector_tiles/src/text/glyph_source.dart';

import 'script_fonts_io.dart'
    if (dart.library.js_interop) 'script_fonts_web.dart';

/// The bundled fonts, in the fallback order labels are shaped with —
/// a stand-in for a phone's system fonts. Each is a subset to the
/// characters in `script_samples.dart` (see `fonts/build.sh`).
const scriptFonts = [
  'NotoSans',
  'NotoSansArmenian',
  'NotoSansGeorgian',
  'NotoSansHebrew',
  'NotoSansArabic',
  'NotoSansBengali',
  'NotoSansTamil',
  'NotoSansSinhala',
  'NotoSansThai',
  'NotoSansLao',
  'NotoSansKhmer',
  'NotoSansMyanmar',
  'NotoSerifTibetan',
  'NotoSansSC',
  'NotoSansKR',
  'NotoEmoji',
];

/// Loads [scriptFonts] and has every [LabelPainter] shape with them.
Future<void> loadScriptFonts() async {
  allowLoadedFonts();
  for (final family in scriptFonts) {
    await (FontLoader(family)..addFont(fontBytes('$family.ttf'))).load();
  }
  LabelPainter.debugFontFamilies = scriptFonts;
}

/// The size labels are drawn at: the painter's shaping reference size,
/// so text is drawn at scale 1 and never snapped — positions in the
/// image are the layout's own.
const textSize = 16.0;

SymbolThemeLayer symbolLayer({
  Map<String, Object?> layout = const {},
  Map<String, Object?> paint = const {},
  bool alongLine = false,
}) {
  final theme = const ThemeReader().read({
    'layers': [
      {
        'id': 'label',
        'type': 'symbol',
        'source': 's',
        'source-layer': 'place',
        'layout': {
          if (alongLine) 'symbol-placement': 'line',
          'text-field': '{name}',
          'text-size': textSize,
          'text-font': ['Noto Sans Regular'],
          ...layout,
        },
        'paint': {
          'text-color': '#000000',
          ...paint,
        },
      },
    ],
  });
  return theme.layers.single as SymbolThemeLayer;
}

/// A path through [points], with the cumulative distances the layouter
/// gives one.
SymbolPath symbolPath(List<Offset> points) {
  final coords = Float32List(points.length * 2);
  final cumulative = Float32List(points.length);
  var total = 0.0;
  for (var i = 0; i < points.length; i++) {
    coords[i * 2] = points[i].dx;
    coords[i * 2 + 1] = points[i].dy;
    if (i > 0) total += (points[i] - points[i - 1]).distance;
    cumulative[i] = total;
  }
  return SymbolPath(coords, cumulative);
}

/// An arc bulging upwards, its apex at [apex]: [radius] wide, swept
/// [degrees] either side of the top in [steps] segments. Tight enough
/// that a label on it visibly bends, gentle enough that no label trips
/// `text-max-angle` or the upright guard.
SymbolPath arcPath({
  Offset apex = const Offset(200, 40),
  double radius = 80,
  double degrees = 75,
  int steps = 61,
}) {
  final centre = apex + Offset(0, radius);
  return symbolPath([
    for (var i = 0; i <= steps; i++)
      () {
        final a = (-degrees + 2 * degrees * i / steps) * math.pi / 180;
        return centre + Offset(math.sin(a), -math.cos(a)) * radius;
      }(),
  ]);
}

/// An arc, its apex at [apex], that the label [text] spans 90° of —
/// so that every label, short or long, bends visibly on it.
Future<SymbolPath> arcFor(String text,
    {Offset apex = const Offset(200, 40)}) async {
  final straight = await drawLabel(text, size: curvedSize);
  final halfWidth = straight.box()!.width / straight.devicePixelRatio / 2;
  return arcPath(
      apex: apex, radius: halfWidth / math.sin(math.pi / 4), degrees: 70);
}

/// Where [arcPath]'s labels are drawn, and how much room they get.
const curvedSize = Size(400, 160);

var _generation = 0;

/// [text] as a label candidate, the way the layer hands one to the
/// painter: a point label at [at], or with [path] a label along that
/// line at its middle. [layerIndex] keeps several labels apart in one
/// frame, each with its own [layout] and [paint].
PlacedSymbol label(
  String text, {
  Map<String, Object?> layout = const {},
  Map<String, Object?> paint = const {},
  SymbolPath? path,
  Offset at = const Offset(200, 60),
  int layerIndex = 0,
}) {
  final layer =
      symbolLayer(layout: layout, paint: paint, alongLine: path != null);
  if (path == null) {
    return PlacedSymbol(
      instance: SymbolInstance(
        layer: layer,
        layerIndex: layerIndex,
        anchor: Offset.zero,
        angle: 0,
        alongLine: false,
        text: text,
        iconName: null,
        sortKey: 0,
        properties: const {},
        geometryType: 'Point',
        featureId: null,
      ),
      screenAnchor: at,
      screenAngle: 0,
    );
  }
  final d = path.length / 2;
  final transform = TileTransform(origin: Offset.zero, scale: 1, rotation: 0);
  return PlacedSymbol(
    instance: SymbolInstance(
      layer: layer,
      layerIndex: layerIndex,
      anchor: path.pointAt(d),
      angle: path.angleAt(d),
      alongLine: true,
      path: path,
      pathDistance: d,
      text: text,
      iconName: null,
      sortKey: 0,
      properties: const {},
      geometryType: 'LineString',
      featureId: null,
    ),
    screenAnchor: transform.apply(path.pointAt(d)),
    screenAngle: path.angleAt(d),
    transform: transform,
  );
}

/// How many labels the last [paintLabels] drew from the style's glyphs
/// rather than the platform's fonts — for `script_glyphs_test.dart`,
/// which checks which path each script takes.
var lastGlyphShaped = 0;

/// Paints [symbols] in one frame of a fresh [LabelPainter], [size]
/// logical pixels at [devicePixelRatio] over [background] (transparent
/// by default), and returns the image and how many were placed. With
/// [glyphs], the painter draws what text it can from them, as a layer
/// given `glyphs` does, once the ranges the labels need have loaded.
Future<(ui.Image, int)> paintLabels(
  List<PlacedSymbol> symbols, {
  Size size = const Size(400, 120),
  double devicePixelRatio = 2,
  Color? background,
  GlyphSource? glyphs,
}) async {
  final painter = LabelPainter()..glyphs = glyphs;
  await painter.glyphsPending([for (final s in symbols) s.instance], 12);
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)..scale(devicePixelRatio);
  if (background != null) canvas.drawColor(background, BlendMode.src);
  final placed = painter.paint(
    canvas: canvas,
    screenSize: size,
    styleZoom: 12,
    symbols: symbols,
    devicePixelRatio: devicePixelRatio,
    placementGeneration: _generation++,
  );
  lastGlyphShaped = painter.debugGlyphShapedTextCount;
  final picture = recorder.endRecording();
  final image = await picture.toImage((size.width * devicePixelRatio).round(),
      (size.height * devicePixelRatio).round());
  picture.dispose();
  painter.dispose();
  return (image, placed.length);
}

/// Draws [text] as one label (see [label]) and returns its pixels.
Future<LabelImage> drawLabel(
  String text, {
  Map<String, Object?> layout = const {},
  Map<String, Object?> paint = const {},
  SymbolPath? path,
  Offset at = const Offset(200, 60),
  Size size = const Size(400, 120),
  double devicePixelRatio = 2,
  Color? background,
  GlyphSource? glyphs,
}) async {
  final (image, placed) = await paintLabels(
    [label(text, layout: layout, paint: paint, path: path, at: at)],
    size: size,
    devicePixelRatio: devicePixelRatio,
    background: background,
    glyphs: glyphs,
  );
  final bytes =
      await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
  final result = LabelImage(
    width: image.width,
    height: image.height,
    devicePixelRatio: devicePixelRatio,
    rgba: bytes!.buffer.asUint8List(),
    placed: placed > 0,
  );
  image.dispose();
  return result;
}

/// The pixels of one drawn label, with the measurements the suite's
/// assertions are made of. Nothing here knows how the painter drew the
/// text — paragraph, glyph atlas or anything that replaces them — which
/// is the point: the assertions hold for any renderer that draws the
/// script correctly.
class LabelImage {
  final int width;
  final int height;
  final double devicePixelRatio;

  /// Straight (unpremultiplied) RGBA.
  final Uint8List rgba;

  /// Whether the painter placed the label at all.
  final bool placed;

  LabelImage({
    required this.width,
    required this.height,
    required this.devicePixelRatio,
    required this.rgba,
    required this.placed,
  });

  /// Whether the pixel at device ([x], [y]) holds ink: at least half
  /// covered by anything drawn.
  bool isInk(int x, int y) => rgba[(y * width + x) * 4 + 3] >= 128;

  /// Whether the pixel holds dark ink — the black fill, not a light
  /// halo around it.
  bool isFill(int x, int y) {
    final i = (y * width + x) * 4;
    return rgba[i + 3] >= 128 && rgba[i] < 128;
  }

  /// Whether the pixel holds light ink — a white halo.
  bool isHalo(int x, int y) {
    final i = (y * width + x) * 4;
    return rgba[i + 3] >= 128 && rgba[i] >= 192;
  }

  /// The box around every pixel [test] accepts (ink by default), in
  /// device pixels; null when there is none.
  PixelBox? box([bool Function(int x, int y)? test]) {
    final accept = test ?? isInk;
    var left = width, top = height, right = -1, bottom = -1;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        if (!accept(x, y)) continue;
        if (x < left) left = x;
        if (x > right) right = x;
        if (y < top) top = y;
        if (y > bottom) bottom = y;
      }
    }
    return right < 0 ? null : PixelBox(left, top, right + 1, bottom + 1);
  }

  late final PixelBox? _inkBox = box();

  /// How many pixels [test] accepts (ink by default).
  int count([bool Function(int x, int y)? test]) {
    final accept = test ?? isInk;
    var n = 0;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        if (accept(x, y)) n++;
      }
    }
    return n;
  }

  /// The share of this image's ink that [other] also has ink at, within
  /// [slack] device pixels — 1 when [other] covers all of it. Slack
  /// absorbs the sub-pixel shifts shaping one string differently from
  /// another causes, and that rasterizers differ by.
  ///
  /// With [dx] and [dy], [other] is looked at that far from each pixel:
  /// how well this image covers [other]'s ink moved by (-[dx], -[dy]).
  double coveredBy(LabelImage other, {int slack = 1, int dx = 0, int dy = 0}) {
    final bounds = _inkBox;
    if (bounds == null) return 1;
    var ink = 0, covered = 0;
    for (var y = bounds.top; y < bounds.bottom; y++) {
      for (var x = bounds.left; x < bounds.right; x++) {
        if (!isInk(x, y)) continue;
        ink++;
        if (other._inkNear(x + dx, y + dy, slack)) covered++;
      }
    }
    return ink == 0 ? 1 : covered / ink;
  }

  /// The best [coveredBy] over every shift within [range] device pixels
  /// of ([dx], [dy]), and the shift that gives it.
  (double, int, int) bestCoveredBy(LabelImage other,
      {int dx = 0, int dy = 0, int range = 6}) {
    var best = (-1.0, 0, 0);
    for (var y = dy - range; y <= dy + range; y++) {
      for (var x = dx - range ~/ 2; x <= dx + range ~/ 2; x++) {
        final covered = coveredBy(other, dx: x, dy: y);
        if (covered > best.$1) best = (covered, x, y);
      }
    }
    return best;
  }

  bool _inkNear(int x, int y, int slack) {
    for (var dy = -slack; dy <= slack; dy++) {
      final yy = y + dy;
      if (yy < 0 || yy >= height) continue;
      for (var dx = -slack; dx <= slack; dx++) {
        final xx = x + dx;
        if (xx < 0 || xx >= width) continue;
        if (isInk(xx, yy)) return true;
      }
    }
    return false;
  }

  /// Whether the two images show the same ink, each covering the
  /// other's to within [tolerance].
  bool looksLike(LabelImage other, {double tolerance = 0.03}) =>
      coveredBy(other) >= 1 - tolerance &&
      other.coveredBy(this) >= 1 - tolerance;

  /// Columns between the leftmost and rightmost ink that hold none: the
  /// gaps between separately drawn pieces.
  int emptyColumns() {
    final ink = box();
    if (ink == null) return 0;
    var empty = 0;
    for (var x = ink.left; x < ink.right; x++) {
      var any = false;
      for (var y = ink.top; y < ink.bottom && !any; y++) {
        any = isInk(x, y);
      }
      if (!any) empty++;
    }
    return empty;
  }

  /// How far the ink at both ends of the label sits below the ink in
  /// its middle, in device pixels — the lesser of the two ends. A label
  /// following a line that bulges upwards droops at its ends; one drawn
  /// straight does not, beyond what the shapes of its letters do.
  double endDrop() {
    final ink = box();
    if (ink == null) return 0;
    final end = math.max(1, (ink.width * 0.15).round());
    final middle = math.max(1, (ink.width * 0.1).round());
    final centre = ink.centerX.round();
    final mid = _meanInkY(centre - middle, centre + middle);
    return math.min(_meanInkY(ink.left, ink.left + end) - mid,
        _meanInkY(ink.right - end, ink.right) - mid);
  }

  double _meanInkY(int fromX, int toX) {
    var sum = 0, n = 0;
    for (var y = 0; y < height; y++) {
      for (var x = math.max(0, fromX); x < math.min(width, toX); x++) {
        if (!isInk(x, y)) continue;
        sum += y;
        n++;
      }
    }
    return n == 0 ? 0 : sum / n;
  }

  /// Encodes the pixels as PNG, for looking at a failure.
  Future<Uint8List> toPng() async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(rgba);
    final descriptor = ui.ImageDescriptor.raw(buffer,
        width: width, height: height, pixelFormat: ui.PixelFormat.rgba8888);
    final codec = await descriptor.instantiateCodec();
    final frame = await codec.getNextFrame();
    final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
    frame.image.dispose();
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();
    return data!.buffer.asUint8List();
  }
}

/// A box of device pixels, right and bottom exclusive.
class PixelBox {
  final int left, top, right, bottom;
  const PixelBox(this.left, this.top, this.right, this.bottom);
  int get width => right - left;
  int get height => bottom - top;
  double get centerX => (left + right) / 2;

  @override
  String toString() => 'PixelBox($left, $top, $right, $bottom)';
}
