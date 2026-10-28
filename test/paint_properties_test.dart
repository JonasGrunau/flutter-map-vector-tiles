import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_map_vector_tiles/src/core/tile_key.dart';
import 'package:flutter_map_vector_tiles/src/grid/raster_tile_store.dart';
import 'package:flutter_map_vector_tiles/src/pipeline/prepared_tile.dart';
import 'package:flutter_map_vector_tiles/src/render/display_tile_data.dart';
import 'package:flutter_map_vector_tiles/src/render/pattern_resolver.dart';
import 'package:flutter_map_vector_tiles/src/render/tile_rasterizer.dart';
import 'package:flutter_map_vector_tiles/src/style/expression.dart';
import 'package:flutter_map_vector_tiles/src/style/sprite_atlas.dart';
import 'package:flutter_map_vector_tiles/src/style/theme.dart';
import 'package:flutter_map_vector_tiles/src/style/theme_reader.dart';
import 'package:flutter_test/flutter_test.dart';

/// The paint and layout properties of fill, line, circle, background
/// and raster layers beyond colour, width and opacity, drawn into one
/// tile at a device pixel ratio of 1, so that a logical pixel is a
/// pixel of the image. Geometry is given in those pixels; the tile's
/// extent is 4096, 16 units to the pixel.
const _key = TileKey(2, 1, 1);

PreparedFeature _feature(PreparedGeomType type, List<List<double>> parts,
        {Map<String, Object?> properties = const {}, Object? id}) =>
    PreparedFeature(
      id: id,
      type: type,
      parts: [
        for (final part in parts)
          Float32List.fromList([for (final v in part) v * 16]),
      ],
      properties: properties,
    );

PreparedFeature _square(double left, double top, double right, double bottom,
        {Map<String, Object?> properties = const {}}) =>
    _feature(
        PreparedGeomType.polygon,
        [
          [left, top, right, top, right, bottom, left, bottom],
        ],
        properties: properties);

PreparedFeature _line(List<double> points,
        {Map<String, Object?> properties = const {}}) =>
    _feature(PreparedGeomType.line, [points], properties: properties);

PreparedFeature _point(double x, double y,
        {Map<String, Object?> properties = const {}}) =>
    _feature(
        PreparedGeomType.point,
        [
          [x, y],
        ],
        properties: properties);

DisplayTileData _tile(List<PreparedFeature> features,
        {Map<String, RasterTile> rasters = const {}}) =>
    DisplayTileData(
      displayKey: _key,
      sources: {
        's': PreparedTile(
          key: _key,
          layers: {
            'l': PreparedSourceLayer(extent: 4096, features: features),
          },
          byteSize: 100,
        ),
      },
      rasters: rasters,
    );

/// A white background under [layers], which read source `s`, layer `l`.
Theme _theme(List<Map<String, Object?>> layers) => const ThemeReader().read({
      'layers': [
        {
          'id': 'bg',
          'type': 'background',
          'paint': {'background-color': '#ffffff'},
        },
        for (final (i, layer) in layers.indexed)
          {'id': 'layer$i', 'source': 's', 'source-layer': 'l', ...layer},
      ],
    });

class _Pixels {
  final ByteData bytes;
  final int width;

  _Pixels(this.bytes, this.width);

  int _channel(int x, int y, int c) => bytes.getUint8((y * width + x) * 4 + c);

  /// The red channel: a grey level when black is drawn on white.
  int grey(int x, int y) => _channel(x, y, 0);

  Color at(int x, int y) => Color.fromARGB(_channel(x, y, 3), _channel(x, y, 0),
      _channel(x, y, 1), _channel(x, y, 2));

  /// How much black column [x] holds between rows [from] and [to], in
  /// pixels: a black line's width, whatever its edges look like.
  double ink(int x, int from, int to) {
    var sum = 0.0;
    for (var y = from; y < to; y++) {
      sum += 1 - grey(x, y) / 255;
    }
    return sum;
  }
}

Future<_Pixels> _render(Theme theme, DisplayTileData data,
    {double zoom = 2,
    PatternResolver? patterns,
    double devicePixelRatio = 1}) async {
  final image = TileRasterizer.rasterize(
    theme: theme,
    data: data,
    styleZoom: zoom,
    devicePixelRatio: devicePixelRatio,
    patterns: patterns,
  )!;
  final bytes = (await image.toByteData())!;
  final pixels = _Pixels(bytes, image.width);
  image.dispose();
  return pixels;
}

