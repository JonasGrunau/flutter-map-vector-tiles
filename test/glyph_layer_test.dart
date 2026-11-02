import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart' hide Theme;
import 'package:flutter/rendering.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_vector_tiles/flutter_map_vector_tiles.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'fixtures/glyph_pbf_builder.dart';
import 'fixtures/lifecycle_harness.dart';
import 'fixtures/mvt_builder.dart';

/// `VectorTileLayer.glyphs` end to end: a tile's labels wait for the
/// glyph ranges they need instead of showing in a system font first,
/// and a layer that goes away while they wait leaves nothing behind.

const _stack = 'Test Regular';

Uint8List _labelledTile([String name = 'AAAA']) => MvtTileBuilder()
    .layer('poi', extent: extent)
    .feature(
      type: 1,
      geometry: [cmd(1, 1), zig(extent ~/ 2), zig(extent ~/ 2)],
      properties: {'name': name},
    )
    .done()
    .build();

/// The label tile at the map's centre, (14, 8726, 5683), and empty
/// tiles everywhere else, so exactly one label is on screen.
class _OneLabelProvider extends CountingProvider {
  _OneLabelProvider({this.name = 'AAAA'});

  final String name;

  @override
  String get cacheKey => 'one-label-$name';

  @override
  Future<TileResponse> load(TileKey tile,
      {CancellationToken? cancellation}) async {
    note(tile);
    return TileResponseData(tile == const TileKey(14, 8726, 5683)
        ? _labelledTile(name)
        : MvtTileBuilder().build());
  }
}

Theme _theme() => const ThemeReader().read({
      'layers': [
        {
          'id': 'bg',
          'type': 'background',
          'paint': {'background-color': '#0000ff'},
        },
        {
          'id': 'poi',
          'type': 'symbol',
          'source': 's',
          'source-layer': 'poi',
          'layout': {
            'text-field': '{name}',
            'text-size': 40,
            'text-font': [_stack],
          },
          'paint': {'text-color': '#00ff00'},
        },
      ],
    });

/// A glyph source whose ranges load only once [gate] completes,
/// counting its loads.
class _GatedGlyphs {
  final gate = Completer<void>();
  var loads = 0;
  late final source = GlyphSource(
    load: (stack, start) async {
      loads++;
      await gate.future;
      return GlyphPbfBuilder()
          .stack(stack, '$start-${start + 255}', [TestGlyph(0x41)]).build();
    },
    signature: 'gated',
  );
}

/// The map's centre tile, (14, 8726, 5683), gets its own data — a green
/// 'AAAA' over a yellow square — only once [gate] completes. Until then
/// it is drawn from its parent, (13, 4363, 2841), whose red
/// [ancestorName] sits right where the tile's own label does.
class _AncestorLabelProvider extends CountingProvider {
  _AncestorLabelProvider({required this.ancestorName, required this.key});

  final String ancestorName;
  final String key;
  final gate = Completer<void>();

  @override
  String get cacheKey => key;

  @override
  Future<TileResponse> load(TileKey tile,
      {CancellationToken? cancellation}) async {
    note(tile);
    if (tile == const TileKey(13, 4363, 2841)) {
      // The centre tile's quadrant of it: the left half, the bottom half.
      return TileResponseData(_colouredLabelTile(
          ancestorName, '#ff0000', extent ~/ 4, 3 * extent ~/ 4));
    }
    if (tile == const TileKey(14, 8726, 5683)) {
      await gate.future;
      return TileResponseData(_colouredLabelTile(
          'AAAA', '#00ff00', extent ~/ 2, extent ~/ 2,
          square: true));
    }
    return TileResponseData(MvtTileBuilder().build());
  }
}

/// A label [name] in [color] at ([x], [y]), and with [square] a yellow
/// square in the tile's top-left corner, so that the tile draws an image
/// of its own.
Uint8List _colouredLabelTile(String name, String color, int x, int y,
    {bool square = false}) {
  final builder = MvtTileBuilder();
  builder.layer('poi', extent: extent).feature(
    type: 1,
    geometry: [cmd(1, 1), zig(x), zig(y)],
    properties: {'name': name, 'color': color},
  ).done();
  if (square) {
    const q = extent ~/ 4;
    builder.layer('own', extent: extent).feature(type: 3, geometry: [
      cmd(1, 1), zig(0), zig(0), //
      cmd(2, 3), zig(q), zig(0), zig(0), zig(q), zig(-q), zig(0),
      cmd(7, 1),
    ]).done();
  }
  return builder.build();
}

