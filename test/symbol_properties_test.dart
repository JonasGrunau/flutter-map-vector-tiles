import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_map_vector_tiles/src/logger.dart';
import 'package:flutter_map_vector_tiles/src/render/label_painter.dart';
import 'package:flutter_map_vector_tiles/src/render/symbol_layouter.dart';
import 'package:flutter_map_vector_tiles/src/style/expression.dart';
import 'package:flutter_map_vector_tiles/src/style/sprite_atlas.dart';
import 'package:flutter_map_vector_tiles/src/style/theme.dart';
import 'package:flutter_map_vector_tiles/src/style/theme_reader.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/label_ids.dart';

// Symbol layout and paint properties beyond the basics: halo blur,
// optional icons and padding, ignore-placement and the overlap modes,
// icon-text-fit with stretchable sprites, justification and line height,
// anchor offsets, text rotation, translation, upright icons, z-order and
// tile-edge avoidance. The test font draws every glyph as a solid em
// square, which makes text extents exact in pixels.

const _canvas = Size(400, 400);
var _generation = 0;

SymbolThemeLayer _layer(
  Map<String, Object?> layout, {
  Map<String, Object?> paint = const {},
  Logger logger = const Logger.noop(),
}) {
  final theme = ThemeReader(logger: logger).read({
    'layers': [
      {
        'id': 'l',
        'type': 'symbol',
        'source': 's',
        'source-layer': 'poi',
        'layout': layout,
        'paint': paint,
      },
    ],
  });
  return theme.layers.single as SymbolThemeLayer;
}

PlacedSymbol _symbol(
  SymbolThemeLayer layer,
  Offset at, {
  String text = '',
  String? icon,
  int layerIndex = 0,
  int order = 0,
  bool alongLine = false,
  double screenAngle = 0,
  TileTransform? transform,
  Map<String, Object?> properties = const {},
  Object? label,
}) =>
    PlacedSymbol(
      // One label per symbol, unless [label] makes several copies of one.
      id: labelIdOf(label ?? (layer, text, icon, at)),
      instance: SymbolInstance(
        layer: layer,
        layerIndex: layerIndex,
        anchor: Offset.zero,
        angle: 0,
        alongLine: alongLine,
        text: text,
        iconName: icon,
        sortKey: 0,
        properties: properties,
        geometryType: 'Point',
        featureId: null,
      ),
      screenAnchor: at,
      screenAngle: screenAngle,
      transform: transform,
      order: order,
    );

/// Paints one placing frame and returns what was drawn, in draw order.
List<PlacedSymbol> _paint(
  List<PlacedSymbol> symbols, {
  LabelPainter? painter,
  SpriteAtlas? sprites,
  int? generation,
}) {
  final own = painter ?? LabelPainter();
  final recorder = ui.PictureRecorder();
  final drawn = own.paint(
    canvas: Canvas(recorder),
    screenSize: _canvas,
    styleZoom: 12,
    symbols: symbols,
    sprites: sprites,
    placementGeneration: generation ?? _generation++,
  );
  recorder.endRecording().dispose();
  if (painter == null) own.dispose();
  return drawn;
}

/// Paints one frame onto a 400×400 image and returns its RGBA bytes.
Future<ByteData> _render(List<PlacedSymbol> symbols,
    {SpriteAtlas? sprites}) async {
  final painter = LabelPainter();
  final recorder = ui.PictureRecorder();
  painter.paint(
    canvas: Canvas(recorder),
    screenSize: _canvas,
    styleZoom: 12,
    symbols: symbols,
    sprites: sprites,
    placementGeneration: _generation++,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(400, 400);
  picture.dispose();
  final bytes = await image.toByteData();
  image.dispose();
  painter.dispose();
  return bytes!;
}

/// Paints one frame with fades on through [painter] at [now] and returns
/// its pixels: the same [generation] at a later [now] replays the last
/// placement pass, with every fade finished.
Future<ByteData> _fadedFrame(LabelPainter painter, List<PlacedSymbol> symbols,
    SpriteAtlas? sprites, int generation, DateTime now) async {
  final recorder = ui.PictureRecorder();
  painter.paint(
    canvas: Canvas(recorder),
    screenSize: _canvas,
    styleZoom: 12,
    symbols: symbols,
    sprites: sprites,
    labelFadeDuration: const Duration(milliseconds: 300),
    placementGeneration: generation,
    now: now,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(400, 400);
  picture.dispose();
  final bytes = await image.toByteData();
  image.dispose();
  return bytes!;
}

/// A sheet holding a red sprite `i` and a blue sprite `b`, 16 px each.
Future<SpriteAtlas> _redAndBlue() async {
  final sheet =
      await _sheet(32, 16, (x, _) => x < 16 ? 0xffff0000 : 0xff0000ff);
  return SpriteAtlas(image: sheet.image, pixelRatio: 1, sprites: {
    'i': const Sprite(x: 0, y: 0, width: 16, height: 16, pixelRatio: 1),
    'b': const Sprite(x: 16, y: 0, width: 16, height: 16, pixelRatio: 1),
  });
}

({int r, int g, int b, int a}) _pixel(ByteData data, int x, int y) {
  final i = (y * 400 + x) * 4;
  return (
    r: data.getUint8(i),
    g: data.getUint8(i + 1),
    b: data.getUint8(i + 2),
    a: data.getUint8(i + 3),
  );
}

/// The x range of pixels in row [y] matching [test], or null.
(int, int)? _span(ByteData data, int y,
    bool Function(({int r, int g, int b, int a}) p) test) {
  int? first, last;
  for (var x = 0; x < 400; x++) {
    if (test(_pixel(data, x, y))) {
      first ??= x;
      last = x;
    }
  }
  return first == null ? null : (first, last!);
}

/// [actual] within a pixel of [expected] at both ends — edge pixels
/// are blended by filtering.
Matcher _about((int, int) expected, {int tolerance = 1}) =>
    predicate<(int, int)?>(
        (actual) =>
            actual != null &&
            (actual.$1 - expected.$1).abs() <= tolerance &&
            (actual.$2 - expected.$2).abs() <= tolerance,
        'within $tolerance px of $expected');

bool _red(({int r, int g, int b, int a}) p) => p.r > 200 && p.g < 60;
bool _blue(({int r, int g, int b, int a}) p) => p.b > 200 && p.r < 60;
bool _black(({int r, int g, int b, int a}) p) =>
    p.a > 200 && p.r < 60 && p.g < 60 && p.b < 60;

/// A sheet of [width]×[height] solid sprites, coloured per column by
/// [colorAt] (ARGB), returned with the atlas built over it.
Future<SpriteAtlas> _sheet(
  int width,
  int height,
  int Function(int x, int y) colorAt, {
  List<(double, double)>? stretchX,
  List<(double, double)>? stretchY,
  Rect? content,
  bool sdf = false,
}) async {
  final pixels = Uint8List(width * height * 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final c = colorAt(x, y);
      final i = (y * width + x) * 4;
      pixels[i] = (c >> 16) & 0xff;
      pixels[i + 1] = (c >> 8) & 0xff;
      pixels[i + 2] = c & 0xff;
      pixels[i + 3] = (c >> 24) & 0xff;
    }
  }
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
      pixels, width, height, ui.PixelFormat.rgba8888, completer.complete);
  final image = await completer.future;
  return SpriteAtlas(
    image: image,
    pixelRatio: 1,
    sprites: {
      'i': Sprite(
        x: 0,
        y: 0,
        width: width.toDouble(),
        height: height.toDouble(),
        pixelRatio: 1,
        sdf: sdf,
        stretchX: stretchX,
        stretchY: stretchY,
        content: content,
      ),
    },
  );
}

