import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart' hide Theme;
import 'package:flutter/rendering.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_vector_tiles/flutter_map_vector_tiles.dart';
import 'package:flutter_map_vector_tiles/src/grid/raster_tile_store.dart';
import 'package:flutter_map_vector_tiles/src/render/display_tile_data.dart';
import 'package:flutter_map_vector_tiles/src/render/hillshade_renderer.dart';
import 'package:flutter_map_vector_tiles/src/style/expression.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';

/// Encodes [metres] as a Terrarium pixel's red, green and blue.
(int, int, int) terrarium(double metres) {
  final v = metres + 32768;
  return (
    (v / 256).floor(),
    v.floor() % 256,
    ((v - v.floor()) * 256).floor(),
  );
}

/// A [dim]² Terrarium DEM tile, decoded.
Future<ui.Image> demImage(
  int dim,
  double Function(int x, int y) elevation,
) {
  final pixels = Uint8List(dim * dim * 4);
  for (var y = 0; y < dim; y++) {
    for (var x = 0; x < dim; x++) {
      final (r, g, b) = terrarium(elevation(x, y));
      pixels.setAll((y * dim + x) * 4, [r, g, b, 255]);
    }
  }
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
      pixels, dim, dim, ui.PixelFormat.rgba8888, completer.complete);
  return completer.future;
}

/// A [dim]² Terrarium DEM tile as an uncompressed 24-bit BMP — encoded
/// synchronously, so a provider can serve it inside fake async.
Uint8List demBmp(int dim, double Function(int x, int y) elevation) {
  final stride = (dim * 3 + 3) & ~3;
  final bytes = ByteData(54 + stride * dim);
  bytes
    ..setUint8(0, 0x42)
    ..setUint8(1, 0x4d)
    ..setUint32(2, bytes.lengthInBytes, Endian.little)
    ..setUint32(10, 54, Endian.little)
    ..setUint32(14, 40, Endian.little)
    ..setInt32(18, dim, Endian.little)
    // Negative: rows run top-down.
    ..setInt32(22, -dim, Endian.little)
    ..setUint16(26, 1, Endian.little)
    ..setUint16(28, 24, Endian.little)
    ..setUint32(34, stride * dim, Endian.little);
  for (var y = 0; y < dim; y++) {
    for (var x = 0; x < dim; x++) {
      final (r, g, b) = terrarium(elevation(x, y));
      final o = 54 + y * stride + x * 3;
      bytes
        ..setUint8(o, b)
        ..setUint8(o + 1, g)
        ..setUint8(o + 2, r);
    }
  }
  return bytes.buffer.asUint8List();
}

HillshadeThemeLayer hillshadeLayer({
  String method = 'standard',
  List<double> directions = const [335],
  List<double> altitudes = const [45],
  double exaggeration = 0.5,
  Color accent = const Color(0xff000000),
  List<Color> shadows = const [Color(0xff000000)],
  List<Color> highlights = const [Color(0xffffffff)],
}) =>
    HillshadeThemeLayer(
      id: 'hillshade',
      source: 'dem',
      minzoom: 0,
      maxzoom: 24,
      filter: constExpr(true),
      method: StringProp.constant(method),
      directions: [for (final d in directions) DoubleProp.constant(d)],
      altitudes: [for (final a in altitudes) DoubleProp.constant(a)],
      anchor: StringProp.constant('viewport'),
      exaggeration: DoubleProp.constant(exaggeration),
      shadowColors: [for (final c in shadows) ColorProp.constant(c)],
      highlightColors: [for (final c in highlights) ColorProp.constant(c)],
      accentColor: ColorProp.constant(accent),
      resampling: StringProp.constant('linear'),
    );

