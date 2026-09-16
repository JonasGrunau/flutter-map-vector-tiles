import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_map_vector_tiles/src/render/label_painter.dart';
import 'package:flutter_map_vector_tiles/src/render/symbol_layouter.dart';
import 'package:flutter_map_vector_tiles/src/style/expression.dart';
import 'package:flutter_map_vector_tiles/src/style/sprite_atlas.dart';
import 'package:flutter_map_vector_tiles/src/style/theme.dart';
import 'package:flutter_map_vector_tiles/src/style/theme_reader.dart';
import 'package:flutter_test/flutter_test.dart';

const _atlasSize = 16;
const _canvasSize = 64;
const _canvasBox = Size(64, 64);

/// A 16x16 non-SDF sprite shaped like `oneway`: solid red on rows 0-6
/// ("up" in the sprite's own frame), transparent rows 7-8 as a buffer so
/// a rotated sample near the centre never straddles the seam, solid blue
/// on rows 9-15. Rotation direction is read off by asking which colour
/// ends up on which side of the icon's centre.
Future<ui.Image> _splitSheet() {
  final pixels = Uint8List(_atlasSize * _atlasSize * 4);
  for (var y = 0; y < _atlasSize; y++) {
    for (var x = 0; x < _atlasSize; x++) {
      final i = (y * _atlasSize + x) * 4;
      if (y <= 6) {
        pixels[i] = 255; // red
        pixels[i + 3] = 255;
      } else if (y >= 9) {
        pixels[i + 2] = 255; // blue
        pixels[i + 3] = 255;
      }
    }
  }
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(pixels, _atlasSize, _atlasSize,
      ui.PixelFormat.rgba8888, completer.complete);
  return completer.future;
}

Future<ui.Image> _solidSheet(int width, int height) {
  final pixels = Uint8List(width * height * 4);
  for (var i = 0; i < pixels.length; i += 4) {
    pixels[i] = 255;
    pixels[i + 3] = 255;
  }
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
      pixels, width, height, ui.PixelFormat.rgba8888, completer.complete);
  return completer.future;
}

SpriteAtlas _atlas(ui.Image image) => SpriteAtlas(
      image: image,
      pixelRatio: 1,
      sprites: {
        'arrow': Sprite(
          x: 0,
          y: 0,
          width: _atlasSize.toDouble(),
          height: _atlasSize.toDouble(),
          pixelRatio: 1,
          sdf: false,
        ),
      },
    );

SymbolThemeLayer _arrowLayer({
  double iconRotate = 0,
  String iconRotationAlignment = 'auto',
  List<double> iconOffset = const [0, 0],
  String iconAnchor = 'center',
}) {
  final theme = const ThemeReader().read({
    'layers': [
      {
        'id': 'road_oneway',
        'type': 'symbol',
        'source': 's',
        'source-layer': 'transportation',
        'layout': {
          'icon-image': 'arrow',
          'icon-size': 1,
          'icon-rotate': iconRotate,
          'icon-rotation-alignment': iconRotationAlignment,
          'icon-offset': iconOffset,
          'icon-anchor': iconAnchor,
        },
      },
    ],
  });
  return theme.layers.single as SymbolThemeLayer;
}

PlacedSymbol _arrowSymbol(SymbolThemeLayer layer,
        {required bool alongLine,
        required double screenAngle,
        Offset screenAnchor = const Offset(32, 32)}) =>
    PlacedSymbol(
      instance: SymbolInstance(
        layer: layer,
        layerIndex: 0,
        anchor: Offset.zero,
        angle: 0,
        alongLine: alongLine,
        text: '',
        iconName: 'arrow',
        sortKey: 0,
        properties: const {},
        geometryType: alongLine ? 'LineString' : 'Point',
        featureId: null,
      ),
      // Centred, so the 16x16 sprite lands on (24,24)-(40,40) and rect.center
      // is exactly (32,32) — rotation has no sub-pixel remainder to blur.
      screenAnchor: screenAnchor,
      screenAngle: screenAngle,
    );

