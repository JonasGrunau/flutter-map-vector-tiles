import 'dart:ui' as ui;
import 'dart:ui' show Offset, Size;

import 'package:flutter_map_vector_tiles/src/core/tile_key.dart';
import 'package:flutter_map_vector_tiles/src/render/label_continuity.dart';
import 'package:flutter_map_vector_tiles/src/render/label_painter.dart';
import 'package:flutter_map_vector_tiles/src/render/symbol_layouter.dart';
import 'package:flutter_map_vector_tiles/src/style/theme.dart';
import 'package:flutter_map_vector_tiles/src/style/theme_reader.dart';
import 'package:flutter_test/flutter_test.dart';

SymbolThemeLayer _layer() {
  final theme = const ThemeReader().read({
    'layers': [
      {
        'id': 'place',
        'type': 'symbol',
        'source': 's',
        'source-layer': 'place',
        'layout': {'text-field': '{name}'},
      },
    ],
  });
  return theme.layers.single as SymbolThemeLayer;
}

SymbolInstance _symbol(
  SymbolThemeLayer layer, {
  String text = 'Feldkirchen',
  String? iconName,
  int layerIndex = 0,
  Offset anchor = Offset.zero,
}) =>
    SymbolInstance(
      layer: layer,
      layerIndex: layerIndex,
      anchor: anchor,
      angle: 0,
      alongLine: false,
      text: text,
      iconName: iconName,
      sortKey: 0,
      properties: const {},
      geometryType: 'Point',
      featureId: null,
    );

/// A symbol as the label pass sees it: a cohort member projected to
/// screen space at [fadeOpacity].
PlacedSymbol _placed(
  SymbolThemeLayer layer,
  double dy, {
  String text = 'Feldkirchen',
  double fadeOpacity = 1,
  int order = 0,
  int layerIndex = 0,
  bool ghost = false,
}) =>
    PlacedSymbol(
      instance: _symbol(layer, text: text, layerIndex: layerIndex),
      screenAnchor: Offset(200, dy),
      screenAngle: 0,
      fadeOpacity: fadeOpacity,
      order: order,
      ghost: ghost,
    );