/// Shades display tile [displayKey] from the DEM tile [demKey] of [dems]
/// (all others are offered as its neighbours) into a 256² image, and
/// returns its RGBA bytes.
Future<ByteData?> shade({
  required HillshadeThemeLayer layer,
  required TileKey displayKey,
  required Map<TileKey, ui.Image> dems,
  TileKey? demKey,
  List<TileKey> descendants = const [],
}) async {
  final center = demKey ?? displayKey;
  final recorder = ui.PictureRecorder();
  final handles = <RasterTile>[];
  RasterTile handle(TileKey key) {
    final tile = RasterTile(key, dems[key]!.clone());
    handles.add(tile);
    return tile;
  }

  final painted = HillshadeRenderer.paint(
    Canvas(recorder),
    layer,
    DisplayTileData(
      displayKey: displayKey,
      sources: const {},
      rasters: {if (descendants.isEmpty) 'dem': handle(center)},
      descendantRasters: {
        if (descendants.isNotEmpty)
          'dem': [for (final k in descendants) handle(k)],
      },
      neighbourRasters: {
        'dem': [
          for (final key in dems.keys)
            if (key != center && !descendants.contains(key)) handle(key),
        ],
      },
      demEncodings: const {'dem': DemEncoding.terrarium},
    ),
    EvalContext(zoom: displayKey.z.toDouble()),
  );
  final picture = recorder.endRecording();
  for (final tile in handles) {
    tile.dispose();
  }
  if (!painted) {
    picture.dispose();
    return null;
  }
  final image = picture.toImageSync(256, 256);
  picture.dispose();
  final bytes = await image.toByteData();
  image.dispose();
  return bytes;
}

({int r, int g, int b, int a}) pixel(ByteData bytes, int x, int y) {
  final i = (y * 256 + x) * 4;
  return (
    r: bytes.getUint8(i),
    g: bytes.getUint8(i + 1),
    b: bytes.getUint8(i + 2),
    a: bytes.getUint8(i + 3),
  );
}

/// What MapLibre's `standard` method makes of a slope ([dx], [dy] in
/// the prepare pass's units) at [latitude], with black shadow and
/// accent and white highlight: the alpha of the result. Includes the eight-bit
/// round trip the slopes make between the two passes.
double standardAlpha(
  double dx,
  double dy, {
  required double latitude,
  double intensity = 0.5,
}) {
  double roundTrip(double d) =>
      (((d / 8 + 128 / 255).clamp(0.0, 1.0) * 255).round() / 255 - 128 / 255) *
      8 /
      math.cos(latitude * math.pi / 180);
  final x = roundTrip(dx), y = roundTrip(dy);
  final slope = math.atan(0.625 * math.sqrt(x * x + y * y));
  final base = 1.875 - intensity * 1.75;
  const maxValue = 0.5 * math.pi;
  final scaled = intensity != 0.5
      ? (math.pow(base, slope) - 1) / (math.pow(base, maxValue) - 1) * maxValue
      : slope;
  final fade = (intensity * 2).clamp(0.0, 1.0);
  final accent = (1 - math.cos(scaled)) * fade;
  // Shadow and highlight are both opaque, so the aspect only picks a
  // colour between them; the alpha is the slope's alone.
  final shadeAlpha = math.sin(scaled) * fade;
  return accent * (1 - shadeAlpha) + shadeAlpha;
}

const _z = 12;
const _x = 2148;
const _y = 1435;
const _key = TileKey(_z, _x, _y);
const _dim = 64;

/// A plane rising [metresPerTexel] eastward, continuous across tiles.
double Function(int, int) eastward(TileKey key, double metresPerTexel) =>
    (x, y) => 1000 + metresPerTexel * ((key.x - _x) * _dim + x);

