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

/// A 16x16 sprite sheet in the shape MapLibre's SDF sheets take: flat
/// black RGB, with the shape carried by the alpha channel as a distance
/// field. Alpha runs 1.0 at the centre down to 0 at the border, crossing
/// the 6/8 edge threshold at `max(|dx|, |dy|) == 2`.
Future<ui.Image> _sdfSheet() {
  final pixels = Uint8List(_atlasSize * _atlasSize * 4);
  for (var y = 0; y < _atlasSize; y++) {
    for (var x = 0; x < _atlasSize; x++) {
      final d = math.max((x - 7.5).abs(), (y - 7.5).abs());
      final a = (0.5 + (4 - d) / 8).clamp(0.0, 1.0);
      final i = (y * _atlasSize + x) * 4;
      // RGB stays 0, so premultiplied and straight encodings agree.
      pixels[i + 3] = (a * 255).round();
    }
  }
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(pixels, _atlasSize, _atlasSize,
      ui.PixelFormat.rgba8888, completer.complete);
  return completer.future;
}

SpriteAtlas _atlas(ui.Image image, {required bool sdf}) => SpriteAtlas(
      image: image,
      pixelRatio: 1,
      sprites: {
        'dot': Sprite(
          x: 0,
          y: 0,
          width: _atlasSize.toDouble(),
          height: _atlasSize.toDouble(),
          pixelRatio: 1,
          sdf: sdf,
        ),
      },
    );

SymbolThemeLayer _iconLayer({
  String iconColor = '#ff0000',
  String? haloColor,
  double? haloWidth,
}) {
  final theme = const ThemeReader().read({
    'layers': [
      {
        'id': 'poi',
        'type': 'symbol',
        'source': 's',
        'source-layer': 'poi',
        'layout': {'icon-image': 'dot', 'icon-size': 1},
        'paint': {
          'icon-color': iconColor,
          if (haloColor != null) 'icon-halo-color': haloColor,
          if (haloWidth != null) 'icon-halo-width': haloWidth,
        },
      },
    ],
  });
  return theme.layers.single as SymbolThemeLayer;
}

PlacedSymbol _iconSymbol(SymbolThemeLayer layer) => PlacedSymbol(
      instance: SymbolInstance(
        layer: layer,
        layerIndex: 0,
        anchor: Offset.zero,
        angle: 0,
        alongLine: false,
        text: '',
        iconName: 'dot',
        sortKey: 0,
        properties: const {},
        geometryType: 'Point',
        featureId: null,
      ),
      // Centred, so the 16x16 sprite lands on (24,24)-(40,40) and each
      // destination pixel samples exactly one texel.
      screenAnchor: const Offset(32, 32),
      screenAngle: 0,
    );

/// Paints one icon and returns the rendered pixels as ARGB rows.
Future<ByteData> _render(SymbolThemeLayer layer, SpriteAtlas atlas) async {
  final painter = LabelPainter();
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  painter.paint(
    canvas: canvas,
    screenSize: _canvasBox,
    styleZoom: 16,
    symbols: [_iconSymbol(layer)],
    sprites: atlas,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(_canvasSize, _canvasSize);
  picture.dispose();
  final bytes = await image.toByteData();
  image.dispose();
  painter.dispose();
  return bytes!;
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

  late ui.Image sheet;
  setUpAll(() async => sheet = await _sdfSheet());
  tearDownAll(() => sheet.dispose());

  test('theme reader parses icon-color and icon-halo', () {
    final layer =
        _iconLayer(iconColor: '#3366ff', haloColor: '#00ff00', haloWidth: 1.5);
    const ctx = EvalContext(zoom: 16);
    expect(layer.iconColor.eval(ctx), const Color(0xff3366ff));
    expect(layer.iconHaloColor.eval(ctx), const Color(0xff00ff00));
    expect(layer.iconHaloWidth.eval(ctx), 1.5);
  });

  test('icon-color defaults to black and halo to transparent', () {
    final theme = const ThemeReader().read({
      'layers': [
        {
          'id': 'poi',
          'type': 'symbol',
          'source': 's',
          'source-layer': 'poi',
          'layout': {'icon-image': 'dot'},
        },
      ],
    });
    final layer = theme.layers.single as SymbolThemeLayer;
    const ctx = EvalContext(zoom: 16);
    expect(layer.iconColor.eval(ctx), const Color(0xff000000));
    expect(layer.iconHaloColor.eval(ctx).a, 0);
    expect(layer.iconHaloWidth.eval(ctx), 0);
  });

  test('sprite index parses the sdf flag', () {
    final sprites = SpriteAtlas.parseIndex({
      'plain': {'x': 0, 'y': 0, 'width': 4, 'height': 4},
      'field': {'x': 4, 'y': 0, 'width': 4, 'height': 4, 'sdf': true},
    });
    expect(sprites['plain']!.sdf, isFalse);
    expect(sprites['field']!.sdf, isTrue);
  });

  test('SDF icon interior is tinted with icon-color, not the sheet colour',
      () async {
    final data = await _render(_iconLayer(), _atlas(sheet, sdf: true));
    // Centre of the shape: alpha well past the 6/8 edge, so fully opaque.
    final centre = _pixel(data, 32, 32);
    expect(centre.a, 255, reason: 'interior should be solid');
    expect(centre.r, 255);
    expect(centre.g, 0);
    expect(centre.b, 0);
  });

  test('SDF icon is thresholded, so the field tail stays transparent',
      () async {
    final data = await _render(_iconLayer(), _atlas(sheet, sdf: true));
    // texel (12,7): distance 4.5 -> alpha 0.44, below the 6/8 edge and
    // below any halo. Blitting the raw field would leave ~113 alpha here,
    // which is exactly the dark-blob artefact.
    expect(_pixel(data, 36, 31).a, 0);
  });

  test('SDF halo fills the band outside the shape edge', () async {
    final layer = _iconLayer(haloColor: '#00ff00', haloWidth: 1.5);
    final data = await _render(layer, _atlas(sheet, sdf: true));
    // texel (10,7): alpha 0.6875 — outside the 6/8 fill edge, inside the
    // (6-1.5)/8 halo edge.
    final band = _pixel(data, 34, 31);
    expect(band.a, 255);
    expect(band.g, 255);
    expect(band.r, 0);
    // The shape itself still wins where the fill covers it.
    expect(_pixel(data, 32, 32).r, 255);
  });

  test('non-SDF sprites are drawn untinted', () async {
    final data = await _render(_iconLayer(), _atlas(sheet, sdf: false));
    final centre = _pixel(data, 32, 32);
    expect(centre.r, 0, reason: 'icon-color must not touch plain sprites');
    expect(centre.g, 0);
    expect(centre.b, 0);
  });
}
