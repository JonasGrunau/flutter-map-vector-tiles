import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_map_vector_tiles/src/render/label_painter.dart';
import 'package:flutter_map_vector_tiles/src/render/symbol_layouter.dart';
import 'package:flutter_map_vector_tiles/src/style/theme.dart';
import 'package:flutter_map_vector_tiles/src/style/theme_reader.dart';
import 'package:flutter_map_vector_tiles/src/text/glyph_source.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/glyph_pbf_builder.dart';
import 'fixtures/label_ids.dart';

/// Labels drawn from a style's glyphs: which text takes that path, how
/// it is measured and drawn, and how it waits for and falls back from
/// its glyph ranges.
///
/// The test font's glyphs are solid boxes — 10×14 px at the PBFs'
/// 24 px em, advancing 12, their top 7 px above the middle of the line
/// (17 px less `top` -10) — so at `text-size` 24 and a pixel ratio of 1
/// every metric below is a whole pixel and every glyph a known
/// rectangle.

const _stack = 'Test Regular';

/// Glyphs for Basic Latin letters, a space and 'Đ' (in the next range).
Uint8List _range(int start) =>
    GlyphPbfBuilder().stack(_stack, '$start-${start + 255}', [
      if (start == 0) ...[
        for (final c in 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'.codeUnits) TestGlyph(c),
        TestGlyph(0x20, width: 0, height: 0, advance: 6, blank: true),
      ],
      if (start == 256) TestGlyph(0x110),
    ]).build();

/// A glyph source serving [_range], recording what it is asked for;
/// [gate], when given, holds every load until it completes.
GlyphSource _source(
        {List<(String, int)>? requests,
        Future<void>? gate,
        bool fail = false}) =>
    GlyphSource(
      load: (stack, start) async {
        requests?.add((stack, start));
        if (gate != null) await gate;
        if (fail || stack != _stack) throw StateError('no such range');
        return _range(start);
      },
      signature: 'test',
    );

SymbolThemeLayer _layer({
  double size = 24,
  String color = '#00ff00',
  double haloWidth = 0,
  double haloBlur = 0,
  Map<String, Object?> layout = const {},
}) {
  final theme = const ThemeReader().read({
    'layers': [
      {
        'id': 'place',
        'type': 'symbol',
        'source': 's',
        'source-layer': 'place',
        'layout': {
          'text-field': '{name}',
          'text-size': size,
          'text-font': [_stack],
          ...layout,
        },
        'paint': {
          'text-color': color,
          'text-halo-color': '#ff0000',
          'text-halo-width': haloWidth,
          'text-halo-blur': haloBlur,
        },
      },
    ],
  });
  return theme.layers.single as SymbolThemeLayer;
}

PlacedSymbol _symbol(SymbolThemeLayer layer, String text, Offset at,
        {int order = 0}) =>
    PlacedSymbol(
      instance: SymbolInstance(
        layer: layer,
        layerIndex: 0,
        anchor: at,
        angle: 0,
        alongLine: false,
        text: text,
        iconName: null,
        sortKey: 0,
        properties: const {},
        geometryType: 'Point',
        featureId: null,
      ),
      id: labelIdOf((text, at)),
      screenAnchor: at,
      screenAngle: 0,
      order: order,
    );

var _generation = 0;

/// Paints one frame of [symbols] onto a 200×100 white canvas, and
/// returns what was drawn and the frame's pixels.
Future<(List<PlacedSymbol>, ByteData)> _paint(
  LabelPainter painter,
  List<PlacedSymbol> symbols,
) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)
    ..drawColor(const Color(0xffffffff), BlendMode.src);
  final drawn = painter.paint(
    canvas: canvas,
    screenSize: const Size(200, 100),
    styleZoom: 12,
    symbols: symbols,
    placementGeneration: _generation++,
  );
  final image = await recorder.endRecording().toImage(200, 100);
  final pixels = (await image.toByteData())!;
  image.dispose();
  return (drawn, pixels);
}

int _argb(ByteData pixels, int x, int y) {
  final i = (y * 200 + x) * 4;
  return (pixels.getUint8(i + 3) << 24) |
      (pixels.getUint8(i) << 16) |
      (pixels.getUint8(i + 1) << 8) |
      pixels.getUint8(i + 2);
}