/// The block of tiles around [_key], each a part of the same plane.
Future<Map<TileKey, ui.Image>> plane(
  double metresPerTexel, {
  bool neighbours = true,
}) async =>
    {
      for (final dy in const [-1, 0, 1])
        for (final dx in const [-1, 0, 1])
          if (neighbours || (dx == 0 && dy == 0))
            TileKey(_z, _x + dx, _y + dy): await demImage(
                _dim, eastward(TileKey(_z, _x + dx, _y + dy), metresPerTexel)),
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    if (kIsWeb) return;
    expect(await HillshadePrograms.load(), isNotNull,
        reason: 'the shaders must load under flutter test');
  });

  group('reading', () {
    test('a hillshade layer takes the spec defaults', () {
      final theme = const ThemeReader().read({
        'layers': [
          {'id': 'h', 'type': 'hillshade', 'source': 'dem'},
        ],
      });
      final layer = theme.layers.single as HillshadeThemeLayer;
      const ctx = EvalContext(zoom: 10);
      expect(layer.source, 'dem');
      expect(layer.method.eval(ctx), 'standard');
      expect([for (final d in layer.directions) d.eval(ctx)], [335]);
      expect([for (final a in layer.altitudes) a.eval(ctx)], [45]);
      expect(layer.anchor.eval(ctx), 'viewport');
      expect(layer.exaggeration.eval(ctx), 0.5);
      expect(layer.shadowColors.single.eval(ctx), const Color(0xff000000));
      expect(layer.highlightColors.single.eval(ctx), const Color(0xffffffff));
      expect(layer.accentColor.eval(ctx), const Color(0xff000000));
      expect(layer.resampling.eval(ctx), 'linear');
    });

    test('a multidirectional hillshade reads one entry per light', () {
      final theme = const ThemeReader().read({
        'layers': [
          {
            'id': 'h',
            'type': 'hillshade',
            'source': 'dem',
            'paint': {
              'hillshade-method': 'multidirectional',
              'hillshade-illumination-direction': [270, 315, 0, 45],
              'hillshade-illumination-altitude': [30, 30, 30, 30],
              'hillshade-highlight-color': ['#fff', '#eee', '#ddd', '#ccc'],
              'hillshade-shadow-color': '#123',
              'hillshade-exaggeration': [
                'interpolate', ['linear'], ['zoom'], 5, 0.2, 10, 0.8, //
              ],
            },
          },
        ],
      });
      final layer = theme.layers.single as HillshadeThemeLayer;
      const ctx = EvalContext(zoom: 7.5);
      expect(layer.method.eval(ctx), 'multidirectional');
      expect(
          [for (final d in layer.directions) d.eval(ctx)], [270, 315, 0, 45]);
      expect(layer.altitudes, hasLength(4));
      expect(layer.highlightColors, hasLength(4));
      expect(layer.shadowColors.single.eval(ctx), const Color(0xff112233));
      expect(layer.exaggeration.eval(ctx), closeTo(0.5, 1e-9));
    });

    test('lights beyond the fourth are reported', () {
      final warnings = <String>[];
      ThemeReader(logger: Logger.custom(onWarn: warnings.add)).read({
        'layers': [
          {
            'id': 'h',
            'type': 'hillshade',
            'source': 'dem',
            'paint': {
              'hillshade-illumination-direction': [0, 60, 120, 180, 240],
            },
          },
        ],
      });
      expect(warnings.single, contains('only the first 4'));
    });

    test('the style reader keeps raster-dem sources with their encoding',
        () async {
      const styleUrl = 'https://maps.example.com/style.json';
      final client = MockClient((request) async {
        if (request.url.toString() != styleUrl) {
          return http.Response('not found', 404);
        }
        return http.Response(
          jsonEncode({
            'version': 8,
            'sources': {
              'mapbox': {
                'type': 'raster-dem',
                'tiles': ['https://dem.example.com/a/{z}/{x}/{y}.png'],
                'tileSize': 256,
                'maxzoom': 12,
              },
              'terrarium': {
                'type': 'raster-dem',
                'tiles': ['https://dem.example.com/b/{z}/{x}/{y}.png'],
                'encoding': 'terrarium',
              },
              'custom': {
                'type': 'raster-dem',
                'tiles': ['https://dem.example.com/c/{z}/{x}/{y}.png'],
                'encoding': 'custom',
                'redFactor': 2,
                'baseShift': 7,
              },
              'imagery': {
                'type': 'raster',
                'tiles': ['https://sat.example.com/{z}/{x}/{y}.jpg'],
              },
            },
            'layers': [
              {'id': 'h', 'type': 'hillshade', 'source': 'mapbox'},
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final style =
          await StyleReader(uri: styleUrl, httpClient: client, cache: false)
              .read();
      addTearDown(style.dispose);
      final sources = style.rasterSources;
      expect(sources['mapbox']!.encoding, DemEncoding.mapbox);
      expect(sources['mapbox']!.tileSize, 256);
      expect(sources['mapbox']!.provider.maximumZoom, 12);
      expect(sources['terrarium']!.encoding, DemEncoding.terrarium);
      expect(
        sources['custom']!.encoding,
        const DemEncoding(redFactor: 2, baseShift: 7),
      );
      expect(sources['imagery']!.encoding, isNull);
      expect(style.theme.layers.single, isA<HillshadeThemeLayer>());
    });

    test('the encodings decode as their documentation says', () {
      // Terrarium: (r * 256 + g + b / 256) - 32768.
      expect(DemEncoding.terrarium.elevation(128, 0, 0), 0);
      expect(DemEncoding.terrarium.elevation(131, 232, 128), 1000.5);
      // Mapbox: -10000 + (r * 256 * 256 + g * 256 + b) * 0.1.
      expect(DemEncoding.mapbox.elevation(1, 134, 160), closeTo(0, 1e-6));
      expect(DemEncoding.mapbox.elevation(1, 173, 176), closeTo(1000, 1e-6));
    });
  });

  group('geometry', () {
    test('neighbours wrap around the antimeridian and stop at the poles', () {
      expect(HillshadeRenderer.neighbourKey(const TileKey(3, 7, 2), 1, 0),
          const TileKey(3, 0, 2));
      expect(HillshadeRenderer.neighbourKey(const TileKey(3, 0, 2), -1, 1),
          const TileKey(3, 7, 3));
      expect(HillshadeRenderer.neighbourKey(const TileKey(3, 4, 0), 0, -1),
          isNull);
      expect(
          HillshadeRenderer.neighbourKey(const TileKey(3, 4, 7), 1, 1), isNull);
    });

    test('a display tile reads the neighbours of the edges it touches', () {
      // Same zoom: every edge.
      expect(HillshadeRenderer.neighboursNeeded(_key, _key), hasLength(8));
      // The top-left quarter of its DEM tile: west, north-west, north.
      expect(
        HillshadeRenderer.neighboursNeeded(
            const TileKey(13, 2 * _x, 2 * _y), _key),
        unorderedEquals([(-1, -1), (0, -1), (-1, 0)]),
      );
      // Deep inside a DEM tile: none.
      expect(
        HillshadeRenderer.neighboursNeeded(
            const TileKey(14, 4 * _x + 1, 4 * _y + 2), _key),
        isEmpty,
      );
    });

    test('slopes are normalised by the texel size, steepened below z15', () {
      // At zoom 15 and above only the texel size counts.
      expect(HillshadeRenderer.slopeScale(15, 256),
          closeTo(256 / math.pow(2, 28.2562 - 15), 1e-12));
      expect(HillshadeRenderer.slopeScale(16, 512),
          closeTo(512 / math.pow(2, 28.2562 - 16), 1e-12));
      // Below, MapLibre's exaggeration: 0.3 per level from 4.5 up.
      expect(HillshadeRenderer.slopeScale(12, 256),
          closeTo(256 / math.pow(2, -0.9 + 28.2562 - 12), 1e-12));
    });

    test('tile rows map to Web Mercator latitudes', () {
      expect(HillshadeRenderer.latitudeOf(0, 0), closeTo(85.0511, 1e-4));
      expect(HillshadeRenderer.latitudeOf(1, 1), closeTo(0, 1e-9));
      expect(HillshadeRenderer.latitudeOf(0, 1), closeTo(-85.0511, 1e-4));
    });
  });

  group('shading', skip: _noShaders, () {
    test('a uniform slope shades as MapLibre does', () async {
      final bytes = (await shade(
        layer: hillshadeLayer(),
        displayKey: _key,
        dems: await plane(10),
      ))!;
      // The Sobel kernel weighs a 20 m rise across two texels four
      // times over.
      final dx = 80 * HillshadeRenderer.slopeScale(_z, _dim);
      final latitude = HillshadeRenderer.latitudeOf(_z, _y) +
          (HillshadeRenderer.latitudeOf(_z, _y + 1) -
                  HillshadeRenderer.latitudeOf(_z, _y)) *
              128.5 /
              256;
      final expected = standardAlpha(dx, 0, latitude: latitude) * 255;
      expect(pixel(bytes, 128, 128).a, closeTo(expected, 1.5));
    });

    test('neighbours make the tile edges seamless', () async {
      final layer = hillshadeLayer();
      final seamless =
          (await shade(layer: layer, displayKey: _key, dems: await plane(10)))!;
      final inner = pixel(seamless, 128, 128);
      for (final x in [0, 1, 254, 255]) {
        for (final y in [0, 128, 255]) {
          expect(pixel(seamless, x, y), inner, reason: 'pixel $x,$y');
        }
      }
      // Alone, the tile's border is flat, and its edge columns shade
      // more lightly.
      final alone = (await shade(
        layer: layer,
        displayKey: _key,
        dems: await plane(10, neighbours: false),
      ))!;
      expect(pixel(alone, 128, 128), inner);
      expect(pixel(alone, 0, 128).a, lessThan(inner.a - 5));
      expect(pixel(alone, 255, 128).a, lessThan(inner.a - 5));
    });

    test('the lit side faces the light', () async {
      // Rising eastward, the ground faces west.
      final dems = await plane(30);
      Future<int> brightness(double direction) async {
        final p = pixel(
          (await shade(
            layer: hillshadeLayer(method: 'basic', directions: [direction]),
            displayKey: _key,
            dems: dems,
          ))!,
          128,
          128,
        );
        // Highlights are white, shadows black: brightness is the share
        // of colour in the alpha.
        return p.a == 0 ? 128 : (p.r * 255 / p.a).round();
      }

      expect(await brightness(270), greaterThan(200), reason: 'lit from west');
      expect(await brightness(90), lessThan(50), reason: 'lit from east');
    });

    test('north is the top of the tile', () async {
      // Rising southward, the ground faces north.
      final dems = {
        for (final dy in const [-1, 0, 1])
          for (final dx in const [-1, 0, 1])
            TileKey(_z, _x + dx, _y + dy):
                await demImage(_dim, (x, y) => 1000 + 30.0 * (dy * _dim + y)),
      };
      Future<int> brightness(double direction) async {
        final p = pixel(
          (await shade(
            layer: hillshadeLayer(method: 'basic', directions: [direction]),
            displayKey: _key,
            dems: dems,
          ))!,
          128,
          128,
        );
        return p.a == 0 ? 128 : (p.r * 255 / p.a).round();
      }

      expect(await brightness(0), greaterThan(200), reason: 'lit from north');
      expect(await brightness(180), lessThan(50), reason: 'lit from south');
    });

    test('a multidirectional hillshade averages its lights', () async {
      final dems = await plane(30);
      Future<({int r, int g, int b, int a})> at(
              List<double> directions) async =>
          pixel(
            (await shade(
              layer: hillshadeLayer(
                method: 'multidirectional',
                directions: directions,
              ),
              displayKey: _key,
              dems: dems,
            ))!,
            128,
            128,
          );
      final west = await at([270]);
      final east = await at([90]);
      final both = await at([270, 90]);
      expect(both.a, closeTo((west.a + east.a) / 2, 2));
      expect(both.r, closeTo((west.r + east.r) / 2, 2));
    });

    test('zero exaggeration draws nothing', () async {
      expect(
        await shade(
          layer: hillshadeLayer(exaggeration: 0),
          displayKey: _key,
          dems: await plane(10),
        ),
        isNull,
      );
    });

    test('nothing is drawn before the shaders are loaded', () async {
      HillshadePrograms.debugReset();
      addTearDown(() async {
        HillshadePrograms.debugReset();
        await HillshadePrograms.load();
      });
      expect(
        await shade(
          layer: hillshadeLayer(),
          displayKey: _key,
          dems: await plane(10),
        ),
        isNull,
      );
    });

    test('an overzoomed display tile shows its part of the DEM tile', () async {
      // Hills, so that position matters.
      final dems = {
        for (final dy in const [-1, 0, 1])
          for (final dx in const [-1, 0, 1])
            TileKey(_z, _x + dx, _y + dy): await demImage(_dim, (x, y) {
              final u = (dx * _dim + x) / _dim, v = (dy * _dim + y) / _dim;
              return 1000 + 400 * math.sin(u * 5) * math.cos(v * 3);
            }),
      };
      final layer = hillshadeLayer();
      final whole = (await shade(layer: layer, displayKey: _key, dems: dems))!;
      // The bottom-right quarter, shaded on its own at the next zoom.
      final quarter = (await shade(
        layer: layer,
        displayKey: const TileKey(_z + 1, 2 * _x + 1, 2 * _y + 1),
        dems: dems,
        demKey: _key,
      ))!;
      for (final (x, y) in const [
        (10, 10),
        (128, 128),
        (200, 60),
        (250, 250)
      ]) {
        final expected = pixel(whole, 128 + x ~/ 2, 128 + y ~/ 2);
        final actual = pixel(quarter, x, y);
        // The display zoom differs, the colours do not: only the
        // interpolation between texels does.
        expect(actual.a, closeTo(expected.a, 6), reason: 'pixel $x,$y');
      }
    });

    test('descendants standing in on zoom-out fill only their part', () async {
      const child = TileKey(_z + 1, 2 * _x, 2 * _y);
      final dems = {child: await demImage(_dim, (x, y) => 1000 + 30.0 * x)};
      final bytes = (await shade(
        layer: hillshadeLayer(),
        displayKey: _key,
        dems: dems,
        descendants: const [child],
      ))!;
      expect(pixel(bytes, 64, 64).a, greaterThan(0));
      expect(pixel(bytes, 192, 64).a, 0);
      expect(pixel(bytes, 64, 192).a, 0);
    });
  });

  group('on the map', skip: _noShaders, () {
    testWidgets('a hillshade layer shades the map, seamlessly', (tester) async {
      tester.view.physicalSize = const Size(512, 512);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      VectorTileLayer.clearMemoryCache();

      // East-facing hills, continuous across tiles: elevation is a
      // function of the texel's place in the world.
      final dem = _DemProvider((key, x, y) {
        final worldX = (key.x * _dim + x) / (_dim << key.z);
        return 1000 + 300 * math.sin(worldX * 2 * math.pi * (1 << 12));
      });
      const center = LatLng(46.0, 7.75);
      await tester.pumpWidget(MaterialApp(
        home: RepaintBoundary(
          key: _boundary,
          child: FlutterMap(
            options: const MapOptions(initialCenter: center, initialZoom: 14),
            children: [
              VectorTileLayer(
                theme: const ThemeReader().read({
                  'layers': [
                    {
                      'id': 'bg',
                      'type': 'background',
                      'paint': {'background-color': '#808080'},
                    },
                    {
                      'id': 'h',
                      'type': 'hillshade',
                      'source': 'dem',
                      // Across the east-west hills, so that the shading
                      // varies along the row.
                      'paint': {'hillshade-illumination-direction': 270},
                    },
                  ],
                }),
                tileProviders: const TileProviders({}),
                rasterSources: {
                  'dem': RasterTileSource(
                    provider: dem,
                    tileSize: 256,
                    encoding: DemEncoding.terrarium,
                  ),
                },
                tileOffset: TileOffset.none,
                tileFadeDuration: Duration.zero,
                diskCacheMaximumSizeInBytes: 0,
              ),
            ],
          ),
        ),
      ));

      // Pumped until the DEM tiles have stopped arriving and the screen
      // has caught up with them.
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (DateTime.now().isBefore(deadline) &&
          (dem.loads == 0 ||
              DateTime.now().difference(dem.lastLoad) <
                  const Duration(seconds: 1))) {
        await tester.pump(const Duration(milliseconds: 16));
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)));
      }
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)));
      }
      final row = await _row(tester, 256);
      expect(row.where((v) => v < 120), isNotEmpty,
          reason: 'slopes facing away from the light are shaded');

      // Tile seams fall on multiples of 256 world pixels; the screen's
      // left edge is not one, so find them from the camera.
      final worldLeft = (_lonToWorldX(center.longitude, 14) - 256).floor();
      final seams = [
        for (var x = 1; x < 511; x++)
          if ((worldLeft + x) % 256 == 0) x,
      ];
      expect(seams, isNotEmpty);
      for (final seam in seams) {
        // Across a seam the row follows the terrain: no dip or bump
        // against a straight line through the pixels four texels either
        // side. Shaded without its neighbours, a tile's edge texels lose
        // half their slope, which dips here by some 15 levels.
        final a = row[seam - 16], b = row[seam + 16];
        for (var x = seam - 16; x <= seam + 16; x++) {
          final straight = a + (b - a) * (x - seam + 16) / 32;
          expect((row[x] - straight).abs(), lessThanOrEqualTo(5),
              reason: 'pixel $x by the seam at $seam');
        }
      }
      // The neighbours beyond the visible grid were asked for too.
      final visibleX = {for (final k in dem.served) k.x};
      expect(visibleX.length, greaterThanOrEqualTo(4));

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  });
}

