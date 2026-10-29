import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:ui' show Offset, Size;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_map_vector_tiles/src/core/tile_key.dart';
import 'package:flutter_map_vector_tiles/src/pipeline/tile_processor.dart';
import 'package:flutter_map_vector_tiles/src/render/display_tile_data.dart';
import 'package:flutter_map_vector_tiles/src/render/label_identity.dart';
import 'package:flutter_map_vector_tiles/src/render/label_painter.dart';
import 'package:flutter_map_vector_tiles/src/render/label_worker.dart';
import 'package:flutter_map_vector_tiles/src/render/symbol_layouter.dart';
import 'package:flutter_map_vector_tiles/src/style/sprite_atlas.dart';
import 'package:flutter_map_vector_tiles/src/style/theme.dart';
import 'package:flutter_map_vector_tiles/src/style/theme_reader.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/mvt_builder.dart';

/// A placement worker runs the screen pass's own placement code over
/// mirrored text metrics. These pin down that it decides what an
/// in-frame pass decides — on a dense synthetic style with curved street
/// names, road shields, variable anchors, optional text, icons, sort
/// keys and repeated names — that the painter adopts its answer, and
/// that a worker which never answers does not freeze placement.

const _fade = Duration(milliseconds: 100);
final _t0 = DateTime(2026, 1, 1);
const _screen = Size(600, 600);

Theme _theme() => const ThemeReader().read({
      'layers': [
        {
          'id': 'street',
          'type': 'symbol',
          'source': 's',
          'source-layer': 'road',
          'layout': {
            'symbol-placement': 'line',
            'symbol-spacing': 120,
            'text-field': '{name}',
            'text-size': 13,
            'text-max-angle': 30,
            'text-padding': 2,
          },
        },
        {
          'id': 'shield',
          'type': 'symbol',
          'source': 's',
          'source-layer': 'road',
          'filter': ['has', 'ref'],
          'layout': {
            'symbol-placement': 'line',
            'symbol-spacing': 200,
            'icon-image': 'shield',
            'text-field': '{ref}',
            'text-size': 10,
            'text-rotation-alignment': 'viewport',
          },
        },
        {
          'id': 'poi',
          'type': 'symbol',
          'source': 's',
          'source-layer': 'poi',
          'layout': {
            'text-field': '{name}',
            'text-size': [
              'interpolate',
              ['linear'],
              ['zoom'],
              13,
              10,
              16,
              14
            ],
            'icon-image': 'dot',
            'text-variable-anchor': ['top', 'bottom', 'left', 'right'],
            'text-radial-offset': 0.8,
            'text-optional': true,
            'symbol-sort-key': ['get', 'rank'],
          },
        },
        {
          'id': 'place',
          'type': 'symbol',
          'source': 's',
          'source-layer': 'poi',
          'maxzoom': 15.2,
          'filter': [
            '<',
            ['get', 'rank'],
            3
          ],
          'layout': {'text-field': '{name}', 'text-size': 16},
        },
      ],
    });

/// One random data tile at [key]: winding named roads (names repeat,
/// so repeat suppression has work) and ranked POIs.
List<SymbolInstance> _symbols(Theme theme, TileKey key, int seed) {
  final random = math.Random(seed);
  final builder = MvtTileBuilder();
  final roads = builder.layer('road');
  const names = ['Hauptstraße', 'Ringweg', 'Am Bach', 'Lindenallee', 'Kai'];
  for (var r = 0; r < 14; r++) {
    var x = random.nextInt(4096);
    var y = random.nextInt(4096);
    final points = 3 + random.nextInt(5);
    final geometry = <int>[cmd(1, 1), zig(x), zig(y), cmd(2, points - 1)];
    for (var p = 1; p < points; p++) {
      final dx = random.nextInt(1400) - 500;
      final dy = random.nextInt(1400) - 700;
      x += dx;
      y += dy;
      geometry
        ..add(zig(dx))
        ..add(zig(dy));
    }
    roads.feature(type: 2, geometry: geometry, properties: {
      'name': names[r % names.length],
      if (r % 3 == 0) 'ref': 'B${r + 3}',
    });
  }
  roads.done();
  final pois = builder.layer('poi');
  for (var p = 0; p < 90; p++) {
    pois.feature(type: 1, geometry: [
      cmd(1, 1),
      zig(random.nextInt(4096)),
      zig(random.nextInt(4096)),
    ], properties: {
      'name': 'Ort ${p * 7 % 61}',
      'rank': random.nextInt(8),
    });
  }
  pois.done();
  final tile = prepareTileSync(PrepareInput(
    z: key.z,
    x: key.x,
    y: key.y,
    bytes: builder.build(),
    layerProperties: const {'road': null, 'poi': null},
  ));
  return SymbolLayouter.layout(
    theme: theme,
    data: DisplayTileData(displayKey: key, sources: {'s': tile}),
    styleZoom: key.z.toDouble(),
  );
}

