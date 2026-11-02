import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart' hide Theme;
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_vector_tiles/flutter_map_vector_tiles.dart';
import 'package:flutter_map_vector_tiles/src/render/label_worker.dart';
import 'package:flutter_map_vector_tiles/src/render/symbol_layouter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'fixtures/lifecycle_harness.dart' show pumpUntil;
import 'fixtures/mvt_builder.dart';

/// When a layer starts its placement worker, hands it a new theme, or
/// places in-frame instead — the wiring the worker's own tests
/// (`label_worker_test.dart`) do not see.

const _tile = TileKey(14, 8726, 5686);

Uint8List _poiTile() => (MvtTileBuilder()
        .layer('poi')
        .feature(
            type: 1,
            geometry: [cmd(1, 1), zig(2048), zig(2048)],
            id: 3,
            properties: {'name': 'Cafe'})
        .done())
    .build();

LatLng _centreOf(TileKey key) {
  final n = math.pow(2, key.z).toDouble();
  final lon = (key.x + 0.5) / n * 360 - 180;
  final y = math.pi * (1 - 2 * (key.y + 0.5) / n);
  final lat = math.atan((math.exp(y) - math.exp(-y)) / 2) * 180 / math.pi;
  return LatLng(lat, lon);
}

Theme _labels(Map<String, Object?> paint, {Map<String, Object?>? state}) =>
    const ThemeReader().read({
      if (state != null) 'state': state,
      'layers': [
        {
          'id': 'label',
          'type': 'symbol',
          'source': 's',
          'source-layer': 'poi',
          'layout': {
            'text-field': '{name}',
            'text-size': state == null
                ? 12
                : [
                    'case',
                    ['global-state', 'large'],
                    22,
                    12
                  ],
          },
          'paint': paint,
        },
      ],
    });

/// One instance for every rebuild: new providers would rebuild the
/// stores, which re-installs the worker for reasons of its own.
final _providers = TileProviders({
  's': MemoryVectorTileProvider(
    tiles: {_tile: _poiTile()},
    cacheKey: 'label-worker-layer',
  ),
});

Widget _map(Theme theme, {VectorTileLayerController? controller}) =>
    MaterialApp(
      home: FlutterMap(
        options: MapOptions(initialCenter: _centreOf(_tile), initialZoom: 14),
        children: [
          VectorTileLayer(
            controller: controller,
            theme: theme,
            tileProviders: _providers,
            tileOffset: TileOffset.none,
            tileFadeDuration: Duration.zero,
            concurrency: 1,
            diskCacheMaximumSizeInBytes: 0,
          ),
        ],
      ),
    );

/// A worker that records what it is told and answers nothing — the
/// painter places in-frame once it stops waiting.
class _RecordingWorker implements LabelPlacementWorker {
  final installs = <Theme>[];
  var disposed = false;

  @override
  bool get ready => true;

  @override
  void install(Theme theme, Map<String, Sprite>? sprites) =>
      installs.add(theme);

  @override
  int mirror(List<SymbolInstance> symbols, LabelMirror Function() build) => 1;

  @override
  void place(
      LabelPassRequest request, void Function(LabelPassResult) onResult) {}

  @override
  void dispose() => disposed = true;
}

void main() {
  late List<_RecordingWorker> workers;
  setUp(() {
    workers = [];
    LabelPlacementWorker.debugCreate = () {
      final worker = _RecordingWorker();
      workers.add(worker);
      return worker;
    };
  });
  tearDown(() {
    LabelPlacementWorker.debugCreate = null;
    VectorTileLayer.clearMemoryCache();
  });

  testWidgets('another global state is handed to the placement worker',
      (tester) async {
    final theme = _labels(const {
      'text-color': '#000000'
    }, state: {
      'large': {'default': false},
    });
    await tester.pumpWidget(_map(theme));
    expect(await pumpUntil(tester, () async => workers.isNotEmpty), isTrue);
    expect(workers.single.installs, [same(theme)]);

    // The worker places by the theme's constants — here the text size
    // its collision boxes are measured with.
    final large = theme.withGlobalState({'large': true});
    await tester.pumpWidget(_map(large));
    await tester.pump();
    expect(workers.single.installs.last, same(large));

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'labels whose opacity reads feature state place in-frame while a '
      'controller can set it', (tester) async {
    final theme = _labels(const {
      'text-color': '#000000',
      'text-opacity': [
        'case',
        [
          'boolean',
          ['feature-state', 'selected'],
          false
        ],
        1,
        0.5,
      ],
    });
    final controller = VectorTileLayerController();
    await tester.pumpWidget(_map(theme, controller: controller));
    // The label shows once its tile has loaded; the worker would have
    // started with it.
    expect(
        await pumpUntil(
            tester,
            () async => controller
                .queryRenderedFeaturesInRect(Rect.fromCenter(
                    center: tester.getCenter(find.byType(FlutterMap)),
                    width: 80,
                    height: 80))
                .any((f) => f.layerId == 'label')),
        isTrue);
    expect(workers, isEmpty, reason: 'the worker sees no feature state');

    // Without a controller no state can be set: the worker takes over.
    await tester.pumpWidget(_map(theme));
    expect(await pumpUntil(tester, () async => workers.isNotEmpty), isTrue);
    expect(workers.single.installs, [same(theme)]);

    // And hands back when one is attached again.
    await tester.pumpWidget(_map(theme, controller: controller));
    await tester.pump();
    expect(workers.single.disposed, isTrue);

    await tester.pumpWidget(const SizedBox());
  });
}