/// `flutter test --platform chrome` serves the test no assets at all,
/// shaders included, so nothing can be shaded there. The web demo
/// (`compare/`) is where hillshading is checked on the web.
const Object _noShaders = kIsWeb
    ? 'flutter test --platform chrome serves no assets, so no shaders'
    : false;

const _boundary = ValueKey('hillshade-boundary');

double _lonToWorldX(double lon, int z) => (lon + 180) / 360 * (256 << z);

/// The red channel of row [y] of the rendered map.
Future<List<int>> _row(WidgetTester tester, int y) async {
  final boundary =
      tester.renderObject<RenderRepaintBoundary>(find.byKey(_boundary));
  final image = boundary.toImageSync();
  final row = await tester.runAsync(() async {
    final data = (await image.toByteData())!;
    return [
      for (var x = 0; x < image.width; x++)
        data.getUint8((y * image.width + x) * 4),
    ];
  });
  image.dispose();
  return row!;
}

class _DemProvider extends VectorTileProvider {
  final double Function(TileKey key, int x, int y) elevation;
  final served = <TileKey>{};
  var loads = 0;
  var lastLoad = DateTime.now();

  _DemProvider(this.elevation);

  @override
  String get cacheKey => 'test-dem';

  @override
  int get maximumZoom => 20;

  @override
  int get minimumZoom => 0;

  @override
  Future<TileResponse> load(TileKey tile,
      {CancellationToken? cancellation}) async {
    loads++;
    lastLoad = DateTime.now();
    served.add(tile);
    return TileResponseData(demBmp(_dim, (x, y) => elevation(tile, x, y)));
  }
}