/// A 2×2 block of display tiles, each laid out from its own random data,
/// with the label ids the layer's identity index gives them as they
/// publish.
({List<List<SymbolInstance>> lists, List<Int32List> ids}) _published(
    Theme theme) {
  const keys = [
    TileKey(14, 0, 0),
    TileKey(14, 1, 0),
    TileKey(14, 0, 1),
    TileKey(14, 1, 1),
  ];
  final index = LabelIdentityIndex();
  final lists = [
    for (var i = 0; i < keys.length; i++) _symbols(theme, keys[i], i + 1),
  ];
  return (
    lists: lists,
    ids: [
      for (var i = 0; i < keys.length; i++) index.assign(keys[i], lists[i])
    ],
  );
}

SpriteAtlas _sprites() {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(const ui.Rect.fromLTWH(0, 0, 2, 2),
      ui.Paint()..color = const ui.Color(0xff000000));
  return SpriteAtlas(
    image: recorder.endRecording().toImageSync(2, 2),
    sprites: const {
      'dot': Sprite(x: 0, y: 0, width: 12, height: 12, pixelRatio: 1),
      'shield': Sprite(x: 0, y: 0, width: 26, height: 16, pixelRatio: 1),
    },
    pixelRatio: 1,
  );
}

/// The block under a camera: [shift] pans it, [scale] zooms it,
/// [rotation] turns it about the screen centre. The last tile counts as
/// a retained one, as a zoom crossing would leave it.
List<LabelCohortInput> _cohorts(
  ({List<List<SymbolInstance>> lists, List<Int32List> ids}) tiles, {
  Offset shift = Offset.zero,
  double rotation = 0,
  double scale = 1.3,
}) {
  const centre = Offset(300, 300);
  final cohorts = <LabelCohortInput>[];
  var order = 0;
  for (var i = 0; i < tiles.lists.length; i++) {
    final local = Offset((i % 2) * 256.0 * scale - 256 * scale,
            (i ~/ 2) * 256.0 * scale - 256 * scale) +
        shift;
    final origin = centre +
        Offset(local.dx * math.cos(rotation) - local.dy * math.sin(rotation),
            local.dx * math.sin(rotation) + local.dy * math.cos(rotation));
    cohorts.add((
      symbols: tiles.lists[i],
      ids: tiles.ids[i],
      transform:
          TileTransform(origin: origin, scale: scale, rotation: rotation),
      ghostOnly: false,
      retained: i == 3,
      order: order,
    ));
    order += tiles.lists[i].length;
  }
  return cohorts;
}

/// [cohorts] as one frame's candidates, the way the layer builds them —
/// from [lists] in place of the cohorts' own when given (a worker's
/// adopted mirrors).
List<PlacedSymbol> _candidates(List<LabelCohortInput> cohorts,
        [List<List<SymbolInstance?>>? lists]) =>
    [
      for (var c = 0; c < cohorts.length; c++)
        for (var i = 0; i < cohorts[c].symbols.length; i++)
          if ((lists?[c] ?? cohorts[c].symbols)[i] case final instance?)
            PlacedSymbol(
              instance: instance,
              id: cohorts[c].ids[i],
              screenAnchor: cohorts[c].transform.apply(instance.anchor),
              screenAngle: instance.angle + cohorts[c].transform.rotation,
              transform: cohorts[c].transform,
              retained: cohorts[c].retained,
              order: cohorts[c].order + i,
            ),
    ];