/// Loads every range [symbols] need into [painter]'s glyphs.
Future<void> _load(LabelPainter painter, List<PlacedSymbol> symbols) async {
  await painter.glyphsPending([for (final s in symbols) s.instance], 12);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Latin text is shaped from glyphs and measured by their advances',
      () async {
    final glyphs = _source();
    final painter = LabelPainter()..glyphs = glyphs;
    final layer = _layer();
    // 'ABC' advances 36 px at size 24: its box spans 82..118, 80..120
    // with the default 2 px padding. 'A' at 130 (122..138, padded
    // 120..140) fits beside it; at 125 it would not. Platform text
    // ('ABC' 72 px wide in the test font) would reach past 130.
    List<PlacedSymbol> pair(double x) => [
          _symbol(layer, 'ABC', const Offset(100, 50)),
          _symbol(layer, 'A', Offset(x, 50), order: 1),
        ];
    await _load(painter, pair(130));
    expect((await _paint(painter, pair(130))).$1, hasLength(2));
    expect((await _paint(LabelPainter()..glyphs = glyphs, pair(125))).$1,
        hasLength(1));
    expect(painter.debugGlyphShapedTextCount, 2);
    expect(painter.debugShapedTextCount, 2);
    painter.dispose();
    glyphs.dispose();
  });

  test('draws each glyph where its metrics put it, in the text colour',
      () async {
    final glyphs = _source();
    final painter = LabelPainter()..glyphs = glyphs;
    final symbols = [_symbol(_layer(), 'AB', const Offset(100, 50))];
    await _load(painter, symbols);
    final (drawn, pixels) = await _paint(painter, symbols);
    expect(drawn, hasLength(1));
    // 'AB' is 24 px wide and one 28.8 px line high, centred on the
    // anchor: its block starts at (88, 35.6). 'A' draws its 10×14 box
    // 1 px right of the pen and 7 px above the middle of the line —
    // columns 89 to 99, rows 43 to 57 — and 'B' 12 px further right.
    // The edges ramp over 1.68 px as in MapLibre, so only pixels clear
    // of them are pure.
    const green = 0xff00ff00;
    expect(_argb(pixels, 94, 50), green);
    expect(_argb(pixels, 106, 50), green);
    expect(_argb(pixels, 90, 44), green);
    expect(_argb(pixels, 97, 55), green);
    expect(_argb(pixels, 94, 40), 0xffffffff);
    expect(_argb(pixels, 94, 60), 0xffffffff);
    expect(_argb(pixels, 86, 50), 0xffffffff);
    painter.dispose();
    glyphs.dispose();
  });

  test('a halo surrounds the glyphs, under their fill', () async {
    final glyphs = _source();
    final painter = LabelPainter()..glyphs = glyphs;
    final symbols = [
      _symbol(_layer(haloWidth: 3), 'AB', const Offset(100, 50)),
    ];
    await _load(painter, symbols);
    final (_, pixels) = await _paint(painter, symbols);
    const red = 0xffff0000;
    expect(_argb(pixels, 94, 50), 0xff00ff00); // fill over the halo
    expect(_argb(pixels, 87, 50), red); // 1.5 px left of 'A'
    expect(_argb(pixels, 94, 41), red); // 1.5 px above 'A'
    expect(_argb(pixels, 84, 50), 0xffffffff); // past the 3 px halo
    painter.dispose();
    glyphs.dispose();
  });

  test('text-halo-blur softens a glyph halo\'s edge', () async {
    // How many pixels of the row through 'A' fade between the white
    // background and the red halo, left of the glyph. Compared between
    // two renders on one renderer, never against fixed values. At size
    // 48 a 4 px halo blurred by 2 px stays inside the glyph's 3 px
    // distance-field border (6 px here), which would cut its ramp off.
    Future<int> fading(double blur) async {
      final glyphs = _source();
      final painter = LabelPainter()..glyphs = glyphs;
      final symbols = [
        _symbol(_layer(size: 48, haloWidth: 4, haloBlur: blur), 'AB',
            const Offset(100, 50)),
      ];
      await _load(painter, symbols);
      final (drawn, pixels) = await _paint(painter, symbols);
      expect(drawn, hasLength(1));
      expect(painter.debugGlyphShapedTextCount, 1);
      painter.dispose();
      glyphs.dispose();
      var count = 0;
      // 'A' starts at column 78; its halo reaches out to the left.
      for (var x = 62; x < 78; x++) {
        final argb = _argb(pixels, x, 50);
        if (argb != 0xffffffff && argb != 0xffff0000) count++;
      }
      return count;
    }

    final sharp = await fading(0);
    final blurred = await fading(2);
    expect(sharp, greaterThan(0));
    expect(blurred, greaterThan(sharp + 1));
  });

  test('text-justify and text-line-height lay glyph lines out', () async {
    final glyphs = _source();
    final painter = LabelPainter()..glyphs = glyphs;
    final symbols = [
      _symbol(_layer(layout: {'text-justify': 'left', 'text-line-height': 2}),
          'ABCD\nA', const Offset(100, 50)),
    ];
    await _load(painter, symbols);
    final (drawn, pixels) = await _paint(painter, symbols);
    expect(drawn, hasLength(1));
    expect(painter.debugGlyphShapedTextCount, 1);
    // 'ABCD' is 48 px wide and the two 2 em lines 96 px high, centred on
    // the anchor: the block starts at (76, 2) and the second line's
    // middle is 72 px down. 'A' sits at the block's left edge, its box
    // columns 77 to 87 and rows 67 to 81; centred, it would start at 95,
    // and with 1.2 em lines end at row 71.
    expect(_argb(pixels, 82, 77), 0xff00ff00);
    expect(_argb(pixels, 92, 77), 0xffffffff);
    painter.dispose();
    glyphs.dispose();
  });

  test('text-justify auto aligns glyph lines to the variable anchor', () async {
    final glyphs = _source();
    final painter = LabelPainter()..glyphs = glyphs;
    final symbols = [
      _symbol(
          _layer(layout: {
            'text-justify': 'auto',
            'text-variable-anchor': ['left'],
          }),
          'ABCD\nA',
          const Offset(60, 50)),
    ];
    await _load(painter, symbols);
    final (drawn, pixels) = await _paint(painter, symbols);
    expect(drawn, hasLength(1));
    // Anchored at its left, the block spans 60 to 108 and the second
    // line's middle is row 64.4. Justified left, 'A' covers columns 61
    // to 71 there; centred, it would start at 79.
    expect(_argb(pixels, 66, 64), 0xff00ff00);
    expect(_argb(pixels, 84, 64), 0xffffffff);
    painter.dispose();
    glyphs.dispose();
  });

  test('glyph cells are rasterized once and reused while the size holds',
      () async {
    final glyphs = _source();
    final painter = LabelPainter()..glyphs = glyphs;
    final small = [_symbol(_layer(), 'ABBA', const Offset(100, 50))];
    await _load(painter, small);
    await _paint(painter, small);
    final atlas = painter.debugGlyphAtlas;
    // Two distinct glyphs, fill only.
    expect(atlas.debugCellCount, 2);
    await _paint(painter, small);
    expect(atlas.debugCellCount, 2);
    // Another size is another cell per glyph.
    await _paint(
        painter, [_symbol(_layer(size: 30), 'AB', const Offset(100, 50))]);
    expect(atlas.debugCellCount, 4);
    painter.dispose();
    glyphs.dispose();
  });

  test('text in scripts that need shaping keeps the platform', () async {
    final glyphs = _source();
    final painter = LabelPainter()..glyphs = glyphs;
    final symbols = [
      _symbol(_layer(), 'שלום', const Offset(60, 50)),
      _symbol(_layer(), 'AB', const Offset(150, 50), order: 1),
    ];
    // The Hebrew label asks for no range at all.
    final requests = <(String, int)>[];
    final recording = _source(requests: requests);
    await (LabelPainter()..glyphs = recording)
        .glyphsPending([for (final s in symbols) s.instance], 12);
    expect(requests, [(_stack, 0)]);
    await _load(painter, symbols);
    final (drawn, _) = await _paint(painter, symbols);
    expect(drawn, hasLength(2));
    expect(painter.debugShapedTextCount, 2);
    expect(painter.debugGlyphShapedTextCount, 1);
    painter.dispose();
    glyphs.dispose();
    recording.dispose();
  });

  test('a code point the font lacks keeps the platform', () async {
    final glyphs = _source();
    final painter = LabelPainter()..glyphs = glyphs;
    // 'É' is in the first range, which this font has, but not in it.
    final symbols = [_symbol(_layer(), 'ÉA', const Offset(100, 50))];
    await _load(painter, symbols);
    await _paint(painter, symbols);
    expect(painter.debugGlyphShapedTextCount, 0);
    expect(painter.debugShapedTextCount, 1);
    painter.dispose();
    glyphs.dispose();
  });

  test('a range that failed to load keeps the platform', () async {
    final glyphs = _source(fail: true);
    final painter = LabelPainter()..glyphs = glyphs;
    final symbols = [_symbol(_layer(), 'AB', const Offset(100, 50))];
    await _load(painter, symbols);
    // Settled, failed: nothing is pending any more.
    expect(painter.glyphsPending([symbols.single.instance], 12), isNull);
    final (drawn, _) = await _paint(painter, symbols);
    expect(drawn, hasLength(1));
    expect(painter.debugGlyphShapedTextCount, 0);
    painter.dispose();
    glyphs.dispose();
  });

  test('glyphsPending asks for each range the text needs, once', () async {
    final requests = <(String, int)>[];
    final gate = Completer<void>();
    final glyphs = _source(requests: requests, gate: gate.future);
    final painter = LabelPainter()..glyphs = glyphs;
    final instances = [
      _symbol(_layer(), 'AB', Offset.zero).instance,
      _symbol(_layer(), 'ĐA', Offset.zero).instance,
      _symbol(_layer(), 'BA', Offset.zero).instance,
    ];
    final first = painter.glyphsPending(instances, 12);
    expect(first, isNotNull);
    // Asked again while loading: the same wait, no second request.
    expect(painter.glyphsPending(instances, 12), isNotNull);
    expect(requests, unorderedEquals([(_stack, 0), (_stack, 256)]));
    gate.complete();
    await first;
    expect(painter.glyphsPending(instances, 12), isNull);
    expect(requests, hasLength(2));
    // Without glyphs nothing is ever pending.
    expect(LabelPainter().glyphsPending(instances, 12), isNull);
    painter.dispose();
    glyphs.dispose();
  });

  test('text shaped while its glyphs loaded is shaped again once they are in',
      () async {
    final gate = Completer<void>();
    final glyphs = _source(gate: gate.future);
    final painter = LabelPainter()..glyphs = glyphs;
    final symbols = [_symbol(_layer(), 'AB', const Offset(100, 50))];
    final loading = painter.glyphsPending([symbols.single.instance], 12)!;
    // The label pass does not wait: the platform shapes it meanwhile.
    await _paint(painter, symbols);
    expect(painter.debugGlyphShapedTextCount, 0);
    gate.complete();
    await loading;
    final (_, pixels) = await _paint(painter, symbols);
    expect(painter.debugGlyphShapedTextCount, 1);
    expect(_argb(pixels, 94, 50), 0xff00ff00);
    painter.dispose();
    glyphs.dispose();
  });

  test('replacing the glyphs shapes everything again', () async {
    final first = _source();
    final second = _source();
    final painter = LabelPainter()..glyphs = first;
    final symbols = [_symbol(_layer(), 'AB', const Offset(100, 50))];
    await _load(painter, symbols);
    await _paint(painter, symbols);
    painter.glyphs = second;
    await _load(painter, symbols);
    await _paint(painter, symbols);
    expect(painter.debugGlyphShapedTextCount, 2);
    painter.glyphs = null;
    await _paint(painter, symbols);
    expect(painter.debugShapedTextCount, 3);
    expect(painter.debugGlyphShapedTextCount, 2);
    painter.dispose();
    first.dispose();
    second.dispose();
  });

  test('LabelMode.tile draws glyph text into the tile', () async {
    final glyphs = _source();
    final painter = LabelPainter()..glyphs = glyphs;
    final layer = _layer();
    final instance = _symbol(layer, 'AB', const Offset(128, 128)).instance;
    await painter.glyphsPending([instance], 12);
    painter.prewarm([instance], 12);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)
      ..drawColor(const Color(0xffffffff), BlendMode.src);
    final drawn =
        painter.paintTile(canvas: canvas, symbols: [instance], styleZoom: 12);
    final image = await recorder.endRecording().toImage(256, 256);
    final pixels = (await image.toByteData())!;
    image.dispose();
    expect(drawn, hasLength(1));
    // 'A' spans columns 117..127, rows 121..135 of the tile.
    const i = (128 * 256 + 122) * 4;
    expect([pixels.getUint8(i), pixels.getUint8(i + 1), pixels.getUint8(i + 2)],
        [0, 255, 0]);
    expect(painter.debugGlyphShapedTextCount, 1);
    painter.dispose();
    glyphs.dispose();
  });
}
