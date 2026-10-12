import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_map_vector_tiles/src/render/label_painter.dart';
import 'package:flutter_map_vector_tiles/src/render/symbol_layouter.dart';
import 'package:flutter_map_vector_tiles/src/style/theme.dart';
import 'package:flutter_map_vector_tiles/src/style/theme_reader.dart';
import 'package:flutter_test/flutter_test.dart';

/// Each paint models changed placement input; a constant would replay
/// the first pass forever once fades are on.
var _nextPlacementGeneration = 0;

SymbolThemeLayer _symbolLayer() {
  final theme = const ThemeReader().read({
    'layers': [
      {
        'id': 'poi',
        'type': 'symbol',
        'source': 's',
        'source-layer': 'poi',
        'layout': {
          'text-field': '{name}',
          'text-size': 14,
          // Every candidate lays out and draws, so the cache actually
          // cycles — collision rejections would hide the churn.
          'text-allow-overlap': true,
        },
      },
    ],
  });
  return theme.layers.single as SymbolThemeLayer;
}

PlacedSymbol _symbolAt(SymbolThemeLayer layer, Offset anchor, String text) =>
    PlacedSymbol(
      instance: SymbolInstance(
        layer: layer,
        layerIndex: 0,
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
      screenAnchor: anchor,
      screenAngle: 0,
    );

void _paintFrame(LabelPainter painter, List<PlacedSymbol> symbols) {
  final recorder = ui.PictureRecorder();
  painter.paint(
    canvas: Canvas(recorder),
    screenSize: const Size(400, 400),
    styleZoom: 12,
    symbols: symbols,
    placementGeneration: _nextPlacementGeneration++,
  );
  recorder.endRecording().dispose();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('cache eviction defers TextPainter disposal past the live frame', () {
    // Regression: the text/glyph caches leaked their TextPainters on
    // eviction and clear(). Disposal must also not be immediate — an
    // entry evicted mid-frame can still be referenced by a symbol
    // prepared earlier in the same frame, and drawing a disposed
    // painter throws in debug mode.
    final painter = LabelPainter();
    final layer = _symbolLayer();

    // Overflow the text cache by 100 distinct texts in one frame, so
    // ~100 evictions happen while the evicted painters are still queued
    // to draw. Anchors must stay inside the 400x400 screen (+150px
    // margin) or the off-screen cull skips layout and nothing evicts.
    const count = LabelPainter.textCacheEntries + 100;
    _paintFrame(painter, [
      for (var i = 0; i < count; i++)
        _symbolAt(layer, Offset((i % 40) * 10.0, ((i ~/ 40) % 40) * 10.0),
            'label $i'),
    ]);

    // The next frame disposes the retired painters and re-lays-out
    // evicted texts without touching disposed objects.
    _paintFrame(painter, [_symbolAt(layer, const Offset(50, 50), 'label 0')]);

    painter.dispose();
  });

  test('trimCaches keeps the text on screen and releases the rest', () {
    final painter = LabelPainter();
    final layer = _symbolLayer();
    List<PlacedSymbol> place(String prefix, int count) => [
          for (var i = 0; i < count; i++)
            _symbolAt(
                layer, Offset((i % 20) * 20.0, (i ~/ 20) * 20.0), '$prefix $i'),
        ];

    // A frame showing both, then one where only the second set is
    // left on screen — drawn from the cache, not shaped again.
    final onScreen = place('here', 40);
    _paintFrame(painter, [...place('left', 100), ...onScreen]);
    _paintFrame(painter, onScreen);
    expect(painter.debugTextCacheLength, 140);

    painter.trimCaches();
    expect(painter.debugTextCacheLength, 40,
        reason: 'only what the last pass used is kept');

    final shaped = painter.debugShapedTextCount;
    _paintFrame(painter, onScreen);
    expect(painter.debugShapedTextCount, shaped,
        reason: 'the labels on screen are not re-shaped');
    _paintFrame(painter, place('left', 100));
    expect(painter.debugShapedTextCount, shaped + 100,
        reason: 'the labels left behind are shaped again on return');
    painter.dispose();
  });

  test('trimCaches keeps text the pump shaped after the last pass', () {
    // Tiles about to be published are shaped between frames; their
    // text is the next frame's, not the past's.
    final painter = LabelPainter();
    final layer = _symbolLayer();
    _paintFrame(painter, [_symbolAt(layer, const Offset(50, 50), 'here')]);
    final arriving = [
      for (final placed in [
        _symbolAt(layer, Offset.zero, 'next 0'),
        _symbolAt(layer, Offset.zero, 'next 1'),
      ])
        placed.instance,
    ];
    painter.prewarm(arriving, 12);

    painter.trimCaches();
    expect(painter.debugTextCacheLength, 3);
    painter.dispose();
  });

  test('trimCaches keeps the on-screen labels a replayed frame skipped', () {
    // Between placement passes only the winners are laid out. The label
    // that lost is still a candidate on screen, and the next pass lays
    // it out again: a trim must not count it as left behind.
    final layer = (const ThemeReader().read({
      'layers': [
        {
          'id': 'poi',
          'type': 'symbol',
          'source': 's',
          'source-layer': 'poi',
          'layout': {'text-field': '{name}', 'text-size': 14},
        },
      ],
    })).layers.single as SymbolThemeLayer;
    final painter = LabelPainter();
    // The same instances every frame, as a layer's tiles hand them over.
    final symbols = [
      _symbolAt(layer, const Offset(200, 200), 'winner'),
      _symbolAt(layer, const Offset(204, 200), 'loser'),
    ];
    final start = DateTime(2026);
    List<PlacedSymbol> frame(Duration at) {
      final recorder = ui.PictureRecorder();
      final drawn = painter.paint(
        canvas: Canvas(recorder),
        screenSize: const Size(400, 400),
        styleZoom: 12,
        symbols: symbols,
        labelFadeDuration: const Duration(milliseconds: 300),
        placementGeneration: _nextPlacementGeneration++,
        now: start.add(at),
      );
      recorder.endRecording().dispose();
      return drawn;
    }

    expect(frame(Duration.zero), hasLength(1), reason: 'the two collide');
    frame(const Duration(milliseconds: 16));
    expect(painter.placementPending, isTrue,
        reason: 'the second frame replayed the first decision');

    painter.trimCaches();
    expect(painter.debugTextCacheLength, 2);
    painter.dispose();
  });
}