List<PlacedSymbol> _paint(List<PlacedSymbol> symbols) {
  final painter = LabelPainter();
  final recorder = ui.PictureRecorder();
  final drawn = painter.paint(
    canvas: ui.Canvas(recorder),
    screenSize: const Size(400, 400),
    styleZoom: 14,
    symbols: symbols,
  );
  recorder.endRecording().dispose();
  painter.dispose();
  return drawn;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final layer = _layer();

  group('labelContinuityKey', () {
    test('ignores the anchor', () {
      // The whole point: the same feature is simplified differently at
      // two zoom levels, so its anchor lands a fraction of a pixel apart
      // and a position-sensitive key would miss the match.
      expect(
        labelContinuityKey(_symbol(layer, anchor: const Offset(10, 10))),
        labelContinuityKey(_symbol(layer, anchor: const Offset(10.4, 9.7))),
      );
    });

    test('separates different text, layers and icons', () {
      final base = labelContinuityKey(_symbol(layer));
      expect(base, isNot(labelContinuityKey(_symbol(layer, text: 'Aschheim'))));
      expect(base, isNot(labelContinuityKey(_symbol(layer, layerIndex: 3))));
      expect(
        labelContinuityKey(_symbol(layer, text: '', iconName: 'cafe')),
        isNot(labelContinuityKey(_symbol(layer, text: '', iconName: 'bar'))),
      );
    });

    test('matches icon-only symbols on their icon', () {
      expect(
        labelContinuityKey(_symbol(layer, text: '', iconName: 'cafe')),
        labelContinuityKey(_symbol(layer,
            text: '', iconName: 'cafe', anchor: const Offset(80, 20))),
      );
    });
  });

  group('partitionCarriedOver', () {
    test('nothing retained: the whole cohort is fresh', () {
      final symbols = [_symbol(layer), _symbol(layer, text: 'Aschheim')];
      final result = partitionCarriedOver(symbols, const {});
      expect(result.carriedCount, 0);
      expect(result.symbols, same(symbols));
    });

    test('a fully covered cohort carries over entirely', () {
      final symbols = [_symbol(layer), _symbol(layer, text: 'Aschheim')];
      final result =
          partitionCarriedOver(symbols, labelContinuityKeys([symbols]));
      expect(result.carriedCount, symbols.length);
      expect(result.symbols, same(symbols));
    });

    test('a mixed cohort puts the carried-over labels first', () {
      final carried = _symbol(layer);
      final fresh = _symbol(layer, text: 'Riemerling');
      final alsoFresh = _symbol(layer, text: 'Putzbrunn');
      final symbols = [fresh, carried, alsoFresh];
      final result = partitionCarriedOver(
          symbols,
          labelContinuityKeys([
            [_symbol(layer, anchor: const Offset(3, 4))]
          ]));

      expect(result.carriedCount, 1);
      expect(result.symbols.first, same(carried));
      expect(result.symbols, hasLength(3));
      expect(result.symbols.skip(1), containsAll([fresh, alsoFresh]));
    });

    test('never mutates the caller\'s list', () {
      // A cache hit publishes the list the result cache owns; reordering
      // it in place would reorder the cache entry itself.
      final fresh = _symbol(layer, text: 'Riemerling');
      final carried = _symbol(layer);
      final symbols = [fresh, carried];
      final result = partitionCarriedOver(
          symbols,
          labelContinuityKeys([
            [carried]
          ]));

      expect(symbols, [fresh, carried], reason: 'input order preserved');
      expect(result.symbols, isNot(same(symbols)));
      expect(result.symbols, [carried, fresh]);
    });

    test('an empty cohort carries nothing', () {
      final result = partitionCarriedOver(
          const [],
          labelContinuityKeys([
            [_symbol(layer)]
          ]));
      expect(result.carriedCount, 0);
      expect(result.symbols, isEmpty);
    });
  });

  group('coveringLabelKeys', () {
    RetainedCohort cohort(TileKey key, List<String> texts) => (
          key: key,
          symbols: [for (final text in texts) _symbol(layer, text: text)],
        );

    test('a retained parent covers the child arriving beneath it', () {
      // Zooming in: the outgoing z14 tile still shows these labels while
      // each of its four z15 children arrives.
      final keys = coveringLabelKeys(const TileKey(15, 200, 200), [
        cohort(const TileKey(14, 100, 100), ['Feldkirchen', 'Aschheim']),
      ]);
      expect(keys, hasLength(2));
      expect(keys, contains(labelContinuityKey(_symbol(layer))));
    });

    test('retained children cover the parent arriving above them', () {
      // Zooming out: four outgoing z15 tiles, one arriving z14 parent.
      final keys = coveringLabelKeys(const TileKey(14, 100, 100), [
        cohort(const TileKey(15, 200, 200), ['Feldkirchen']),
        cohort(const TileKey(15, 201, 201), ['Aschheim']),
      ]);
      expect(keys, hasLength(2));
    });

    test('a retained tile elsewhere on screen covers nothing here', () {
      final keys = coveringLabelKeys(const TileKey(15, 200, 200), [
        cohort(const TileKey(14, 500, 500), ['Feldkirchen']),
      ]);
      expect(keys, isEmpty);
    });

    test('a retained tile with no labels covers nothing', () {
      final keys = coveringLabelKeys(const TileKey(15, 200, 200), [
        cohort(const TileKey(14, 100, 100), const []),
      ]);
      expect(keys, isEmpty);
    });

    test('nothing retained: the arriving cohort is free to fade', () {
      expect(coveringLabelKeys(const TileKey(15, 200, 200), const []), isEmpty);
    });
  });

  group('orphanedLabels', () {
    test('keeps only what the arriving level does not replace', () {
      // Feldkirchen is in the tileset at z13 but not at z14: no symbol
      // at the arriving level will ever draw it, so it is what a
      // fade-out has to cover.
      final outgoing = [
        _symbol(layer),
        _symbol(layer, text: 'Aschheim'),
      ];
      final orphans = orphanedLabels(
          outgoing,
          labelContinuityKeys([
            [_symbol(layer, text: 'Aschheim')]
          ]));
      expect(orphans, hasLength(1));
      expect(orphans.single.text, 'Feldkirchen');
    });

    test('a fully replaced cohort orphans nothing', () {
      final outgoing = [_symbol(layer), _symbol(layer, text: 'Aschheim')];
      expect(
          orphanedLabels(outgoing, labelContinuityKeys([outgoing])), isEmpty);
    });

    test('an arriving level with no labels orphans everything', () {
      final outgoing = [_symbol(layer), _symbol(layer, text: 'Aschheim')];
      expect(orphanedLabels(outgoing, const {}), hasLength(2));
    });

    test('orphans and carry-over partition the outgoing cohort', () {
      // The two halves must not overlap, or a label would both fade out
      // and be redrawn opaque by the arriving level.
      final outgoing = [
        _symbol(layer),
        _symbol(layer, text: 'Aschheim'),
        _symbol(layer, text: 'Riemerling'),
      ];
      final arriving = labelContinuityKeys([
        [_symbol(layer, text: 'Aschheim')]
      ]);
      final orphans = orphanedLabels(outgoing, arriving);
      final carried = partitionCarriedOver(outgoing, arriving).carriedCount;
      expect(orphans.length + carried, outgoing.length);
    });
  });

  group('a label fading out', () {
    test('yields its space to a live label, and never blocks one', () {
      // The ghost sorts first on y, so without the ghost rules it would
      // take the space and the live label would be dropped. Instead the
      // live label places, and the ghost — tested against the finished
      // layout, reserving nothing — steps aside. Its disappearance is
      // masked by the very label that replaced it.
      final drawn = _paint([
        _placed(layer, 200, text: 'Feldkirchen', fadeOpacity: 0.5, ghost: true),
        _placed(layer, 200.2, text: 'Aschheim', order: 1),
      ]);
      expect(drawn, hasLength(1));
      expect(drawn.single.instance.text, 'Aschheim');
    });

    test('still fades out where nothing live claims its space', () {
      // The ordinary case: the arriving level simply has no label here,
      // so the ghost draws at its fade opacity until it reaches zero.
      final drawn = _paint([
        _placed(layer, 200, text: 'Feldkirchen', fadeOpacity: 0.5, ghost: true),
        _placed(layer, 340, text: 'Aschheim', order: 1),
      ]);
      expect(drawn, hasLength(2));
      expect(
        drawn.singleWhere((s) => s.instance.text == 'Feldkirchen').fadeOpacity,
        0.5,
      );
    });

    test('loses even from a style layer that would normally win space', () {
      // Topmost layers place first, so layer 5 would beat layer 0 — but
      // ghosts place after every live label regardless of layer. A dying
      // label never outranks one that is staying.
      final drawn = _paint([
        _placed(layer, 200,
            text: 'Feldkirchen', layerIndex: 5, fadeOpacity: 0.5, ghost: true),
        _placed(layer, 200.2, text: 'Aschheim', order: 1),
      ]);
      expect(drawn, hasLength(1));
      expect(drawn.single.instance.text, 'Aschheim');
    });
  });

  group('a label present at both zoom levels', () {
    // Across an integer zoom crossing the arriving level and the
    // retained one both offer the same label for a few frames. Their
    // anchors differ by a fraction of a pixel — the two levels simplify
    // geometry differently — so the collision index's y-ordering picks
    // between them essentially at random. The fix is to make that choice
    // not matter, by never re-fading a label the retained level shows.
    test('draws opaque whichever copy wins collision', () {
      for (final arrivingFirst in [true, false]) {
        // 199.7 vs 200.0: whichever anchor sorts first wins the space.
        final drawn = _paint([
          _placed(layer, arrivingFirst ? 199.7 : 200.3, order: 0), // arriving
          _placed(layer, 200.0, order: 1), // retained
        ]);
        expect(drawn, hasLength(1), reason: 'the two copies collide');
        expect(drawn.single.fadeOpacity, 1,
            reason: 'carried over, so neither copy fades');
      }
    });

    test('a cohort that re-fades is what makes the label blink', () {
      // The behaviour the fix removes, pinned so a regression is loud:
      // when the arriving copy fades in it still beats the retained copy
      // for collision space, so the label drops to a fraction of its
      // opacity while a fully opaque copy of it is right there.
      final drawn = _paint([
        _placed(layer, 199.7, fadeOpacity: 0.125, order: 0), // arriving
        _placed(layer, 200.0, order: 1), // retained
      ]);
      expect(drawn, hasLength(1));
      expect(drawn.single.fadeOpacity, 0.125,
          reason: 'the retained opaque copy was suppressed by the fading one');
    });
  });

  group('labelContinuityKeys', () {
    test('unions every cohort and dedupes', () {
      final keys = labelContinuityKeys([
        [_symbol(layer), _symbol(layer, text: 'Aschheim')],
        [_symbol(layer, anchor: const Offset(9, 9))],
      ]);
      expect(keys, hasLength(2));
      expect(keys, contains(labelContinuityKey(_symbol(layer))));
    });
  });
}