/// Labels in their feature's colour, from z14 on: the parent tile shows
/// none of its own at z13, and asks for no glyphs there.
Theme _ancestorTheme() => const ThemeReader().read({
      'layers': [
        {
          'id': 'bg',
          'type': 'background',
          'paint': {'background-color': '#0000ff'},
        },
        {
          'id': 'own',
          'type': 'fill',
          'source': 's',
          'source-layer': 'own',
          'paint': {'fill-color': '#ffff00'},
        },
        {
          'id': 'poi',
          'type': 'symbol',
          'source': 's',
          'source-layer': 'poi',
          'minzoom': 14,
          'layout': {
            'text-field': '{name}',
            'text-size': 40,
            'text-font': [_stack],
          },
          'paint': {
            'text-color': ['get', 'color'],
          },
        },
      ],
    });

/// Glyph ranges 0 and 256, each loading once its own gate completes,
/// recording the ranges asked for.
class _RangeGatedGlyphs {
  _RangeGatedGlyphs(this.signature);

  final String signature;
  final gate0 = Completer<void>();
  final gate256 = Completer<void>();
  final asked = <int>[];
  late final source = GlyphSource(
    load: (stack, start) async {
      asked.add(start);
      await (start == 256 ? gate256 : gate0).future;
      return GlyphPbfBuilder().stack(stack, '$start-${start + 255}', [
        TestGlyph(0x41),
        TestGlyph(0x42),
        TestGlyph(0x110),
      ]).build();
    },
    signature: signature,
  );
}

Widget _app(
  VectorTileProvider provider,
  GlyphSource glyphs, {
  MapController? controller,
  double initialZoom = 14,
  Theme? theme,
  LabelMode labelMode = LabelMode.screen,
}) =>
    MaterialApp(
      home: RepaintBoundary(
        key: boundaryKey,
        child: FlutterMap(
          mapController: controller,
          options: MapOptions(
            initialCenter: const LatLng(48.1725, 11.7375),
            initialZoom: initialZoom,
          ),
          children: [
            VectorTileLayer(
              theme: theme ?? _theme(),
              tileProviders: TileProviders({'s': provider}),
              glyphs: glyphs,
              labelMode: labelMode,
              tileOffset: TileOffset.none,
              tileFadeDuration: Duration.zero,
              labelFadeDuration: Duration.zero,
              concurrency: 1,
              diskCacheMaximumSizeInBytes: 0,
            ),
          ],
        ),
      ),
    );

/// How many pixels show the label colour. The test font of the
/// platform path draws the one label, 'AAAA', as four solid 40 px
/// blocks, several thousand pixels; the glyph path draws four 17×23 px
/// boxes, about 1,500.
Future<int> _labelPixels(WidgetTester tester) async {
  final boundary =
      tester.renderObject<RenderRepaintBoundary>(find.byKey(boundaryKey));
  final image = boundary.toImageSync();
  final count = await tester.runAsync(() async {
    final data = (await image.toByteData())!;
    var n = 0;
    for (var i = 0; i < data.lengthInBytes; i += 4) {
      if (data.getUint8(i) == 0 &&
          data.getUint8(i + 1) == 0xff &&
          data.getUint8(i + 2) == 0 &&
          data.getUint8(i + 3) == 0xff) {
        n++;
      }
    }
    return n;
  });
  image.dispose();
  return count!;
}

Future<bool> _hasLabel(WidgetTester tester) async =>
    await _labelPixels(tester) > 0;

/// Below this many label pixels the label is drawn from glyphs.
const _glyphLabelPixels = 3000;

/// Pumps until a symbols job has asked for the glyph range — and so is
/// waiting for it — then a few frames more. Not [settleLoads]: the wait
/// limit runs on the test's fake clock, which a settle of a second of
/// real time advances by several seconds.
Future<void> _untilParked(WidgetTester tester, _GatedGlyphs glyphs) async {
  expect(await pumpUntil(tester, () async => glyphs.loads > 0), isTrue);
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// [n] frames of 16 ms, each with a moment of real time for loads and
/// decodes to move — a few seconds at most on the fake clock, well
/// short of the glyph wait limit.
Future<void> _frames(WidgetTester tester, int n) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
  }
}

