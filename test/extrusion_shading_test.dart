import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:flutter_map_vector_tiles/src/render/extrusion_painter.dart';
import 'package:flutter_map_vector_tiles/src/render/extrusion_shading.dart';
import 'package:flutter_map_vector_tiles/src/style/expression.dart';
import 'package:flutter_map_vector_tiles/src/style/theme.dart';
import 'package:flutter_map_vector_tiles/src/style/theme_reader.dart';
import 'package:flutter_test/flutter_test.dart';

int _red(int argb) => (argb >> 16) & 0xff;

void main() {
  group('projection', () {
    test("MapLibre's lean: 50 m, 300 px out, style z16, Munich, 800 px", () {
      // Style zoom 16 is camera zoom 17 with flutter_map's 256 px tiles.
      final ppm = ExtrusionPainter.pixelsPerMetre(17, 48.14);
      final k = ExtrusionPainter.scaleAt(50 * ppm, 800);
      expect(300 * (k - 1), closeTo(16.6, 0.05));
    });

    test('the ground does not move', () {
      expect(ExtrusionPainter.scaleAt(0, 800), 1);
    });

    test('a roof past the near plane is held at it', () {
      // D = 1200, the near plane 16 px in front of the camera.
      expect(ExtrusionPainter.scaleAt(5000, 800), closeTo(1200 / 16, 1e-9));
      expect(ExtrusionPainter.scaleAt(1184, 800), closeTo(1200 / 16, 1e-9));
      expect(ExtrusionPainter.scaleAt(1100, 800), closeTo(12, 1e-9));
    });
  });

  group('shading', () {
    final light = ExtrusionLight.of(null, 16);
    // Grey 0.6.
    const grey = 0xff999999;

    test('the default light stands at [1.15, 210°, 30°]', () {
      expect(light.x, closeTo(0.2875, 1e-4));
      expect(light.y, closeTo(-0.4980, 1e-4));
      expect(light.z, closeTo(0.9959, 1e-4));
      expect(light.viewport, isTrue);
      expect(light.intensity, 0.5);
    });

    test('grey 0.6: roof 0.6287, walls 0.2646 to 0.4167', () {
      final table = Int32List(ExtrusionShading.stride);
      ExtrusionShading.fill(
          table,
          0,
          grey,
          ExtrusionShading.gradientKey(0, 0, 10),
          ExtrusionShading.gradientKey(1, 0, 10),
          light);
      expect(_red(table[0]), (0.6287 * 255).round());
      final levels = Uint8List(256);
      ExtrusionShading.levelsOf(light, 0, levels);
      final walls = [
        for (var a = 0; a < 256; a++) _red(table[1 + levels[a]]),
        for (var a = 0; a < 256; a++)
          _red(table[1 + ExtrusionShading.levels + levels[a]]),
      ];
      final darkest = walls.reduce((a, b) => a < b ? a : b);
      final brightest = walls.reduce((a, b) => a > b ? a : b);
      expect(darkest, (0.2646 * 255).round());
      // The light level is quantized to 1/63: within a unit.
      expect(brightest, closeTo(0.4167 * 255, 1));
    });

    test('the wall facing the light is lit, the one behind it dark', () {
      final levels = Uint8List(256);
      ExtrusionShading.levelsOf(light, 0, levels);
      // Azimuth 210°, clockwise from the top of the screen: the light is
      // down and to the left, at 120° clockwise from +x (y down). A wall
      // whose outward normal points there faces it.
      int levelOf(double degrees) =>
          levels[(degrees / 360 * 256).round() & 255];
      final most = levels.reduce((a, b) => a > b ? a : b);
      expect(levelOf(120), most);
      expect(most, (0.575 * (ExtrusionShading.levels - 1)).round());
      expect(levelOf(300), 0);
      expect(levelOf(30), 0);
      expect(levelOf(210), 0);
    });

    test('a viewport light turns against the map, a map light with it', () {
      final viewport = Uint8List(256), turned = Uint8List(256);
      ExtrusionShading.levelsOf(light, 0, viewport);
      // Turning the map a quarter clockwise: a wall now facing down-left
      // on screen faced up-left on the map before, i.e. its map normal
      // is a quarter turn counter-clockwise of the screen one.
      ExtrusionShading.levelsOf(light, 3.141592653589793 / 2, turned);
      for (var a = 0; a < 256; a++) {
        expect(turned[(a - 64) & 255], viewport[a]);
      }
      final mapLight = ExtrusionLight.of(
          StyleLight(
            anchor: StringProp.constant('map'),
            position: NumListProp.constant(const [1.15, 210, 30]),
            color: ColorProp.constant(const Color(0xffffffff)),
            intensity: DoubleProp.constant(0.5),
          ),
          16);
      final still = Uint8List(256);
      ExtrusionShading.levelsOf(mapLight, 1.2, still);
      expect(still, viewport);
    });

    test('the alpha of the colour darkens it, as premultiplied', () {
      final opaque = Int32List(ExtrusionShading.stride);
      final half = Int32List(ExtrusionShading.stride);
      ExtrusionShading.fill(opaque, 0, 0xffffffff, 0, 0, light);
      ExtrusionShading.fill(half, 0, 0x80ffffff, 0, 0, light);
      expect(_red(half[0]), lessThan(_red(opaque[0]) * 0.6));
      expect((half[0] >> 24) & 0xff, 0xff);
    });

    test('vertical gradient: the foot darker, a tall top bright', () {
      final table = Int32List(ExtrusionShading.stride);
      ExtrusionShading.fill(
          table,
          0,
          grey,
          ExtrusionShading.gradientKey(0, 0, 200),
          ExtrusionShading.gradientKey(1, 0, 200),
          light);
      const level = 30;
      final foot = _red(table[1 + level]);
      final top = _red(table[1 + ExtrusionShading.levels + level]);
      expect(top, greaterThan(foot));
      final flat = Int32List(ExtrusionShading.stride);
      ExtrusionShading.fill(flat, 0, grey, ExtrusionShading.noGradient,
          ExtrusionShading.noGradient, light);
      expect(_red(flat[1 + level]),
          _red(flat[1 + ExtrusionShading.levels + level]));
      // Without a gradient a wall is shaded as a tall one's top.
      expect(_red(flat[1 + level]), top);
    });
  });

  group('style', () {
    Theme read(Map<String, Object?> style) => const ThemeReader().read(style);

    test('height and base keep render_height and render_min_height', () {
      final theme = read({
        'layers': [
          {
            'id': 'b',
            'type': 'fill-extrusion',
            'source': 's',
            'source-layer': 'building',
            'paint': {
              'fill-extrusion-height': ['get', 'render_height'],
              'fill-extrusion-base': [
                'interpolate', ['linear'], ['zoom'], //
                14, 0, 16, ['get', 'render_min_height'],
              ],
              'fill-extrusion-vertical-gradient': false,
            },
          },
        ],
      });
      final layer = theme.layers.single as FillThemeLayer;
      expect(layer.referencedProperties,
          containsAll(['render_height', 'render_min_height']));
      expect(layer.extrusionHeightReadsZoom, isFalse);
      expect(layer.extrusionBaseReadsZoom, isTrue);
      expect(
          layer.extrusionHeight!.eval(
              const EvalContext(zoom: 15, properties: {'render_height': 42})),
          42);
      expect(layer.extrusionVerticalGradient!.eval(const EvalContext(zoom: 15)),
          isFalse);
    });

    test('a fill has no extrusion properties', () {
      final theme = read({
        'layers': [
          {'id': 'f', 'type': 'fill', 'source': 's', 'source-layer': 'l'},
        ],
      });
      final layer = theme.layers.single as FillThemeLayer;
      expect(layer.extrusionHeight, isNull);
      expect(layer.extrusionVerticalGradient, isNull);
    });

    test('the root light, its defaults and its zoom functions', () {
      expect(read({'layers': <Object>[]}).light, isNull);
      final theme = read({
        'light': {
          'anchor': 'map',
          'position': [2, 90, 45],
          'color': 'red',
          'intensity': [
            'interpolate',
            ['linear'],
            ['zoom'],
            10,
            0.2,
            20,
            0.8
          ],
        },
        'layers': <Object>[],
      });
      final light = ExtrusionLight.of(theme.light, 15);
      expect(light.viewport, isFalse);
      expect(light.intensity, closeTo(0.5, 1e-9));
      expect(light.red, 1);
      expect(light.green, 0);
      // Azimuth 90°: from the right, the light pointing left.
      expect(light.x, closeTo(-2 * 0.7071, 1e-3));
      expect(light.y, closeTo(0, 1e-9));
      expect(light.z, closeTo(2 * 0.7071, 1e-3));
      final partial = ExtrusionLight.of(
          read({
            'light': {'intensity': 0.9},
            'layers': <Object>[],
          }).light,
          15);
      expect(partial.intensity, 0.9);
      expect(partial.viewport, isTrue);
      expect(partial.z, closeTo(0.9959, 1e-4));
    });
  });
}