const _black = Color(0xff000000);
const _white = Color(0xffffffff);
const _red = Color(0xffff0000);
const _blue = Color(0xff0000ff);

Matcher _near(int grey, [int tolerance = 2]) =>
    inInclusiveRange(grey - tolerance, grey + tolerance);

/// An 8×8 sprite of one colour, as the only icon of a sheet.
SpriteAtlas _solidAtlas(Color color) {
  final recorder = ui.PictureRecorder();
  Canvas(recorder)
      .drawRect(const Rect.fromLTWH(0, 0, 8, 8), Paint()..color = color);
  final picture = recorder.endRecording();
  final image = picture.toImageSync(8, 8);
  picture.dispose();
  return SpriteAtlas(
    image: image,
    sprites: const {
      'solid': Sprite(x: 0, y: 0, width: 8, height: 8, pixelRatio: 1),
    },
    pixelRatio: 1,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('translate', () {
    test('fill-translate moves the fill by [x, y] pixels', () async {
      final pixels = await _render(
        _theme([
          {
            'type': 'fill',
            'paint': {
              'fill-color': '#000000',
              'fill-translate': [10, 20],
            },
          },
        ]),
        _tile([_square(64, 64, 128, 128)]),
      );
      expect(pixels.grey(70, 70), 255, reason: 'left behind');
      expect(pixels.grey(100, 100), 0);
      expect(pixels.grey(134, 140), 0, reason: 'moved in');
      expect(pixels.grey(140, 150), 255);
    });

    test('a zoom function of [x, y] arrays is interpolated, as in Bright',
        () async {
      // Bright's building-top: [0, 0] at z14 to [-2, -2] at z16.
      final theme = _theme([
        {
          'type': 'fill',
          'paint': {
            'fill-color': '#000000',
            'fill-translate': [
              'interpolate',
              ['linear'],
              ['zoom'],
              14,
              [
                'literal',
                [0, 0],
              ],
              16,
              [
                'literal',
                [-20, -20],
              ],
            ],
          },
        },
      ]);
      final layer = theme.layers.last as FillThemeLayer;
      expect(layer.translate!.eval(const EvalContext(zoom: 15)), [-10, -10]);
      final pixels =
          await _render(theme, _tile([_square(64, 64, 128, 128)]), zoom: 15);
      expect(pixels.grey(56, 56), 0);
      expect(pixels.grey(122, 122), 255);
    });

    test('geometry translated in from outside the cull window is drawn',
        () async {
      // Entirely beyond the 64 px buffer the rasterizer culls outside:
      // the window has to move with the geometry.
      final pixels = await _render(
        _theme([
          {
            'type': 'fill',
            'paint': {
              'fill-color': '#000000',
              'fill-translate': [150, 0],
            },
          },
        ]),
        _tile([_square(-200, 64, -100, 128)]),
      );
      expect(pixels.grey(25, 100), 0);
    });

    test('a fill pattern moves with its translated fill', () async {
      final atlas = _solidAtlas(_black);
      final patterns = PatternResolver(atlas);
      final pixels = await _render(
        _theme([
          {
            'type': 'fill',
            'paint': {
              'fill-pattern': 'solid',
              'fill-translate': [10, 0],
            },
          },
        ]),
        _tile([_square(64, 64, 128, 128)]),
        patterns: patterns,
      );
      expect(pixels.grey(70, 100), 255);
      expect(pixels.grey(134, 100), 0);
      patterns.dispose();
      atlas.dispose();
    });

    test('line-translate and circle-translate move their geometry', () async {
      final line = await _render(
        _theme([
          {
            'type': 'line',
            'paint': {
              'line-width': 4,
              'line-translate': [0, 30],
            },
          },
        ]),
        _tile([
          _line([20, 128, 236, 128]),
        ]),
      );
      expect(line.grey(128, 128), 255);
      expect(line.grey(128, 158), 0);

      final circle = await _render(
        _theme([
          {
            'type': 'circle',
            'paint': {
              'circle-radius': 10,
              'circle-translate': [-40, 0],
            },
          },
        ]),
        _tile([_point(128, 128)]),
      );
      expect(circle.grey(128, 128), 255);
      expect(circle.grey(88, 128), 0);
    });

    test('fill-extrusion-translate moves the flat extrusion', () async {
      final pixels = await _render(
        _theme([
          {
            'type': 'fill-extrusion',
            'paint': {
              'fill-extrusion-color': '#000000',
              'fill-extrusion-translate': [0, -30],
            },
          },
        ]),
        _tile([_square(64, 64, 128, 128)]),
      );
      expect(pixels.grey(100, 110), 255);
      expect(pixels.grey(100, 40), 0);
    });
  });

  group('line-offset', () {
    test('shifts a line to the right of its direction, left when negative',
        () async {
      Future<_Pixels> offset(double by) => _render(
            _theme([
              {
                'type': 'line',
                'paint': {'line-width': 4, 'line-offset': by},
              },
            ]),
            // Drawn eastwards: its right is south, down the tile.
            _tile([
              _line([20, 128, 236, 128]),
            ]),
          );
      final right = await offset(10);
      expect(right.grey(128, 128), 255);
      expect(right.grey(128, 138), 0);
      final left = await offset(-10);
      expect(left.grey(128, 118), 0);
      expect(left.grey(128, 138), 255);
    });

    test('insets a polygon outline, corners included', () async {
      final pixels = await _render(
        _theme([
          {
            'type': 'line',
            'paint': {'line-width': 2, 'line-offset': 5},
          },
        ]),
        _tile([_square(64, 64, 192, 192)]),
      );
      expect(pixels.grey(64, 128), 255, reason: 'the original edge');
      expect(pixels.grey(69, 128), _near(0, 40));
      expect(pixels.grey(186, 128), _near(0, 40));
      // A right angle keeps its miter: the inset ring is closed.
      expect(pixels.grey(69, 69), _near(0, 40));
      expect(pixels.grey(128, 128), 255);
    });

    test('a data-driven offset applies per feature', () async {
      final pixels = await _render(
        _theme([
          {
            'type': 'line',
            'paint': {
              'line-width': 4,
              'line-offset': ['get', 'o'],
            },
          },
        ]),
        _tile([
          _line([20, 64, 236, 64], properties: {'o': 10}),
          _line([20, 192, 236, 192], properties: {'o': -10}),
        ]),
      );
      expect(pixels.grey(128, 74), 0);
      expect(pixels.grey(128, 182), 0);
      expect(pixels.grey(128, 64), 255);
      expect(pixels.grey(128, 192), 255);
    });
  });

  group('line-blur', () {
    // MapLibre widens a line's anti-aliasing ramp by its blur: alpha
    // falls linearly from full, blur + 1 device px inside the edge, to
    // zero half a device px past it. Compared row by row at a device
    // pixel ratio of 3, down the middle of a horizontal line.
    Future<({double maxError, double ink, double expectedInk, double peak})>
        compare(double width, double blur, {bool perFeature = false}) async {
      const dpr = 3.0;
      final pixels = await _render(
        _theme([
          {
            'type': 'line',
            'paint': {
              'line-width': width,
              // Read from the feature, the stroke is drawn per feature.
              'line-blur': perFeature ? ['get', 'b'] : blur,
            },
          },
        ]),
        _tile([
          _line([20, 128, 236, 128], properties: {'b': blur}),
        ]),
        devicePixelRatio: dpr,
      );
      var maxError = 0.0, ink = 0.0, expectedInk = 0.0, peak = 0.0;
      for (var y = (110 * dpr).round(); y < (146 * dpr).round(); y++) {
        final alpha = 1 - pixels.grey((128 * dpr).round(), y) / 255;
        final d = ((y + 0.5) / dpr - 128).abs();
        final expected =
            ((width / 2 + 0.5 / dpr - d) / (blur + 1 / dpr)).clamp(0.0, 1.0);
        maxError = math.max(maxError, (alpha - expected).abs());
        peak = math.max(peak, alpha);
        ink += alpha / dpr;
        expectedInk += expected / dpr;
      }
      return (
        maxError: maxError,
        ink: ink,
        expectedInk: expectedInk,
        peak: peak
      );
    }

    test('fades the edges over the blur, as MapLibre does', () async {
      for (final blur in [2.0, 4.0]) {
        final r = await compare(8, blur);
        // Skia stays within 0.06 of the ramp, Impeller within about 0.1.
        expect(r.maxError, lessThan(0.12), reason: 'blur $blur');
        // A line `width` wide holds width − blur pixels of ink.
        expect(r.ink, closeTo(8 - blur, 0.05), reason: 'blur $blur');
      }
    });

    test('a line narrower than twice its blur never reaches full alpha',
        () async {
      final r = await compare(2, 4);
      expect(r.peak, lessThan(0.3));
      expect(r.maxError, lessThan(0.05));
      expect(r.ink, closeTo(r.expectedInk, 0.03));
    });

    test('a blur narrower than anti-aliasing still takes its ink', () async {
      // Americana's roads: 0.5 px, under the mask filter's threshold.
      // The line loses what the ramp takes, drawn as one path for the
      // layer or per feature alike.
      for (final perFeature in [false, true]) {
        final r = await compare(3, 0.5, perFeature: perFeature);
        expect(r.ink, closeTo(r.expectedInk, 0.2));
        expect(r.maxError, lessThan(0.3));
      }
    });

    test('a layer-wide opaque blur drawn as one path matches per feature',
        () async {
      // A colour read from the feature (the same for both) keeps the
      // stroke per feature; a constant one lets the layer draw a single
      // blurred path. Apart from where strokes overlap, the two agree.
      Future<_Pixels> draw(Object color) => _render(
            _theme([
              {
                'type': 'line',
                'paint': {
                  'line-width': 8,
                  'line-blur': 3,
                  'line-color': color,
                },
              },
            ]),
            _tile([
              _line([20, 64, 236, 64], properties: {'c': '#000000'}),
              _line([20, 192, 236, 192], properties: {'c': '#000000'}),
            ]),
            devicePixelRatio: 3,
          );
      final batched = await draw('#000000');
      final perFeature = await draw(['get', 'c']);
      var worst = 0;
      for (var y = 0; y < 768; y += 3) {
        for (var x = 60; x < 708; x += 9) {
          worst = math.max(
              worst, (batched.grey(x, y) - perFeature.grey(x, y)).abs());
        }
      }
      expect(worst, lessThanOrEqualTo(2));
      expect(batched.grey(384, 192), _near(0, 30), reason: 'blurred core');
    });

    // The next two hold on Skia either way; under Impeller
    // (`flutter test --enable-impeller`) they fail without the
    // workarounds in `_paintLine` and `_drawStroke`.

    test('a blurred dashed line along an axis still draws', () async {
      // Several contours on one horizontal line: Impeller draws nothing
      // for such a path under a mask filter.
      final pixels = await _render(
        _theme([
          {
            'type': 'line',
            'paint': {
              'line-width': 6,
              'line-blur': 2,
              'line-dasharray': [3, 2],
            },
          },
        ]),
        _tile([
          _line([20, 128, 236, 128]),
        ]),
        devicePixelRatio: 2,
      );
      expect(pixels.ink(2 * 30, 2 * 110, 2 * 146), greaterThan(4));
    });

    test('a blurred casing on a bent line keeps its casing', () async {
      // Impeller erased the whole layer for a mask-blurred gap stroke.
      final pixels = await _render(
        _theme([
          {
            'type': 'line',
            'paint': {'line-width': 4, 'line-gap-width': 12, 'line-blur': 2},
          },
        ]),
        _tile([
          _line([20, 128, 128, 128, 236, 200]),
        ]),
        devicePixelRatio: 2,
      );
      expect(pixels.grey(2 * 64, 2 * 128), 255, reason: 'the gap');
      expect(pixels.ink(2 * 64, 2 * 100, 2 * 160), greaterThan(8));
    });

    test('a blur reading the feature applies per feature', () async {
      final pixels = await _render(
        _theme([
          {
            'type': 'line',
            'paint': {
              'line-width': 8,
              'line-blur': ['get', 'b'],
            },
          },
        ]),
        _tile([
          _line([20, 64, 236, 64], properties: {'b': 0}),
          _line([20, 192, 236, 192], properties: {'b': 4}),
        ]),
      );
      expect(pixels.grey(128, 67), 0);
      expect(pixels.grey(128, 195), greaterThan(150));
    });

    test('a blurred casing keeps its gap', () async {
      final pixels = await _render(
        _theme([
          {
            'type': 'line',
            'paint': {'line-width': 6, 'line-gap-width': 12, 'line-blur': 2},
          },
        ]),
        _tile([
          _line([20, 128, 236, 128]),
        ]),
      );
      // Casing rows 116–121 and 134–139 around a 12 px gap.
      expect(pixels.grey(128, 128), 255);
      expect(pixels.grey(128, 118), _near(0, 30));
      expect(pixels.grey(128, 137), _near(0, 30));
      expect(pixels.grey(128, 110), 255);
    });
  });

  group('line-miter-limit', () {
    // A 40° V pointing up, its vertex at (128, 64). A miter would reach
    // 5 / sin 20° ≈ 14.6 px above the vertex, a ratio of 2.9 — past the
    // spec's default limit of 2, inside Skia's own default of 4.
    final arm = 100 * math.sin(20 * math.pi / 180);
    final drop = 100 * math.cos(20 * math.pi / 180);
    final v = _line([128 - arm, 64 + drop, 128, 64, 128 + arm, 64 + drop]);

    Future<_Pixels> joined(Map<String, Object?> layout) => _render(
          _theme([
            {
              'type': 'line',
              'layout': layout,
              'paint': {'line-width': 10},
            },
          ]),
          _tile([v]),
        );

    test('the default of 2 bevels a sharp miter join', () async {
      final pixels = await joined({});
      expect(pixels.grey(128, 56), 255);
      expect(pixels.grey(128, 66), 0);
    });

    test('a higher limit keeps it mitered', () async {
      final pixels = await joined({'line-miter-limit': 4});
      expect(pixels.grey(128, 56), 0);
    });

    test('a negative limit bevels, never falls back to a miter', () async {
      final pixels = await joined({'line-miter-limit': -1});
      expect(pixels.grey(128, 56), 255);
    });
  });

  group('sort keys', () {
    test('fill-sort-key draws a higher key above a lower one', () async {
      final features = [
        _square(64, 64, 160, 160, properties: {'k': 2, 'c': '#ff0000'}),
        _square(96, 96, 192, 192, properties: {'k': 1, 'c': '#0000ff'}),
      ];
      Map<String, Object?> layer({bool sorted = true}) => {
            'type': 'fill',
            if (sorted)
              'layout': {
                'fill-sort-key': ['get', 'k'],
              },
            'paint': {
              'fill-color': ['get', 'c'],
            },
          };
      final unsorted =
          await _render(_theme([layer(sorted: false)]), _tile(features));
      expect(unsorted.at(128, 128), _blue, reason: 'source order');
      final sorted = await _render(_theme([layer()]), _tile(features));
      expect(sorted.at(128, 128), _red);
    });

    test('line-sort-key ties keep source order', () async {
      final features = [
        _line([20, 128, 236, 128], properties: {'k': 1, 'c': '#ff0000'}),
        _line([128, 20, 128, 236], properties: {'k': 1, 'c': '#0000ff'}),
        _line([20, 20, 236, 236], properties: {'k': 0, 'c': '#000000'}),
      ];
      final pixels = await _render(
        _theme([
          {
            'type': 'line',
            'layout': {
              'line-sort-key': ['get', 'k'],
            },
            'paint': {
              'line-width': 8,
              'line-color': ['get', 'c'],
            },
          },
        ]),
        _tile(features),
      );
      // The diagonal, lowest, goes under both; blue was later than red.
      expect(pixels.at(128, 128), _blue);
      expect(pixels.at(60, 60), _black);
    });

    test('circle-sort-key, and a key reading the zoom re-sorts per zoom',
        () async {
      final theme = _theme([
        {
          'type': 'circle',
          'layout': {
            'circle-sort-key': [
              'case',
              [
                '>=',
                ['zoom'],
                3,
              ],
              ['get', 'k'],
              [
                '-',
                ['get', 'k'],
              ],
            ],
          },
          'paint': {
            'circle-radius': 20,
            'circle-color': ['get', 'c'],
          },
        },
      ]);
      final data = _tile([
        _point(120, 128, properties: {'k': 1, 'c': '#ff0000'}),
        _point(136, 128, properties: {'k': 2, 'c': '#0000ff'}),
      ]);
      expect((await _render(theme, data, zoom: 3)).at(128, 128), _blue);
      expect((await _render(theme, data, zoom: 2)).at(128, 128), _red);
      expect((await _render(theme, data, zoom: 3)).at(128, 128), _blue);
    });
  });

  group('circles', () {
    test('the stroke lies outside the radius', () async {
      final pixels = await _render(
        _theme([
          {
            'type': 'circle',
            'paint': {
              'circle-radius': 20,
              'circle-color': '#ff0000',
              'circle-stroke-width': 10,
              'circle-stroke-color': '#000000',
            },
          },
        ]),
        _tile([_point(128, 128)]),
      );
      expect(pixels.at(128 + 16, 128), _red);
      expect(pixels.at(128 + 22, 128), _black);
      expect(pixels.at(128 + 28, 128), _black);
      expect(pixels.at(128 + 32, 128), _white);
    });

    test('a translucent stroke does not cover the fill', () async {
      final pixels = await _render(
        _theme([
          {
            'type': 'circle',
            'paint': {
              'circle-radius': 20,
              'circle-color': '#ff0000',
              'circle-stroke-width': 10,
              'circle-stroke-color': '#000000',
              'circle-stroke-opacity': 0.5,
            },
          },
        ]),
        _tile([_point(128, 128)]),
      );
      // Half black over the white background, not over the red fill.
      final band = pixels.at(128 + 25, 128);
      expect((band.r * 255).round(), _near(128, 3));
      expect((band.g * 255).round(), _near(128, 3));
    });

    test('circle-blur 1 leaves only the centre at full opacity', () async {
      final pixels = await _render(
        _theme([
          {
            'type': 'circle',
            'paint': {'circle-radius': 40, 'circle-blur': 1},
          },
        ]),
        _tile([_point(128, 128)]),
      );
      // smoothstep(1 − d / 40): 1 at the centre, 0.5 halfway, 0 at the
      // edge.
      expect(pixels.grey(128, 128), _near(0, 4));
      expect(pixels.grey(128 + 20, 128), _near(128, 12));
      expect(pixels.grey(128 + 39, 128), greaterThan(245));
    });

    test('circle-blur 0.5 keeps the inner half solid', () async {
      final pixels = await _render(
        _theme([
          {
            'type': 'circle',
            'paint': {'circle-radius': 40, 'circle-blur': 0.5},
          },
        ]),
        _tile([_point(128, 128)]),
      );
      expect(pixels.grey(128 + 18, 128), _near(0, 4));
      expect(pixels.grey(128 + 30, 128), _near(128, 12));
    });

    test('a blurred circle with a stroke blends from fill to stroke', () async {
      final pixels = await _render(
        _theme([
          {
            'type': 'circle',
            'paint': {
              'circle-radius': 30,
              'circle-color': '#ff0000',
              'circle-stroke-width': 10,
              'circle-stroke-color': '#0000ff',
              'circle-blur': 0.25,
            },
          },
        ]),
        _tile([_point(128, 128)]),
      );
      // The centre is the fill; a gradient lands within a step of it.
      final centre = pixels.at(128, 128);
      expect(centre.r, greaterThan(0.97));
      expect(centre.g + centre.b, lessThan(0.03));
      // Between the radius and the edge's ramp: stroke, opaque.
      final stroke = pixels.at(128 + 30, 128);
      expect(stroke.b, greaterThan(0.9));
      expect(stroke.r, lessThan(0.1));
    });
  });

  group('background-pattern', () {
    test('replaces the background colour', () async {
      final atlas = _solidAtlas(_blue);
      final patterns = PatternResolver(atlas);
      final pixels = await _render(
        const ThemeReader().read({
          'layers': [
            {
              'id': 'bg',
              'type': 'background',
              'paint': {
                'background-color': '#ff0000',
                'background-pattern': 'solid',
              },
            },
          ],
        }),
        _tile(const []),
        patterns: patterns,
      );
      expect(pixels.at(0, 0), _blue);
      expect(pixels.at(255, 255), _blue);
      patterns.dispose();
      atlas.dispose();
    });

    test('falls back to the colour when the sprite is missing', () async {
      final atlas = _solidAtlas(_blue);
      final patterns = PatternResolver(atlas);
      final pixels = await _render(
        const ThemeReader().read({
          'layers': [
            {
              'id': 'bg',
              'type': 'background',
              'paint': {
                'background-color': '#ff0000',
                'background-pattern': 'missing',
              },
            },
          ],
        }),
        _tile(const []),
        patterns: patterns,
      );
      expect(pixels.at(128, 128), _red);
      patterns.dispose();
      atlas.dispose();
    });

    test('a patterned background is no gap colour', () {
      final theme = const ThemeReader().read({
        'layers': [
          {
            'id': 'bg',
            'type': 'background',
            'paint': {'background-pattern': 'solid'},
          },
        ],
      });
      expect(theme.backgroundColor(10), isNull);
    });
  });

  group('raster resampling', () {
    /// A 2×2 image, black top-left and white elsewhere, magnified to fill
    /// the tile: each pixel becomes a 128 px block.
    RasterTile checker() {
      final recorder = ui.PictureRecorder();
      Canvas(recorder)
        ..drawRect(const Rect.fromLTWH(0, 0, 2, 2), Paint()..color = _white)
        ..drawRect(const Rect.fromLTWH(0, 0, 1, 1), Paint()..color = _black);
      final picture = recorder.endRecording();
      final image = picture.toImageSync(2, 2);
      picture.dispose();
      return RasterTile(_key, image);
    }

    Future<_Pixels> resampled(Map<String, Object?> paint) async {
      final raster = checker();
      final pixels = await _render(
        const ThemeReader().read({
          'layers': [
            {'id': 'r', 'type': 'raster', 'source': 'r', 'paint': paint},
          ],
        }),
        DisplayTileData(
            displayKey: _key, sources: const {}, rasters: {'r': raster}),
      );
      raster.dispose();
      return pixels;
    }

    test('nearest keeps the blocks sharp, linear blends them', () async {
      final nearest = await resampled({'raster-resampling': 'nearest'});
      expect(nearest.grey(120, 64), 0);
      expect(nearest.grey(136, 64), 255);
      final linear = await resampled({});
      expect(linear.grey(120, 64), inExclusiveRange(10, 245));
    });

    test('the generic resampling property wins over raster-resampling',
        () async {
      final pixels = await resampled(
          {'resampling': 'nearest', 'raster-resampling': 'linear'});
      expect(pixels.grey(120, 64), 0);
    });
  });

  group('theme reader', () {
    test('leaves the new properties null when the style does not set them', () {
      final layers = _theme([
        {'type': 'fill'},
        {'type': 'line'},
        {'type': 'circle'},
      ]).layers;
      final fill = layers[1] as FillThemeLayer;
      final line = layers[2] as LineThemeLayer;
      final circle = layers[3] as CircleThemeLayer;
      expect(fill.translate, isNull);
      expect(fill.sortKey, isNull);
      expect(line.translate, isNull);
      expect(line.offset, isNull);
      expect(line.blur, isNull);
      expect(line.miterLimit, isNull);
      expect(line.sortKey, isNull);
      expect(circle.blur, isNull);
      expect(circle.translate, isNull);
      expect(circle.sortKey, isNull);
      expect((layers[0] as BackgroundThemeLayer).pattern, isNull);
    });

    test('reads the legacy stop function form of a translate', () {
      // OSM Bright's water-offset.
      final fill = _theme([
        {
          'type': 'fill',
          'paint': {
            'fill-translate': {
              'base': 1,
              'stops': [
                [
                  6,
                  [2, 0],
                ],
                [
                  8,
                  [0, 0],
                ],
              ],
            },
          },
        },
      ]).layers.last as FillThemeLayer;
      expect(fill.translate!.eval(const EvalContext(zoom: 7)), [1, 0]);
    });

    test('a miter limit expression falls back to the spec default', () {
      final line = _theme([
        {
          'type': 'line',
          'layout': {
            'line-miter-limit': ['get', 'missing'],
          },
        },
      ]).layers.last as LineThemeLayer;
      expect(line.miterLimit!.eval(const EvalContext(zoom: 10)), 2);
    });

    test('a sort key registers the properties it reads', () {
      final line = _theme([
        {
          'type': 'line',
          'layout': {
            'line-sort-key': ['get', 'rank'],
          },
        },
      ]).layers.last;
      expect(line.referencedProperties, contains('rank'));
    });
  });
}