/// How many pixels show the ancestor's red label and the tile's own
/// green one.
Future<({int red, int green})> _labelColours(WidgetTester tester) async {
  final boundary =
      tester.renderObject<RenderRepaintBoundary>(find.byKey(boundaryKey));
  final image = boundary.toImageSync();
  final count = await tester.runAsync(() async {
    final data = (await image.toByteData())!;
    var red = 0, green = 0;
    for (var i = 0; i < data.lengthInBytes; i += 4) {
      final r = data.getUint8(i), g = data.getUint8(i + 1);
      final b = data.getUint8(i + 2);
      if (r > 200 && g < 60 && b < 60) red++;
      if (g > 200 && r < 60 && b < 60) green++;
    }
    return (red: red, green: green);
  });
  image.dispose();
  return count!;
}

void main() {
  setUp(VectorTileLayer.clearMemoryCache);

  testWidgets('labels wait for their glyphs instead of switching fonts',
      (tester) async {
    tester.view.physicalSize = const Size(600, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final glyphs = _GatedGlyphs();
    final provider = _OneLabelProvider();
    await tester.pumpWidget(_app(provider, glyphs.source));
    await _untilParked(tester, glyphs);
    // Its labels are held back.
    expect(glyphs.loads, 1, reason: 'one range, asked for once');
    expect(await _hasLabel(tester), isFalse,
        reason: 'shaping waits for the glyph range');

    await tester.runAsync(() async => glyphs.gate.complete());
    expect(await pumpUntil(tester, () => _hasLabel(tester)), isTrue,
        reason: 'the parked symbols resume once the range is in');
    expect(await _labelPixels(tester), lessThan(_glyphLabelPixels),
        reason: 'drawn from the glyphs');
    expect(glyphs.loads, 1);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    glyphs.source.dispose();
  });

  testWidgets('a layer disposed while its labels wait for glyphs lets go',
      (tester) async {
    tester.view.physicalSize = const Size(600, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final glyphs = _GatedGlyphs();
    final provider = _OneLabelProvider();
    await tester.pumpWidget(_app(provider, glyphs.source));
    await _untilParked(tester, glyphs);
    expect(glyphs.loads, 1);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    // The range arriving after the layer is gone must not resurrect its
    // jobs: nothing throws, nothing is scheduled.
    await tester.runAsync(() async => glyphs.gate.complete());
    expect(
        await pumpUntil(
            tester, () async => glyphs.source.rangeOf(_stack, 0) != null),
        isTrue);
    expect(tester.takeException(), isNull);
    glyphs.source.dispose();
  });

  testWidgets(
      'labels stop waiting for glyphs that do not come, and switch '
      'once they do', (tester) async {
    tester.view.physicalSize = const Size(600, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final glyphs = _GatedGlyphs();
    final provider = _OneLabelProvider();
    await tester.pumpWidget(_app(provider, glyphs.source));
    await _untilParked(tester, glyphs);
    expect(await _hasLabel(tester), isFalse);

    // A request hanging on a bad connection: past the wait limit the
    // labels are shaped by the platform rather than left off the map.
    await tester.pump(const Duration(seconds: 5));
    expect(await pumpUntil(tester, () => _hasLabel(tester)), isTrue);
    expect(await _labelPixels(tester), greaterThan(_glyphLabelPixels),
        reason: 'the system font, while the range is still on its way');

    await tester.runAsync(() async => glyphs.gate.complete());
    expect(
        await pumpUntil(tester,
            () async => (await _labelPixels(tester)) < _glyphLabelPixels),
        isTrue,
        reason: 'the style font once the range arrives');

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    glyphs.source.dispose();
  });

  testWidgets('labels whose glyph range fails at once use the system font',
      (tester) async {
    tester.view.physicalSize = const Size(600, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    // What no network looks like: every range fails straight away.
    var loads = 0;
    final glyphs = GlyphSource(
      load: (stack, start) async {
        loads++;
        throw StateError('Failed host lookup');
      },
      signature: 'offline',
    );
    final provider = _OneLabelProvider();
    await tester.pumpWidget(_app(provider, glyphs));
    expect(await pumpUntil(tester, () => _hasLabel(tester)), isTrue,
        reason: 'the label is shaped by the platform once its range failed');
    expect(await _labelPixels(tester), greaterThan(_glyphLabelPixels));
    expect(loads, 1);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    glyphs.dispose();
  });

  testWidgets('labels waiting on several ranges at once still appear',
      (tester) async {
    // Regression: waiting on two ranges at once handed the pump a
    // Future<List<void>>, whose `timeout` threw at the wait limit's
    // callback inside the pump, and the tile's labels never came.
    tester.view.physicalSize = const Size(600, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final gate = Completer<void>();
    final glyphs = GlyphSource(
      load: (stack, start) async {
        await gate.future;
        return GlyphPbfBuilder().stack(stack, '$start-${start + 255}', [
          TestGlyph(0x41),
          TestGlyph(0x110),
        ]).build();
      },
      signature: 'two ranges',
    );
    final provider = _OneLabelProvider(name: 'AĐAĐ');
    await tester.pumpWidget(_app(provider, glyphs));
    expect(await pumpUntil(tester, () async => provider.loads > 0), isTrue);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(tester.takeException(), isNull);
    expect(await _hasLabel(tester), isFalse);

    await tester.runAsync(() async => gate.complete());
    expect(await pumpUntil(tester, () => _hasLabel(tester)), isTrue);
    expect(await _labelPixels(tester), lessThan(_glyphLabelPixels),
        reason: 'drawn from the glyphs');

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    glyphs.dispose();
  });

  for (final mode in LabelMode.values) {
    testWidgets(
        'labels drawn from an ancestor and waiting on glyphs do not come '
        'back over the tile\'s own (${mode.name} labels)', (tester) async {
      // Regression: the provisional render's symbols job, parked on the
      // same range as the final one, resumed after it and published the
      // ancestor's labels over the tile's own — in tile mode, as a
      // provisional image that never let the retained level go.
      tester.view.physicalSize = const Size(600, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final glyphs = _RangeGatedGlyphs('ancestor-labels-${mode.name}');
      final provider = _AncestorLabelProvider(
          ancestorName: 'BBBB', key: 'ancestor-labels-${mode.name}');
      final controller = MapController();
      await tester.pumpWidget(_app(provider, glyphs.source,
          controller: controller,
          initialZoom: 13,
          theme: _ancestorTheme(),
          labelMode: mode));
      await settleLoads(tester, provider, painted: false);
      expect(glyphs.asked, isEmpty);

      // At z14 the tile's data is held back: it is drawn from its parent,
      // whose label waits for range 0.
      controller.move(const LatLng(48.1725, 11.7375), 14);
      expect(
          await pumpUntil(tester, () async => glyphs.asked.isNotEmpty), isTrue);
      await _frames(tester, 10);

      // Its own data arrives; its own label waits for the same range.
      await tester.runAsync(() async => provider.gate.complete());
      await _frames(tester, 30);
      expect(glyphs.asked, [0]);

      await tester.runAsync(() async => glyphs.gate0.complete());
      await _frames(tester, 60);
      final colours = await _labelColours(tester);
      expect(colours.green, greaterThan(0), reason: 'the tile\'s own label');
      expect(colours.red, 0, reason: 'no label of the ancestor');

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      glyphs.source.dispose();
    });
  }

  testWidgets(
      'labels drawn from an ancestor and waiting on a range the tile\'s '
      'own labels do not need are dropped once those are in', (tester) async {
    // Regression: the provisional render's symbols job, parked on range
    // 256, resumed after the final labels had published and replaced
    // them with the ancestor's.
    tester.view.physicalSize = const Size(600, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final glyphs = _RangeGatedGlyphs('ancestor-labels-other-range');
    glyphs.gate0.complete();
    final provider = _AncestorLabelProvider(
        ancestorName: 'BĐBĐ', key: 'ancestor-labels-other-range');
    final controller = MapController();
    await tester.pumpWidget(_app(provider, glyphs.source,
        controller: controller, initialZoom: 13, theme: _ancestorTheme()));
    await settleLoads(tester, provider, painted: false);
    expect(glyphs.asked, isEmpty);

    controller.move(const LatLng(48.1725, 11.7375), 14);
    expect(await pumpUntil(tester, () async => glyphs.asked.contains(256)),
        isTrue);
    await _frames(tester, 10);

    // 'AAAA' needs range 0 alone, which is in: the tile's own label shows.
    await tester.runAsync(() async => provider.gate.complete());
    expect(
        await pumpUntil(
            tester, () async => (await _labelColours(tester)).green > 0,
            timeout: const Duration(seconds: 5)),
        isTrue);

    await tester.runAsync(() async => glyphs.gate256.complete());
    await _frames(tester, 40);
    final colours = await _labelColours(tester);
    expect(colours.green, greaterThan(0), reason: 'the tile\'s own label');
    expect(colours.red, 0, reason: 'no label of the ancestor');

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    glyphs.source.dispose();
  });
}