Future<SpriteAtlas> _redIcon([int size = 16]) =>
    _sheet(size, size, (_, __) => 0xffff0000);

/// A 16×16 SDF sheet: alpha falls from the centre and crosses the 6/8
/// edge two texels from it (see `sdf_icon_test.dart`).
Future<SpriteAtlas> _sdfIcon() => _sheet(16, 16, (x, y) {
      final d = math.max((x - 7.5).abs(), (y - 7.5).abs());
      final a = ((0.5 + (4 - d) / 8).clamp(0.0, 1.0) * 255).round();
      return a << 24;
    }, sdf: true);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('theme reader', () {
    test('every property defaults to its spec value', () {
      final layer = _layer({'text-field': 'x'});
      const ctx = EvalContext(zoom: 12);
      expect(layer.textJustify.eval(ctx), 'center');
      expect(layer.textLineHeight.eval(ctx), 1.2);
      expect(layer.textRotate.eval(ctx), 0);
      expect(layer.textVariableAnchorOffset, isNull);
      expect(layer.textIgnorePlacement.eval(ctx), isFalse);
      expect(layer.iconIgnorePlacement.eval(ctx), isFalse);
      expect(layer.textOverlap, isNull);
      expect(layer.iconOverlap, isNull);
      expect(layer.iconOptional.eval(ctx), isFalse);
      expect(layer.iconPadding.eval(ctx), [2]);
      expect(layer.iconTextFit.eval(ctx), 'none');
      expect(layer.iconTextFitPadding.eval(ctx), [0, 0, 0, 0]);
      expect(layer.iconKeepUpright.eval(ctx), isFalse);
      expect(layer.symbolZOrder.eval(ctx), 'auto');
      expect(layer.symbolAvoidEdges.eval(ctx), isFalse);
      expect(layer.textHaloBlur.eval(ctx), 0);
      expect(layer.iconHaloBlur.eval(ctx), 0);
      expect(layer.textTranslate.eval(ctx), [0, 0]);
      expect(layer.textTranslateAnchor.eval(ctx), 'map');
      expect(layer.iconTranslate.eval(ctx), [0, 0]);
      expect(layer.iconTranslateAnchor.eval(ctx), 'map');
    });

    test('parses every property', () {
      final layer = _layer({
        'text-field': 'x',
        'text-justify': 'auto',
        'text-line-height': 1.5,
        'text-rotate': 30,
        'text-variable-anchor-offset': [
          'top',
          [0, 1],
          'bottom',
          [0, -1.5],
        ],
        'text-ignore-placement': true,
        'icon-ignore-placement': true,
        'text-overlap': 'cooperative',
        'icon-overlap': 'always',
        'icon-optional': true,
        'icon-padding': [1, 2, 3, 4],
        'icon-text-fit': 'both',
        'icon-text-fit-padding': [1, 2, 3, 4],
        'icon-keep-upright': true,
        'symbol-z-order': 'source',
        'symbol-avoid-edges': true,
      }, paint: {
        'text-halo-blur': 1.5,
        'icon-halo-blur': 2,
        'text-translate': [3, 4],
        'text-translate-anchor': 'viewport',
        'icon-translate': [5, 6],
        'icon-translate-anchor': 'viewport',
      });
      const ctx = EvalContext(zoom: 12);
      expect(layer.textJustify.eval(ctx), 'auto');
      expect(layer.textLineHeight.eval(ctx), 1.5);
      expect(layer.textRotate.eval(ctx), 30);
      expect(layer.textVariableAnchorOffset!.eval(ctx), [
        (anchor: 'top', x: 0.0, y: 1.0),
        (anchor: 'bottom', x: 0.0, y: -1.5),
      ]);
      expect(layer.textIgnorePlacement.eval(ctx), isTrue);
      expect(layer.iconIgnorePlacement.eval(ctx), isTrue);
      expect(layer.textOverlap!.eval(ctx), 'cooperative');
      expect(layer.iconOverlap!.eval(ctx), 'always');
      expect(layer.iconOptional.eval(ctx), isTrue);
      expect(layer.iconPadding.eval(ctx), [1, 2, 3, 4]);
      expect(layer.iconTextFit.eval(ctx), 'both');
      expect(layer.iconTextFitPadding.eval(ctx), [1, 2, 3, 4]);
      expect(layer.iconKeepUpright.eval(ctx), isTrue);
      expect(layer.symbolZOrder.eval(ctx), 'source');
      expect(layer.symbolAvoidEdges.eval(ctx), isTrue);
      expect(layer.textHaloBlur.eval(ctx), 1.5);
      expect(layer.iconHaloBlur.eval(ctx), 2);
      expect(layer.textTranslate.eval(ctx), [3, 4]);
      expect(layer.textTranslateAnchor.eval(ctx), 'viewport');
      expect(layer.iconTranslate.eval(ctx), [5, 6]);
      expect(layer.iconTranslateAnchor.eval(ctx), 'viewport');
    });

    test('icon-padding takes a bare number, literal or computed', () {
      const ctx = EvalContext(zoom: 12);
      expect(_layer({'icon-padding': 5}).iconPadding.eval(ctx), [5]);
      expect(
          _layer({
            'icon-padding': [
              'step',
              ['zoom'],
              1,
              10,
              7,
            ],
          }).iconPadding.eval(ctx),
          [7]);
    });

    test('an interpolated anchor-offset collection interpolates its offsets',
        () {
      final layer = _layer({
        'text-field': 'x',
        'text-variable-anchor-offset': [
          'interpolate',
          ['linear'],
          ['zoom'],
          10,
          [
            'literal',
            [
              'top',
              [0, 1],
            ],
          ],
          14,
          [
            'literal',
            [
              'top',
              [0, 3],
            ],
          ],
        ],
      });
      expect(layer.textVariableAnchorOffset!.eval(const EvalContext(zoom: 12)),
          [(anchor: 'top', x: 0.0, y: 2.0)]);
    });

    test('a malformed anchor-offset collection evaluates to null', () {
      expect(AnchorOffsetsProp.parse(['top']), isNull);
      expect(
          AnchorOffsetsProp.parse([
            'top',
            [0],
          ]),
          isNull);
      expect(
          AnchorOffsetsProp.parse([
            1,
            [0, 0],
          ]),
          isNull);
    });

    test('text-writing-mode is reported as unsupported, the layer kept', () {
      final logged = <String>[];
      final layer = _layer({
        'text-field': 'x',
        'text-writing-mode': ['vertical'],
      }, logger: Logger.custom(onLog: logged.add));
      expect(layer.textField.eval(const EvalContext(zoom: 12)), 'x');
      expect(logged.single, contains('text-writing-mode'));
    });

    test('sprite index parses stretch zones and the content box', () {
      final sprites = SpriteAtlas.parseIndex({
        'shield': {
          'x': 0,
          'y': 0,
          'width': 20,
          'height': 16,
          'stretchX': [
            [4, 8],
            [12, 16],
          ],
          'stretchY': [
            [4, 12],
          ],
          'content': [4, 4, 16, 12],
        },
        'bad': {
          'x': 0,
          'y': 0,
          'width': 4,
          'height': 4,
          'stretchX': [
            [3, 1],
          ],
          'content': [0, 0, 1],
        },
      });
      final shield = sprites['shield']!;
      expect(shield.stretchX, [(4.0, 8.0), (12.0, 16.0)]);
      expect(shield.stretchY, [(4.0, 12.0)]);
      expect(shield.content, const Rect.fromLTRB(4, 4, 16, 12));
      expect(sprites['bad']!.stretchX, isNull);
      expect(sprites['bad']!.content, isNull);
    });
  });

  group('halo blur', () {
    // Partly transparent pixels across a row through the glyphs: a crisp
    // halo has a pixel or two of antialiasing per edge, a blurred one a
    // ramp several pixels wide.
    int softPixels(ByteData data) {
      var n = 0;
      for (var x = 0; x < 400; x++) {
        final a = _pixel(data, x, 200).a;
        if (a > 10 && a < 245) n++;
      }
      return n;
    }

    test('text-halo-blur softens the halo edge', () async {
      Future<ByteData> render(double blur) => _render([
            _symbol(
                _layer({
                  'text-field': 'x',
                  'text-size': 32,
                }, paint: {
                  'text-color': 'rgba(0,0,0,0)',
                  'text-halo-color': '#000000',
                  'text-halo-width': 4,
                  'text-halo-blur': blur,
                }),
                const Offset(200, 200),
                text: 'HH'),
          ]);
      final crisp = softPixels(await render(0));
      final blurred = softPixels(await render(4));
      expect(crisp, lessThanOrEqualTo(8));
      expect(blurred, greaterThan(crisp + 8));
    });

    test('a blurred halo draws the same on every frame', () async {
      final layer = _layer({
        'text-field': 'x',
        'text-size': 24
      }, paint: {
        'text-halo-color': '#ff0000',
        'text-halo-width': 2,
        'text-halo-blur': 2,
      });
      final painter = LabelPainter();
      addTearDown(painter.dispose);
      Future<Uint8List> frame() async {
        final recorder = ui.PictureRecorder();
        painter.paint(
          canvas: Canvas(recorder),
          screenSize: _canvas,
          styleZoom: 12,
          symbols: [_symbol(layer, const Offset(200, 200), text: 'Halo')],
          placementGeneration: _generation++,
        );
        final picture = recorder.endRecording();
        final image = await picture.toImage(400, 400);
        picture.dispose();
        final bytes = await image.toByteData();
        image.dispose();
        return bytes!.buffer.asUint8List();
      }

      final first = await frame();
      expect(await frame(), first);
    });

    test('icon-halo-blur widens the SDF halo ramp', () async {
      final atlas = await _sdfIcon();
      addTearDown(atlas.dispose);
      Future<ByteData> render(double blur) => _render([
            _symbol(
                _layer({
                  'icon-image': 'i',
                  'icon-size': 8
                }, paint: {
                  'icon-color': 'rgba(0,0,0,0)',
                  'icon-halo-color': '#000000',
                  'icon-halo-width': 8,
                  'icon-halo-blur': blur,
                }),
                const Offset(200, 200),
                icon: 'i'),
          ], sprites: atlas);
      final crisp = softPixels(await render(0));
      final blurred = softPixels(await render(6));
      expect(blurred, greaterThan(crisp + 8));
    });
  });

  group('collision', () {
    late SpriteAtlas icon;
    setUpAll(() async => icon = await _redIcon());
    tearDownAll(() => icon.dispose());

    test('icon-optional keeps the text when only its icon collides', () {
      // A blocker icon over the anchor; the text hangs well below it.
      final blocker = _symbol(
          _layer({'icon-image': 'i'}), const Offset(200, 200),
          icon: 'i', layerIndex: 1);
      SymbolThemeLayer poi(bool optional) => _layer({
            'text-field': 'x',
            'icon-image': 'i',
            'text-offset': [0, 3],
            'icon-optional': optional,
          });

      final strict =
          _symbol(poi(false), const Offset(200, 200), text: 'Poi', icon: 'i');
      expect(_paint([blocker, strict], sprites: icon), [blocker]);

      final painter = LabelPainter();
      addTearDown(painter.dispose);
      final optional =
          _symbol(poi(true), const Offset(200, 200), text: 'Poi', icon: 'i');
      final drawn =
          _paint([blocker, optional], painter: painter, sprites: icon);
      expect(drawn, unorderedEquals([blocker, optional]));
      final sitting = painter.debugPlacement.lookup(optional.id)!;
      expect(sitting.iconDropped, isTrue);
      expect(sitting.textDropped, isFalse);
    });

    test('a dropped icon stays dropped on replay frames', () async {
      // Blocker blue, the POI's icon red and twice its size, both over
      // the anchor: a replay collides nothing, so only the remembered
      // drop keeps red from showing around the blocker.
      final sheet =
          await _sheet(32, 16, (x, _) => x < 16 ? 0xffff0000 : 0xff0000ff);
      addTearDown(sheet.dispose);
      final atlas = SpriteAtlas(image: sheet.image, pixelRatio: 1, sprites: {
        'i': const Sprite(x: 0, y: 0, width: 16, height: 16, pixelRatio: 1),
        'b': const Sprite(x: 16, y: 0, width: 16, height: 16, pixelRatio: 1),
      });
      final blocker = _symbol(
          _layer({'icon-image': 'b'}), const Offset(200, 200),
          icon: 'b', layerIndex: 1);
      final poiLayer = _layer({
        'text-field': 'x',
        'icon-image': 'i',
        'icon-size': 2,
        'text-offset': [0, 3],
        'icon-optional': true,
      });
      final poi = _symbol(poiLayer, const Offset(200, 200),
          text: 'Poi', icon: 'i', order: 1, label: poiLayer);
      // A second copy of the same label at the same sitting (the other
      // level of a zoom crossing), which loses to the first: it must not
      // wipe what the winner's pass decided.
      final copy = _symbol(poiLayer, const Offset(202, 200),
          text: 'Poi', icon: 'i', order: 2, label: poiLayer);
      final painter = LabelPainter();
      addTearDown(painter.dispose);
      Future<ByteData> frame(int generation, DateTime now) async {
        final recorder = ui.PictureRecorder();
        painter.paint(
          canvas: Canvas(recorder),
          screenSize: _canvas,
          styleZoom: 12,
          symbols: [blocker, poi, copy],
          sprites: atlas,
          labelFadeDuration: const Duration(milliseconds: 300),
          placementGeneration: generation,
          now: now,
        );
        final picture = recorder.endRecording();
        final image = await picture.toImage(400, 400);
        picture.dispose();
        final bytes = await image.toByteData();
        image.dispose();
        return bytes!;
      }

      final generation = _generation++;
      final start = DateTime(2026);
      await frame(generation, start);
      // The same generation a second later: a replay, every fade done.
      final replay =
          await frame(generation, start.add(const Duration(seconds: 1)));
      expect(_pixel(replay, 212, 200).r, 0, reason: 'no red icon');
      expect(_blue(_pixel(replay, 200, 200)), isTrue, reason: 'blocker');
      expect(_span(replay, 248, _black), isNotNull, reason: 'text drawn');
    });

    test('a label placed at one variable anchor is not drawn again at another',
        () {
      // Two copies of one POI at one sitting: the first takes "top", and
      // the second, whose text collides there, must not take "bottom".
      final layer = _layer({
        'text-field': 'x',
        'text-size': 14,
        'icon-image': 'i',
        'icon-optional': true,
        'text-variable-anchor': ['top', 'bottom'],
        'text-radial-offset': 1.5,
      });
      final drawn = _paint([
        _symbol(layer, const Offset(200, 200),
            text: 'Poi', icon: 'i', order: 0, label: layer),
        _symbol(layer, const Offset(201, 200),
            text: 'Poi', icon: 'i', order: 1, label: layer),
      ], sprites: icon);
      expect(drawn, hasLength(1));
    });

    test('a fitted icon whose text was dropped stays fitted on replay',
        () async {
      // The text's padded box reaches the blocker, the fitted icon's box
      // does not: the pass keeps the icon alone, fitted to the text.
      final atlas = await _redAndBlue();
      addTearDown(atlas.dispose);
      final blocker = _symbol(
          _layer({'icon-image': 'b'}), const Offset(250, 200),
          icon: 'b', layerIndex: 1);
      final shield = _symbol(
          _layer({
            'text-field': 'x',
            'text-size': 20,
            'text-padding': 24,
            'text-optional': true,
            'icon-image': 'i',
            'icon-padding': 0,
            'icon-text-fit': 'both',
          }, paint: {
            'text-color': 'rgba(0,0,0,0)',
          }),
          const Offset(200, 200),
          text: 'WW',
          icon: 'i');
      final painter = LabelPainter();
      addTearDown(painter.dispose);
      final generation = _generation++;
      final start = DateTime(2026);
      await _fadedFrame(painter, [blocker, shield], atlas, generation, start);
      final replay = await _fadedFrame(painter, [blocker, shield], atlas,
          generation, start.add(const Duration(seconds: 1)));
      // "WW" is 40 × 24 around (200, 200).
      expect(_span(replay, 200, _red), _about((180, 219)));
    });

    test('icon-padding widens the space an icon claims', () {
      // 16 px icons 20 px apart: the default 2 px padding leaves them
      // touching, 3 px makes them overlap.
      List<PlacedSymbol> place(Object padding) {
        final layer = _layer({'icon-image': 'i', 'icon-padding': padding});
        return _paint([
          _symbol(layer, const Offset(100, 100), icon: 'i', order: 0),
          _symbol(layer, const Offset(120, 100), icon: 'i', order: 1),
        ], sprites: icon);
      }

      expect(place(2), hasLength(2));
      expect(place(3), hasLength(1));
      expect(place([0, 5, 0, 0]), hasLength(1), reason: 'right padding only');
      expect(place([3, 0, 3, 0]), hasLength(2), reason: 'vertical only');
    });

    test('text-ignore-placement lets later labels overlap', () {
      List<PlacedSymbol> place(bool ignore) {
        final layer =
            _layer({'text-field': 'x', 'text-ignore-placement': ignore});
        return _paint([
          _symbol(layer, const Offset(200, 200), text: 'Alpha', order: 0),
          _symbol(layer, const Offset(200, 200), text: 'Beta', order: 1),
        ]);
      }

      expect(place(false), hasLength(1));
      expect(place(true), hasLength(2));
    });

    test('a symbol allowed to overlap still reserves its space', () {
      // MapLibre inserts allow-overlap boxes: the overlapping symbol may
      // be drawn over others, but a later one that may not overlap
      // keeps clear of it.
      final top = _symbol(
          _layer({'text-field': 'x', 'text-allow-overlap': true}),
          const Offset(200, 200),
          text: 'Top',
          layerIndex: 1);
      final below = _symbol(_layer({'text-field': 'x'}), const Offset(200, 200),
          text: 'Below');
      expect(_paint([top, below]), [top]);
    });

    test('text-overlap overrides text-allow-overlap', () {
      List<PlacedSymbol> place(String overlap, bool allow) {
        final layer = _layer({
          'text-field': 'x',
          'text-overlap': overlap,
          'text-allow-overlap': allow,
        });
        return _paint([
          _symbol(layer, const Offset(200, 200), text: 'Alpha', order: 0),
          _symbol(layer, const Offset(200, 200), text: 'Beta', order: 1),
        ]);
      }

      expect(place('always', false), hasLength(2));
      expect(place('never', true), hasLength(1));
    });

    test('a data-driven overlap mode is read per feature', () {
      // Placement properties that read no feature data are resolved once
      // per layer; one that does must still differ between features.
      final layer = _layer({
        'text-field': 'x',
        'text-overlap': ['get', 'overlap'],
      });
      PlacedSymbol label(String text, int order, String overlap) =>
          _symbol(layer, const Offset(200, 200),
              text: text, order: order, properties: {'overlap': overlap});
      final drawn = _paint([
        label('Alpha', 0, 'never'),
        label('Beta', 1, 'always'),
        label('Gamma', 2, 'never'),
      ]);
      expect(drawn.map((s) => s.instance.text),
          unorderedEquals(['Alpha', 'Beta']));
    });

    test('cooperative symbols overlap each other but not never-symbols', () {
      List<PlacedSymbol> place(String topMode) {
        final top = _symbol(
            _layer({'text-field': 'x', 'text-overlap': topMode}),
            const Offset(200, 200),
            text: 'Top',
            layerIndex: 1);
        final below = _symbol(
            _layer({'text-field': 'x', 'text-overlap': 'cooperative'}),
            const Offset(200, 200),
            text: 'Below');
        return _paint([top, below]);
      }

      expect(place('never'), hasLength(1));
      expect(place('cooperative'), hasLength(2));
      expect(place('always'), hasLength(2));
    });

    test('symbol-avoid-edges drops a label crossing its tile edge', () {
      // The tile covers (0,0)–(256,256) on screen; "WWWW" at 16 px is
      // 64 px wide, so centred at x 240 it crosses the right edge.
      final tile = TileTransform(origin: Offset.zero, scale: 1, rotation: 0);
      List<PlacedSymbol> place(bool avoid, double x) => _paint([
            _symbol(_layer({'text-field': 'x', 'symbol-avoid-edges': avoid}),
                Offset(x, 100),
                text: 'WWWW', transform: tile),
          ]);

      expect(place(false, 240), hasLength(1));
      expect(place(true, 240), isEmpty);
      expect(place(true, 200), hasLength(1));
    });
  });

  group('icon-text-fit', () {
    // "WWWW" at 20 px: 80 × 24 (line height 1.2), centred on (200, 200).
    PlacedSymbol shield(String fit,
            {List<num>? padding, Map<String, Object?> paint = const {}}) =>
        _symbol(
            _layer({
              'text-field': 'x',
              'text-size': 20,
              'icon-image': 'i',
              'icon-text-fit': fit,
              if (padding != null) 'icon-text-fit-padding': padding,
            }, paint: {
              'text-color': 'rgba(0,0,0,0)',
              ...paint,
            }),
            const Offset(200, 200),
            text: 'WWWW',
            icon: 'i');

    test('both: the icon spans the text plus its padding', () async {
      final atlas = await _redIcon();
      addTearDown(atlas.dispose);
      final data = await _render([
        shield('both', padding: [2, 4, 6, 8])
      ], sprites: atlas);
      // Text box 160..240 × 188..212; padding top 2, right 4, bottom 6,
      // left 8.
      expect(_span(data, 200, _red), _about((152, 243)));
      final column = [
        for (var y = 0; y < 400; y++)
          if (_red(_pixel(data, 200, y))) y,
      ];
      expect((column.first, column.last), _about((186, 217)));
    });

    test('width: only the width is fitted, the height stays the icon\'s',
        () async {
      final atlas = await _redIcon();
      addTearDown(atlas.dispose);
      final data = await _render([shield('width')], sprites: atlas);
      expect(_span(data, 200, _red), _about((160, 239)));
      final column = [
        for (var y = 0; y < 400; y++)
          if (_red(_pixel(data, 200, y))) y,
      ];
      expect((column.first, column.last), _about((192, 207)));
    });

    test('an axis not fitted centres on the text, padding aside', () async {
      final atlas = await _redIcon();
      addTearDown(atlas.dispose);
      final data = await _render([
        shield('width', padding: [0, 4, 10, 4]),
      ], sprites: atlas);
      expect(_span(data, 200, _red), _about((156, 243)));
      final column = [
        for (var y = 0; y < 400; y++)
          if (_red(_pixel(data, 200, y))) y,
      ];
      expect((column.first, column.last), _about((192, 207)));
    });

    test('a fitted icon moves with icon-translate, not text-translate',
        () async {
      final atlas = await _redIcon();
      addTearDown(atlas.dispose);
      final data = await _render([
        shield('both', paint: {
          'icon-translate': [0, 40],
          'text-translate': [0, -40],
        }),
      ], sprites: atlas);
      final column = [
        for (var y = 0; y < 400; y++)
          if (_red(_pixel(data, 200, y))) y,
      ];
      expect((column.first, column.last), _about((228, 251)));
    });

    test('stretch zones stretch, the other pixels keep their size', () async {
      // Blue 4 px borders around an 8 px red stretch zone.
      final atlas = await _sheet(
          16, 16, (x, _) => x >= 4 && x < 12 ? 0xffff0000 : 0xff0000ff,
          stretchX: [(4, 12)]);
      addTearDown(atlas.dispose);
      final data = await _render([shield('width')], sprites: atlas);
      expect(_span(data, 200, _blue), _about((160, 239)));
      // Bilinear filtering blends a few pixels across each seam between
      // slices, as it does in MapLibre.
      expect(_span(data, 200, _red), _about((164, 235), tolerance: 4));
    });

    test('a stretched icon has no seams between its slices', () async {
      // A solid sprite stretched on both axes, its slice boundaries on
      // fractional pixels: drawn slice by slice, each slice's
      // antialiased edge let the background through along the seams.
      final atlas = await _sheet(16, 16, (_, __) => 0xffff0000,
          stretchX: [(4, 12)], stretchY: [(4, 12)]);
      addTearDown(atlas.dispose);
      final layer = _layer({
        'text-field': 'x',
        'text-size': 20,
        'icon-image': 'i',
        'icon-text-fit': 'both',
        'icon-text-fit-padding': [3.3, 3.3, 3.3, 3.3],
      }, paint: {
        'text-color': 'rgba(0,0,0,0)',
      });
      final data = await _render([
        _symbol(layer, const Offset(200.4, 200.4), text: 'WWWW', icon: 'i'),
      ], sprites: atlas);
      bool solid(int x, int y) {
        final p = _pixel(data, x, y);
        return p.a == 255 && p.r > 250 && p.g < 5 && p.b < 5;
      }

      // The icon spans about 157..244 × 185..216; one pixel in from its
      // edges, every pixel is the sprite's own colour.
      final notSolid = [
        for (var x = 159; x <= 241; x++)
          for (final y in const [190, 200, 210])
            if (!solid(x, y)) (x, y),
        for (var y = 188; y <= 213; y++)
          for (final x in const [165, 200, 235])
            if (!solid(x, y)) (x, y),
      ];
      expect(notSolid, isEmpty);
    });

    test('the content box is what fits the text', () async {
      // Content is the red middle; the blue frame stays outside it.
      final atlas = await _sheet(
          16, 16, (x, _) => x >= 4 && x < 12 ? 0xffff0000 : 0xff0000ff,
          stretchX: [(4, 12)], content: const Rect.fromLTRB(4, 0, 12, 16));
      addTearDown(atlas.dispose);
      final data = await _render([shield('width')], sprites: atlas);
      expect(_span(data, 200, _red), _about((160, 239), tolerance: 4));
      expect(_span(data, 200, _blue), _about((156, 243)));
    });
  });

  group('text layout', () {
    // Two lines at 20 px: "WWWWW" (100 px) over "W" (20 px), anchored at
    // (200, 200): the box spans 150..250, the second line 200..224.
    Future<(int, int)?> secondLine(Map<String, Object?> layout) async {
      final data = await _render([
        _symbol(
            _layer({
              'text-field': 'x',
              'text-size': 20,
              ...layout,
            }),
            const Offset(200, 200),
            text: 'WWWWW\nW'),
      ]);
      return _span(data, 212, _black);
    }

    test('text-justify aligns the lines', () async {
      expect(await secondLine({}), (190, 209));
      expect(await secondLine({'text-justify': 'left'}), (150, 169));
      expect(await secondLine({'text-justify': 'right'}), (230, 249));
    });

    test('text-justify auto follows the anchor', () async {
      // Anchored left: the box starts at the anchor, lines flush left.
      expect(await secondLine({'text-justify': 'auto', 'text-anchor': 'left'}),
          (200, 219));
      expect(await secondLine({'text-justify': 'auto', 'text-anchor': 'right'}),
          (180, 199));
    });

    test('text-justify auto follows the variable anchor a label takes',
        () async {
      // Only "right" is offered: the box ends at the anchor.
      expect(
          await secondLine({
            'text-justify': 'auto',
            'text-variable-anchor': ['right'],
          }),
          (180, 199));
    });

    test('text-justify auto shapes single-line text once, whatever the side',
        () {
      // Only "right" is free: a blocker covers "left". Single-line text
      // looks the same aligned to either side, so moving it there must
      // not shape it again inside the frame.
      final layer = _layer({
        'text-field': 'x',
        'text-size': 14,
        'text-justify': 'auto',
        'text-variable-anchor': ['left', 'right'],
      });
      final label = _symbol(layer, const Offset(200, 200), text: 'Single');
      final blocker = _symbol(
          _layer({'text-field': 'x', 'text-size': 14}), const Offset(290, 200),
          text: 'Blocker', layerIndex: 1);
      final painter = LabelPainter();
      addTearDown(painter.dispose);
      final justified = LabelPainter.debugJustifiedLayouts;
      painter.prewarm([label.instance, blocker.instance], 12);
      final shaped = painter.debugShapedTextCount;
      expect(_paint([blocker, label], painter: painter), hasLength(2));
      expect(painter.debugPlacement.lookup(label.id)!.anchor, 'right');
      expect(painter.debugShapedTextCount, shaped);
      expect(LabelPainter.debugJustifiedLayouts, justified);
    });

    test('text-justify auto lays multi-line text out per side in prewarm', () {
      final layer = _layer({
        'text-field': 'x',
        'text-size': 14,
        'text-justify': 'auto',
        'text-variable-anchor': ['left', 'right'],
      });
      final label = _symbol(layer, const Offset(200, 200), text: 'Two\nlines');
      final painter = LabelPainter();
      addTearDown(painter.dispose);
      final before = LabelPainter.debugJustifiedLayouts;
      painter.prewarm([label.instance], 12);
      expect(LabelPainter.debugJustifiedLayouts, before + 2);
      expect(_paint([label], painter: painter), hasLength(1));
      expect(LabelPainter.debugJustifiedLayouts, before + 2,
          reason: 'nothing laid out inside the frame');
    });

    test('text-line-height sets the line pitch and the box height', () {
      // A two-line label over a one-line one 50 px below: with the
      // default 1.2 em the boxes are clear of each other, with 2 em the
      // label reaches down to 240 and collides.
      List<PlacedSymbol> place(double lineHeight) => _paint([
            _symbol(
                _layer({
                  'text-field': 'x',
                  'text-size': 20,
                  'text-line-height': lineHeight,
                }),
                const Offset(200, 200),
                text: 'Two\nLines',
                layerIndex: 1),
            _symbol(_layer({'text-field': 'x', 'text-size': 20}),
                const Offset(200, 250),
                text: 'One'),
          ]);

      expect(place(1.2), hasLength(2));
      expect(place(2), hasLength(1));
    });
  });

  group('anchors and offsets', () {
    test('text-variable-anchor-offset applies each anchor\'s own offset',
        () async {
      // Anchor "top" with a 2 em offset down: the box starts 40 px below
      // the anchor.
      final data = await _render([
        _symbol(
            _layer({
              'text-field': 'x',
              'text-size': 20,
              'text-variable-anchor-offset': [
                'top',
                [0, 2],
              ],
            }),
            const Offset(200, 100),
            text: 'W'),
      ]);
      final column = [
        for (var y = 0; y < 400; y++)
          if (_black(_pixel(data, 200, y))) y,
      ];
      expect(column.first, inInclusiveRange(140, 144));
    });

    test('text-variable-anchor-offset falls through to the next anchor', () {
      final painter = LabelPainter();
      addTearDown(painter.dispose);
      final blocker = _symbol(
          _layer({'text-field': 'x', 'text-size': 20}), const Offset(230, 200),
          text: 'WW', layerIndex: 1);
      final label = _symbol(
          _layer({
            'text-field': 'x',
            'text-size': 20,
            'text-variable-anchor-offset': [
              'left',
              [1, 0],
              'right',
              [-1, 0],
            ],
          }),
          const Offset(200, 200),
          text: 'WW');
      expect(_paint([blocker, label], painter: painter), hasLength(2));
      expect(painter.debugPlacement.lookup(label.id)!.anchor, 'right');
    });

    test('text-offset with variable anchors points away from each anchor',
        () async {
      // MapLibre takes the offset's magnitude: -2 em still moves a
      // "top"-anchored box down, away from the anchor.
      final data = await _render([
        _symbol(
            _layer({
              'text-field': 'x',
              'text-size': 20,
              'text-variable-anchor': ['top'],
              'text-offset': [0, -2],
            }),
            const Offset(200, 100),
            text: 'W'),
      ]);
      final column = [
        for (var y = 0; y < 400; y++)
          if (_black(_pixel(data, 200, y))) y,
      ];
      expect(column.first, inInclusiveRange(140, 144));
    });

    test('text-rotate turns the label and its collision box', () {
      // "WWWWW" is 100 × 24; a neighbour 40 px to the right overlaps it
      // unless it is turned upright.
      List<PlacedSymbol> place(double rotate) => _paint([
            _symbol(
                _layer({
                  'text-field': 'x',
                  'text-size': 20,
                  'text-rotate': rotate,
                }),
                const Offset(200, 200),
                text: 'WWWWW',
                layerIndex: 1),
            _symbol(_layer({'text-field': 'x', 'text-size': 20}),
                const Offset(240, 200),
                text: 'W'),
          ]);

      expect(place(0), hasLength(1));
      expect(place(90), hasLength(2));
    });

    test('map-aligned point text turns with the map', () async {
      final data = await _render([
        _symbol(
            _layer({
              'text-field': 'x',
              'text-size': 20,
              'text-rotation-alignment': 'map',
            }),
            const Offset(200, 200),
            text: 'WWWWW',
            screenAngle: math.pi / 2),
      ]);
      // Turned upright: a column one line wide and 100 px tall.
      final (left, right) = _span(data, 200, _black)!;
      expect(right - left, inInclusiveRange(17, 24));
      expect(_span(data, 160, _black), isNotNull);
    });

    test('text-translate moves the text, turned with the map by default',
        () async {
      Future<(int, int)?> row(String anchor) async => _span(
          await _render([
            _symbol(
                _layer({
                  'text-field': 'x',
                  'text-size': 20
                }, paint: {
                  'text-translate': [0, 30],
                  'text-translate-anchor': anchor,
                }),
                const Offset(200, 200),
                text: 'W',
                screenAngle: math.pi / 2),
          ]),
          200,
          _black);
      // The map is turned a quarter: "down" on the map is screen left.
      expect(await row('map'), (160, 179));
      expect(await row('viewport'), isNull, reason: 'moved below row 200');
    });

    test('a data-driven translate moves each feature its own way', () async {
      final layer = _layer({
        'text-field': 'x',
        'text-size': 20
      }, paint: {
        'text-translate': ['get', 'shift'],
      });
      final data = await _render([
        _symbol(layer, const Offset(100, 200), text: 'W', properties: {
          'shift': [0, 0]
        }),
        _symbol(layer, const Offset(300, 200), text: 'W', properties: {
          'shift': [0, 30]
        }),
      ]);
      expect(_span(data, 200, _black), (90, 109));
      expect(_span(data, 230, _black), (290, 309));
    });

    test('icon-translate moves the icon', () async {
      final atlas = await _redIcon();
      addTearDown(atlas.dispose);
      final data = await _render([
        _symbol(
            _layer({
              'icon-image': 'i'
            }, paint: {
              'icon-translate': [50, 0],
            }),
            const Offset(200, 200),
            icon: 'i'),
      ], sprites: atlas);
      expect(_span(data, 200, _red), _about((242, 257)));
    });

    test('icon-keep-upright turns a backwards line icon around', () async {
      // Red left half, blue right: drawn along a line pointing left, the
      // icon comes out mirrored unless kept upright.
      final atlas =
          await _sheet(16, 16, (x, _) => x < 8 ? 0xffff0000 : 0xff0000ff);
      addTearDown(atlas.dispose);
      Future<bool> redOnLeft(bool upright) async {
        final data = await _render([
          _symbol(
              _layer({
                'icon-image': 'i',
                'symbol-placement': 'line',
                'icon-keep-upright': upright,
              }),
              const Offset(200, 200),
              icon: 'i',
              alongLine: true,
              screenAngle: math.pi),
        ], sprites: atlas);
        return _red(_pixel(data, 194, 200));
      }

      expect(await redOnLeft(false), isFalse);
      expect(await redOnLeft(true), isTrue);
    });
  });

  test('LabelMode.tile draws the new properties through paintTile', () async {
    final atlas = await _redIcon();
    addTearDown(atlas.dispose);
    final layer = _layer({
      'text-field': 'x',
      'text-size': 20,
      'icon-image': 'i',
      'icon-text-fit': 'both',
      'icon-text-fit-padding': [2, 2, 2, 2],
      'text-justify': 'left',
      'icon-optional': true,
    }, paint: {
      'text-halo-color': '#ffffff',
      'text-halo-width': 1,
      'text-halo-blur': 1,
    });
    final painter = LabelPainter();
    addTearDown(painter.dispose);
    final recorder = ui.PictureRecorder();
    final drawn = painter.paintTile(
      canvas: Canvas(recorder),
      symbols: [
        SymbolInstance(
          layer: layer,
          layerIndex: 0,
          anchor: const Offset(128, 128),
          angle: 0,
          alongLine: false,
          text: 'WW',
          iconName: 'i',
          sortKey: 0,
          properties: const {},
          geometryType: 'Point',
          featureId: null,
        ),
      ],
      styleZoom: 12,
      sprites: atlas,
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(256, 256);
    picture.dispose();
    final bytes = (await image.toByteData())!;
    image.dispose();
    expect(drawn, hasLength(1));
    // "WW" spans 108..148; the red shield 2 px beyond it on each side.
    int red(int x) => bytes.getUint8((128 * 256 + x) * 4);
    expect(red(107), greaterThan(200));
    expect(red(148), greaterThan(200));
    expect(red(102), lessThan(50));
  });

  group('symbol-z-order', () {
    late SpriteAtlas icon;
    setUpAll(() async => icon = await _redIcon());
    tearDownAll(() => icon.dispose());

    List<PlacedSymbol> drawOrder(String zOrder) {
      final layer = _layer({
        'icon-image': 'i',
        'icon-allow-overlap': true,
        'symbol-z-order': zOrder,
      });
      // Source order puts the lower one first.
      return _paint([
        _symbol(layer, const Offset(200, 210), icon: 'i', order: 0),
        _symbol(layer, const Offset(200, 200), icon: 'i', order: 1),
      ], sprites: icon);
    }

    test('overlapping symbols draw lower ones on top by default', () {
      expect(drawOrder('auto').map((s) => s.order), [1, 0]);
      expect(drawOrder('viewport-y').map((s) => s.order), [1, 0]);
    });

    test('source keeps the source order', () {
      expect(drawOrder('source').map((s) => s.order), [0, 1]);
    });
  });
}
