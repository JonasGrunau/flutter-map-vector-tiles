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

Widget _app(VectorTileProvider provider, GlyphSource glyphs) => MaterialApp(
      home: RepaintBoundary(
        key: boundaryKey,
        child: FlutterMap(
          options: const MapOptions(
            initialCenter: LatLng(48.1725, 11.7375),
            initialZoom: 14,
          ),
          children: [
            VectorTileLayer(
              theme: _theme(),
              tileProviders: TileProviders({'s': provider}),
              glyphs: glyphs,
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
}
