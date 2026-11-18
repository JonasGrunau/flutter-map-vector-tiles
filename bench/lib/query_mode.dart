/// `BENCH_MODE=query`: what `VectorTileLayerController` costs.
library;

// ignore_for_file: implementation_imports
// ignore_for_file: invalid_use_of_visible_for_testing_member

import 'dart:io' show ProcessInfo;
import 'dart:math' as math;
import 'dart:typed_data' show Uint8List;
import 'dart:ui' show Offset, Rect, Size;

import 'package:flutter_map/flutter_map.dart' show MapController;
import 'package:flutter_map_vector_tiles/flutter_map_vector_tiles.dart' as vt;
import 'package:flutter_map_vector_tiles/src/pipeline/tile_processor.dart'
    show PrepareInput, prepareTileSync;
import 'package:flutter_map_vector_tiles/src/render/symbol_layouter.dart'
    show SymbolLayouter;
import 'package:flutter_map_vector_tiles/src/render/tile_rasterizer.dart'
    show TileRasterizer;

import 'env.dart';
import 'frame_recorder.dart';
import 'report.dart';

/// When, and on which frame, the last rasterize or layout landed.
typedef Quiet = ({DateTime at, int frame});

/// The style plus a fill over its buildings and a line over its roads,
/// each transparent until a feature's state says `selected` — the
/// tap-to-highlight the example app shows. Two kinds because they
/// cost differently: OpenMapTiles-schema tiles merge buildings into
/// multipolygons of hundreds, which reach many tiles, while a road is
/// one way.
vt.Theme withSelection(vt.Theme theme) {
  final buildings =
      theme.layers.where((l) => l.sourceLayer == 'building').firstOrNull;
  if (buildings == null) return theme;
  const selected = [
    'boolean',
    ['feature-state', 'selected'],
    false
  ];
  final selection = const vt.ThemeReader().read({
    'layers': [
      {
        'id': 'selection',
        'type': 'fill',
        'source': buildings.source,
        'source-layer': 'building',
        'paint': {
          'fill-color': '#e53935',
          'fill-opacity': ['case', selected, 0.7, 0],
        },
      },
      {
        'id': 'selection-road',
        'type': 'line',
        'source': buildings.source,
        'source-layer': 'transportation',
        'paint': {
          'line-color': '#e53935',
          'line-width': 6,
          'line-opacity': ['case', selected, 0.8, 0],
        },
      },
    ],
  });
  return vt.Theme(
      id: '${theme.id}+selection',
      layers: [...theme.layers, ...selection.layers]);
}

/// One query run over a map parked at [Env.idleZoom] and settled.
class QueryRun {
  QueryRun({
    required this.map,
    required this.features,
    required this.recorder,
    required this.size,
    required this.quiet,
    required this.frame,
  });

  final MapController map;
  final vt.VectorTileLayerController features;
  final FrameRecorder recorder;

  /// The screen the queries cover.
  final Size size;

  /// Forces frames until nothing has been rasterized or laid out for
  /// `quiet`; see the bench page's `_quiet`.
  final Future<Quiet> Function({Duration quiet}) quiet;

  /// The number of the frame being drawn.
  final int Function() frame;

  Future<void> run(vt.Style style) async {
    final hits = _taps();
    await _stateChanges(hits);
    await _shot();
    await _decode(style);
    await _walk();
    benchLog('MEMORY retainAllProperties=${Env.retainAll} '
        'rss=${(ProcessInfo.currentRss / 1048576).toStringAsFixed(0)} MiB');
  }