List<PlacedSymbol> _paint(
  LabelPainter painter,
  List<LabelCohortInput> cohorts,
  SpriteAtlas? sprites, {
  required double zoom,
  required int generation,
  required DateTime now,
}) {
  final recorder = ui.PictureRecorder();
  final drawn = painter.paint(
    canvas: ui.Canvas(recorder),
    screenSize: _screen,
    styleZoom: zoom,
    symbols: _candidates(cohorts),
    sprites: sprites,
    labelFadeDuration: _fade,
    placementGeneration: generation,
    cohorts: cohorts,
    now: now,
  );
  recorder.endRecording().dispose();
  return drawn;
}

/// The label ids [symbols] places.
Set<int> _ids(Iterable<PlacedSymbol> symbols) =>
    {for (final s in symbols) s.id};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final theme = _theme();
  final sprites = _sprites();

  for (final (zoom, rotation) in [(14.4, 0.0), (15.1, 0.0), (14.8, 0.6)]) {
    test(
        'a worker pass places what an in-frame pass places '
        '(z$zoom, rotation $rotation)', () {
      final tiles = _published(theme);
      final ui = LabelPainter();
      final worker = LabelPainter.worker()..installWorker(sprites.sprites);

      // Pass 1: nothing on screen yet, no incumbents. The UI shapes on
      // its first frame; the lists are mirrored after it, as after the
      // pump's shaping.
      var cohorts = _cohorts(tiles, rotation: rotation);
      final first =
          _paint(ui, cohorts, sprites, zoom: zoom, generation: 1, now: _t0);
      final mirrored = [
        for (final list in tiles.lists)
          worker.adoptMirror(ui.mirrorOf(list), theme),
      ];
      var winners = worker.placeForWorker(
        screenSize: _screen,
        styleZoom: zoom,
        symbols: _candidates(cohorts, mirrored),
        incumbents: const [],
      );
      expect(first.length, greaterThan(20), reason: 'a crowded screen');
      expect(_ids(winners), _ids(first));
      // The variable anchors each label took, and whether its text or
      // icon was dropped, agree too.
      for (final winner in winners) {
        final decision = worker.decisionOf(winner);
        final sitting = ui.debugPlacement.lookup(winner.id);
        if (decision.anchor != null) {
          expect(sitting?.anchor, decision.anchor, reason: '${winner.id}');
        }
        expect(sitting?.textDropped ?? false, decision.textDropped);
        expect(sitting?.iconDropped ?? false, decision.iconDropped);
      }

      // Replay, then pan and zoom a little and place again: the first
      // pass's winners are incumbents now.
      var replayed = const <PlacedSymbol>[];
      for (var f = 1; f <= 4; f++) {
        replayed = _paint(ui, cohorts, sprites,
            zoom: zoom,
            generation: 1,
            now: _t0.add(Duration(milliseconds: 40 * f)));
      }
      cohorts = _cohorts(tiles,
          rotation: rotation, shift: const Offset(23, -17), scale: 1.32);
      final second = _paint(ui, cohorts, sprites,
          zoom: zoom + 0.05,
          generation: 2,
          now: _t0.add(const Duration(milliseconds: 400)));
      winners = worker.placeForWorker(
        screenSize: _screen,
        styleZoom: zoom + 0.05,
        symbols: _candidates(cohorts, mirrored),
        incumbents: _ids(first),
        // The copies the UI drew, which the pass tries first.
        drawnCopies: [for (final s in replayed) s.order],
      );
      expect(_ids(winners), _ids(second));
      // And from the same copies.
      expect({for (final s in winners) s.order},
          {for (final s in second) s.order});
    });
  }

  test('a pass the worker never answers is placed in-frame after a second', () {
    final cohorts = _cohorts(_published(theme));
    final expected = _ids(_paint(LabelPainter(), cohorts, sprites,
        zoom: 14.6, generation: 1, now: _t0));
    final silent = _SilentWorker();
    final painter = LabelPainter()..worker = silent;
    var drawn =
        _paint(painter, cohorts, sprites, zoom: 14.6, generation: 1, now: _t0);
    expect(silent.requests, 1);
    expect(drawn, isEmpty);
    drawn = _paint(painter, cohorts, sprites,
        zoom: 14.6,
        generation: 1,
        now: _t0.add(const Duration(milliseconds: 600)));
    expect(drawn, isEmpty, reason: 'still waiting for the answer');
    expect(painter.placementPending, isTrue);
    drawn = _paint(painter, cohorts, sprites,
        zoom: 14.6,
        generation: 1,
        now: _t0.add(const Duration(milliseconds: 1100)));
    expect(silent.requests, 1, reason: 'placed in-frame, not asked again');
    expect(_ids(drawn), expected);
    expect(painter.placementPending, isFalse);
  });

  test('the painter adopts the isolate worker\'s answer', () async {
    LabelPlacementWorker.debugDisabled = false;
    addTearDown(() => LabelPlacementWorker.debugDisabled = true);
    final worker = LabelPlacementWorker.create()!;
    addTearDown(worker.dispose);
    worker.install(theme, sprites.sprites);
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!worker.ready) {
      expect(DateTime.now().isBefore(deadline), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    final tiles = _published(theme);
    final painter = LabelPainter()..worker = worker;
    // The worker places by the metrics of shaped text: shape and mirror
    // first, as the pump does when a tile publishes.
    for (final list in tiles.lists) {
      painter
        ..prewarm(list, 14)
        ..mirror(list);
    }
    // Then the retention pin cuts the last tile down to what was drawn:
    // a new list, which goes over as indices into the tile's mirror.
    final kept = [for (var i = 0; i < tiles.lists[3].length; i += 2) i];
    final pinned = (
      lists: [
        ...tiles.lists.take(3),
        [for (final i in kept) tiles.lists[3][i]],
      ],
      ids: [
        ...tiles.ids.take(3),
        Int32List.fromList([for (final i in kept) tiles.ids[3][i]]),
      ],
    );
    final cohorts = _cohorts(pinned);
    // The in-frame decision, from a painter without a worker.
    final expected = _ids(_paint(LabelPainter(), cohorts, sprites,
        zoom: 14.6, generation: 1, now: _t0));
    final mirrors = LabelPlacementWorker.debugMirrorCount;
    final mirrorBytes = LabelPlacementWorker.debugMirrorBytes;

    final commits = LabelPlacementWorker.debugCommits;
    var now = _t0;
    var drawn =
        _paint(painter, cohorts, sprites, zoom: 14.6, generation: 1, now: now);
    // The request frame replays the decision in force: none yet.
    expect(drawn, isEmpty);
    expect(painter.placementPending, isTrue);
    while (LabelPlacementWorker.debugCommits == commits) {
      expect(DateTime.now().isBefore(deadline), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      now = now.add(const Duration(milliseconds: 16));
      drawn = _paint(painter, cohorts, sprites,
          zoom: 14.6, generation: 1, now: now);
    }
    expect(_ids(drawn), expected);
    expect(painter.placementPending, isFalse);
    // The cut was the one list mirrored for the pass, as its indices.
    expect(LabelPlacementWorker.debugMirrorCount - mirrors, 1);
    expect(
        LabelPlacementWorker.debugMirrorBytes - mirrorBytes, kept.length * 4);
  }, skip: kIsWeb);
}

/// A worker that takes every request and answers none.
class _SilentWorker implements LabelPlacementWorker {
  var requests = 0;

  @override
  bool get ready => true;

  @override
  void install(Theme theme, Map<String, Sprite>? sprites) {}

  @override
  int mirror(List<SymbolInstance> symbols, LabelMirror Function() build) => 1;

  @override
  void place(
          LabelPassRequest request, void Function(LabelPassResult) onResult) =>
      requests++;

  @override
  void dispose() {}
}