Future<ByteData> _render(SymbolThemeLayer layer, PlacedSymbol symbol) async {
  final atlas = _atlas(await _splitSheet());
  final painter = LabelPainter();
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  painter.paint(
    canvas: canvas,
    screenSize: _canvasBox,
    styleZoom: 16,
    symbols: [symbol],
    sprites: atlas,
    placementGeneration: 0,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(_canvasSize, _canvasSize);
  picture.dispose();
  final bytes = await image.toByteData();
  image.dispose();
  painter.dispose();
  atlas.image.dispose();
  return bytes!;
}

Future<int> _rotatedCollisionCount() async {
  final image = await _solidSheet(24, 4);
  final atlas = SpriteAtlas(
    image: image,
    pixelRatio: 1,
    sprites: const {
      'wide': Sprite(
        x: 0,
        y: 0,
        width: 24,
        height: 4,
        pixelRatio: 1,
        sdf: false,
      ),
    },
  );
  final theme = const ThemeReader().read({
    'layers': [
      {
        'id': 'wide-icons',
        'type': 'symbol',
        'source': 's',
        'source-layer': 'poi',
        'layout': {
          'icon-image': 'wide',
          'icon-rotate': ['get', 'rotation'],
          'icon-rotation-alignment': 'viewport',
        },
      },
    ],
  });
  final layer = theme.layers.single as SymbolThemeLayer;
  PlacedSymbol symbol(Offset anchor, double rotation) => PlacedSymbol(
        instance: SymbolInstance(
          layer: layer,
          layerIndex: 0,
          anchor: Offset.zero,
          angle: 0,
          alongLine: false,
          text: '',
          iconName: 'wide',
          sortKey: 0,
          properties: {'rotation': rotation},
          geometryType: 'Point',
          featureId: null,
        ),
        screenAnchor: anchor,
        screenAngle: 0,
      );

  final painter = LabelPainter();
  final recorder = ui.PictureRecorder();
  final drawn = painter.paint(
    canvas: Canvas(recorder),
    screenSize: _canvasBox,
    styleZoom: 16,
    symbols: [
      symbol(const Offset(32, 24), 90),
      symbol(const Offset(32, 40), 0),
    ],
    sprites: atlas,
    placementGeneration: 0,
  );
  recorder.endRecording().dispose();
  painter.dispose();
  atlas.image.dispose();
  return drawn.length;
}

({int r, int g, int b, int a}) _pixel(ByteData data, int x, int y) {
  final i = (y * _canvasSize + x) * 4;
  return (
    r: data.getUint8(i),
    g: data.getUint8(i + 1),
    b: data.getUint8(i + 2),
    a: data.getUint8(i + 3),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('theme reader parses icon-rotate and icon-rotation-alignment', () {
    final layer = _arrowLayer(iconRotate: 90, iconRotationAlignment: 'map');
    const ctx = EvalContext(zoom: 16);
    expect(layer.iconRotate.eval(ctx), 90);
    expect(layer.iconRotationAlignment.eval(ctx), 'map');
  });

  test('icon-rotate defaults to 0 and alignment to auto', () {
    final layer = _arrowLayer();
    const ctx = EvalContext(zoom: 16);
    expect(layer.iconRotate.eval(ctx), 0);
    expect(layer.iconRotationAlignment.eval(ctx), 'auto');
  });

  test('a point icon with no rotate is drawn upright, unrotated', () async {
    final layer = _arrowLayer();
    final data = await _render(
        layer, _arrowSymbol(layer, alongLine: false, screenAngle: 0));
    expect(_pixel(data, 32, 26).r, 255, reason: 'red stays on top');
    expect(_pixel(data, 32, 38).b, 255, reason: 'blue stays on bottom');
  });

  test(
      'road_oneway: icon-rotate 90 + map alignment turns the icon to '
      'follow the line direction, not the screen top', () async {
    // The line runs due east on screen (screenAngle 0): the arrow must
    // turn to point east, not stay pointing up.
    final layer = _arrowLayer(iconRotate: 90, iconRotationAlignment: 'map');
    final data = await _render(
        layer, _arrowSymbol(layer, alongLine: true, screenAngle: 0));
    expect(_pixel(data, 38, 32).r, 255,
        reason: 'the sprite\'s "up" content rotates to the east side');
    expect(_pixel(data, 26, 32).b, 255,
        reason: 'the sprite\'s "down" content rotates to the west side');
  });

  test(
      'road_oneway_opposite: icon-rotate -90 turns the icon the other '
      'way from road_oneway on the same line', () async {
    final layer = _arrowLayer(iconRotate: -90, iconRotationAlignment: 'map');
    final data = await _render(
        layer, _arrowSymbol(layer, alongLine: true, screenAngle: 0));
    expect(_pixel(data, 26, 32).r, 255,
        reason: 'mirrors road_oneway: "up" rotates west, not east');
    expect(_pixel(data, 38, 32).b, 255);
  });

  test('map-aligned icon also turns when the line runs north-south', () async {
    final layer = _arrowLayer(iconRotate: 90, iconRotationAlignment: 'map');
    // screenAngle = pi/2: the line runs due south on screen.
    final data = await _render(layer,
        _arrowSymbol(layer, alongLine: true, screenAngle: 1.5707963267948966));
    expect(_pixel(data, 32, 38).r, 255,
        reason: 'rotated a further 90°: "up" content now points south');
  });

  test('map-aligned point icon follows the camera rotation', () async {
    final layer = _arrowLayer(iconRotationAlignment: 'map');
    // For a point symbol screenAngle carries only the camera bearing.
    final data = await _render(
        layer, _arrowSymbol(layer, alongLine: false, screenAngle: math.pi / 2));
    expect(_pixel(data, 38, 32).r, 255,
        reason: 'map east rotates to screen south/east with the camera');
    expect(_pixel(data, 26, 32).b, 255);
  });

  test('icon-rotation-alignment: viewport ignores the line direction',
      () async {
    final layer = _arrowLayer(iconRotate: 0, iconRotationAlignment: 'viewport');
    final data = await _render(
        layer, _arrowSymbol(layer, alongLine: true, screenAngle: 1.2));
    expect(_pixel(data, 32, 26).r, 255,
        reason: 'viewport alignment stays upright regardless of the line');
    expect(_pixel(data, 32, 38).b, 255);
  });

  test('icon-rotate alone still applies to a viewport-aligned point icon',
      () async {
    final layer =
        _arrowLayer(iconRotate: 90, iconRotationAlignment: 'viewport');
    final data = await _render(
        layer, _arrowSymbol(layer, alongLine: false, screenAngle: 0));
    expect(_pixel(data, 38, 32).r, 255);
    expect(_pixel(data, 26, 32).b, 255);
  });

  test('icon-offset rotates around the symbol anchor with the icon', () async {
    final layer = _arrowLayer(
      iconRotate: 90,
      iconRotationAlignment: 'viewport',
      iconOffset: const [0, -8],
    );
    final data = await _render(
        layer, _arrowSymbol(layer, alongLine: false, screenAngle: 0));
    expect(_pixel(data, 46, 32).r, 255,
        reason: 'the upward offset turns right with the icon');
    expect(_pixel(data, 34, 32).b, 255);
  });

  test('collision uses the rotated bounds of a rectangular icon', () async {
    expect(await _rotatedCollisionCount(), 1);
  });
}