  /// 1. Taps: a point query on a 12×20 grid over the whole screen, then
  /// 48 px squares around the same points — the tolerance a finger
  /// usually gets. Returns the buildings and roads the points hit.
  List<(String, Iterable<vt.RenderedFeature>)> _taps() {
    final pointUs = <int>[], rectUs = <int>[];
    var pointHits = 0, rectHits = 0;
    final buildings = <Object, vt.RenderedFeature>{};
    final roads = <Object, vt.RenderedFeature>{};
    for (var iy = 0; iy < 20; iy++) {
      for (var ix = 0; ix < 12; ix++) {
        final p =
            Offset((ix + 0.5) * size.width / 12, (iy + 0.5) * size.height / 20);
        final watch = Stopwatch()..start();
        final hits = features.queryRenderedFeatures(p);
        pointUs.add(watch.elapsedMicroseconds);
        pointHits += hits.length;
        for (final hit in hits) {
          if (hit.id == null) continue;
          if (hit.sourceLayer == 'building') buildings[hit.id!] = hit;
          if (hit.sourceLayer == 'transportation') roads[hit.id!] = hit;
        }
        watch
          ..reset()
          ..start();
        final inRect = features.queryRenderedFeaturesInRect(
            Rect.fromCenter(center: p, width: 48, height: 48));
        rectUs.add(watch.elapsedMicroseconds);
        rectHits += inRect.length;
      }
    }
    benchLog('QUERY point ${distribution(pointUs)} ms '
        'hits/query=${(pointHits / pointUs.length).toStringAsFixed(1)}');
    benchLog('QUERY rect48 ${distribution(rectUs)} ms '
        'hits/query=${(rectHits / rectUs.length).toStringAsFixed(1)}');
    return [('building', buildings.values), ('road', roads.values)];
  }

  /// 2. One state change at a time: select a feature, wait for the
  /// tiles it touches to be drawn again, clear it, wait again — 20
  /// buildings, then 20 roads. A clear that rasterizes nothing was
  /// served from the finished-tile cache.
  Future<void> _stateChanges(
      List<(String, Iterable<vt.RenderedFeature>)> kinds) async {
    recorder.start();
    final work0 = WorkCounters.now();
    for (final (kind, hits) in kinds) {
      final setMs = <int>[], clearMs = <int>[];
      final setFrames = <int>[], clearFrames = <int>[];
      final setTiles = <int>[], clearTiles = <int>[];
      final setRasterUs = <int>[];
      final kindLayouts0 = SymbolLayouter.debugLayoutCount;
      for (final feature in hits.take(20)) {
        for (final select in [true, false]) {
          final tiles0 = TileRasterizer.debugRasterizeCount;
          final rasterUs0 = TileRasterizer.debugRasterizeMicros;
          final frame0 = frame();
          final t0 = DateTime.now();
          if (select) {
            features.setFeatureState(
                source: feature.source,
                sourceLayer: feature.sourceLayer,
                id: feature.id!,
                state: {'selected': true});
          } else {
            features.removeFeatureState(
                source: feature.source,
                sourceLayer: feature.sourceLayer,
                id: feature.id!);
          }
          final done = await quiet();
          // Counted in thousandths, for [distribution].
          final tiles = TileRasterizer.debugRasterizeCount - tiles0;
          final ms = tiles == 0 ? 0 : done.at.difference(t0).inMilliseconds;
          final frames = tiles == 0 ? 0 : done.frame - frame0;
          (select ? setMs : clearMs).add(ms * 1000);
          (select ? setFrames : clearFrames).add(frames * 1000);
          (select ? setTiles : clearTiles).add(tiles * 1000);
          if (select) {
            setRasterUs.add(TileRasterizer.debugRasterizeMicros - rasterUs0);
          }
        }
      }
      benchLog('STATE $kind '
          'n=${math.min(20, hits.length)} '
          'relayouts=${SymbolLayouter.debugLayoutCount - kindLayouts0}');
      benchLog('STATE $kind set   ms ${distribution(setMs)} · '
          'frames ${distribution(setFrames)} · tiles ${distribution(setTiles)} · '
          'raster-ms ${distribution(setRasterUs)}');
      benchLog('STATE $kind clear ms ${distribution(clearMs)} · '
          'frames ${distribution(clearFrames)} · tiles ${distribution(clearTiles)}');
    }
    recorder.stop();
    recorder.report('query state changes', WorkCounters.now().since(work0));
  }

  /// A selected building held still for a screenshot (`SHOT` is the cue
  /// for whoever is driving `adb exec-out screencap`).
  Future<void> _shot() async {
    final centre = Offset(size.width / 2, size.height / 2);
    final shown = features
        .queryRenderedFeaturesInRect(
            Rect.fromCenter(center: centre, width: 200, height: 200))
        .where((f) => f.sourceLayer == 'building' && f.id != null)
        .firstOrNull;
    if (shown == null) return;
    features.setFeatureState(
        source: shown.source,
        sourceLayer: shown.sourceLayer,
        id: shown.id!,
        state: {'selected': true});
    await quiet();
    benchLog('SHOT selected ${shown.layerId} '
        'id=${shown.id} ${shown.properties}');
    await Future<void>.delayed(const Duration(seconds: 6));
    features.removeFeatureState(
        source: shown.source, sourceLayer: shown.sourceLayer, id: shown.id!);
    await quiet();
  }

  /// 3. Decoding with every property against the style's own, over the
  /// data tiles under the screen, on this thread — the same work the
  /// worker isolates do, measured without their queue.
  Future<void> _decode(vt.Style style) async {
    final sourceId = style.theme.layers
        .where((l) => l.sourceLayer == 'building')
        .firstOrNull
        ?.source;
    final provider = sourceId == null ? null : style.providers[sourceId];
    if (provider == null) return;
    final keep = _keepLists(style.theme, sourceId!);
    final all = <String, Set<String>?>{for (final sl in keep.keys) sl: null};
    final z = provider.maximumZoom;
    final (cx, cy) = _tileUnder(Env.lat, Env.lon, z);
    var styledBytes = 0, allBytes = 0;
    final styledUs = <int>[], allUs = <int>[];
    for (var dy = -1; dy <= 1; dy++) {
      for (var dx = -1; dx <= 1; dx++) {
        final key = vt.TileKey(z, cx + dx, cy + dy);
        final response = await provider.load(key);
        if (response is! vt.TileResponseData) continue;
        final styled = _medianDecode(key, response.bytes, keep);
        styledUs.add(styled.us);
        styledBytes += styled.bytes;
        final every = _medianDecode(key, response.bytes, all);
        allUs.add(every.us);
        allBytes += every.bytes;
      }
    }
    benchLog('DECODE tiles=${styledUs.length} z$z '
        'styled ${(styledBytes / 1048576).toStringAsFixed(2)} MiB '
        '${distribution(styledUs)} ms · all ${(allBytes / 1048576).toStringAsFixed(2)} '
        'MiB ${distribution(allUs)} ms · ×${(allBytes / styledBytes).toStringAsFixed(2)}');
  }

  /// Per source layer of [sourceId], the properties the style reads, or
  /// null where some layer needs them all.
  static Map<String, Set<String>?> _keepLists(vt.Theme theme, String sourceId) {
    final keep = <String, Set<String>?>{};
    for (final layer in theme.layers) {
      final sl = layer.sourceLayer;
      if (layer.source != sourceId || sl == null) continue;
      final mine = layer.referencedProperties;
      keep[sl] = keep.containsKey(sl)
          ? (keep[sl] == null || mine == null ? null : {...keep[sl]!, ...mine})
          : mine?.toSet();
    }
    return keep;
  }

  /// The web-mercator tile at zoom [z] that holds [lat], [lon].
  static (int, int) _tileUnder(double lat, double lon, int z) {
    final n = 1 << z;
    final latRad = lat * math.pi / 180;
    return (
      ((lon + 180) / 360 * n).floor(),
      ((1 - math.log(math.tan(latRad) + 1 / math.cos(latRad)) / math.pi) /
              2 *
              n)
          .floor(),
    );
  }

  /// The median of five decodes of [key] keeping [properties], and the
  /// decoded tile's size.
  static ({int us, int bytes}) _medianDecode(
      vt.TileKey key, Uint8List bytes, Map<String, Set<String>?> properties) {
    final runs = <int>[];
    var size = 0;
    for (var i = 0; i < 5; i++) {
      final watch = Stopwatch()..start();
      final tile = prepareTileSync(PrepareInput(
          z: key.z,
          x: key.x,
          y: key.y,
          bytes: bytes,
          layerProperties: properties));
      runs.add(watch.elapsedMicroseconds);
      size = tile.byteSize;
    }
    runs.sort();
    return (us: runs[2], bytes: size);
  }

  /// 4. What the process holds after the same walk: four screens away
  /// and back, each left to finish.
  Future<void> _walk() async {
    for (final (dx, dy) in [(1, 0), (1, 1), (0, 1), (0, 0)]) {
      final camera = map.camera;
      final offset = Offset(dx * size.width, dy * size.height);
      final centre =
          camera.unprojectAtZoom(camera.projectAtZoom(Env.centre) + offset);
      map.move(centre, Env.idleZoom);
      await quiet(quiet: const Duration(seconds: 2));
    }
  }
}
