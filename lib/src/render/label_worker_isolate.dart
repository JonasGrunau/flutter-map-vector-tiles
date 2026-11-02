import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' show Offset, Size;

import '../cache/lru_cache.dart';
import '../style/sprite_atlas.dart';
import '../style/theme.dart';
import 'label_painter.dart';
import 'label_worker.dart';
import 'symbol_layouter.dart';

LabelPlacementWorker? createLabelWorker() => _IsolateLabelWorker();

/// The UI isolate's end of the placement worker.
class _IsolateLabelWorker implements LabelPlacementWorker {
  /// Symbol lists the worker holds at once. A screen's current and
  /// retained tiles are a few dozen; the rest is what a zoom round trip
  /// brings back from the finished-tile cache.
  static const _maxMirrors = 256;

  final _inbox = ReceivePort();
  SendPort? _port;
  Isolate? _isolate;
  var _failed = false;
  var _disposed = false;
  var _installed = false;

  /// Bumped by every [install]: mirrors and passes of an older epoch are
  /// interpreted against a theme that no longer applies.
  var _epoch = 0;

  /// Messages sent before the isolate reported its port.
  final _queue = <Object?>[];

  final _mirrorIds = Expando<int>();

  /// Where each mirrored instance sits: its mirror and index. A list made
  /// only of instances one live mirror already holds — the retention pin
  /// cuts a retained tile's list down to what was drawn — is sent as
  /// indices into that mirror rather than packed again.
  final _slots = Expando<(int, int)>();
  var _nextMirror = 0;
  late final _mirrors = LruCache<int, int>(
    maxEntries: _maxMirrors,
    onEvict: (id, bytes) {
      LabelPlacementWorker.debugMirrorLiveBytes -= bytes;
      _send(('drop', id));
    },
  );

  final _waiting = <int, void Function(LabelPassResult)>{};

  _IsolateLabelWorker() {
    _inbox.listen(_onMessage);
    Isolate.spawn(_main, _inbox.sendPort,
            debugName: 'flutter_map_vector_tiles labels',
            onExit: _inbox.sendPort,
            errorsAreFatal: false)
        .then((isolate) {
      if (_disposed) {
        isolate.kill(priority: Isolate.immediate);
      } else {
        _isolate = isolate;
      }
    }, onError: (Object _) => _fail());
  }

  @override
  bool get ready => _port != null && _installed && !_failed && !_disposed;

  @override
  void install(Theme theme, final Map<String, Sprite>? sprites) {
    _epoch++;
    _installed = true;
    _waiting.clear();
    _mirrors.clear();
    LabelPlacementWorker.debugMirrorLiveBytes = 0;
    _send(('install', _epoch, theme, sprites));
  }

  @override
  int mirror(List<SymbolInstance> symbols, LabelMirror Function() build) {
    final known = _mirrorIds[symbols];
    if (known != null && _mirrors.get(known) != null) return known;
    final stopwatch = Stopwatch()..start();
    final id = ++_nextMirror;
    _mirrorIds[symbols] = id;
    final subset = _subsetOf(symbols);
    final int bytes;
    if (subset != null) {
      bytes = subset.$2.lengthInBytes;
      _send(('subset', id, subset.$1, subset.$2));
    } else {
      final mirror = build();
      bytes = mirror.byteSize;
      _send(('mirror', id, mirror));
      for (var i = 0; i < symbols.length; i++) {
        _slots[symbols[i]] = (id, i);
      }
    }
    _mirrors.put(id, bytes);
    LabelPlacementWorker.debugMirrorCount++;
    LabelPlacementWorker.debugMirrorBytes += bytes;
    LabelPlacementWorker.debugMirrorLiveBytes += bytes;
    LabelPlacementWorker.debugMirrorMicros += stopwatch.elapsedMicroseconds;
    return id;
  }

  /// The mirror holding every one of [symbols], with their indices in
  /// it, or null when no single live mirror does.
  (int, Int32List)? _subsetOf(List<SymbolInstance> symbols) {
    final parent = _slots[symbols.first]?.$1;
    if (parent == null || !_mirrors.containsKey(parent)) return null;
    final indices = Int32List(symbols.length);
    for (var i = 0; i < symbols.length; i++) {
      final slot = _slots[symbols[i]];
      if (slot == null || slot.$1 != parent) return null;
      indices[i] = slot.$2;
    }
    return (parent, indices);
  }

  @override
  void place(
      LabelPassRequest request, void Function(LabelPassResult) onResult) {
    _waiting[request.id] = onResult;
    _send(('pass', _epoch, request));
  }

  void _send(Object? message) {
    if (_disposed || _failed) return;
    final port = _port;
    if (port == null) {
      _queue.add(message);
      return;
    }
    try {
      port.send(message);
    } on ArgumentError {
      // Something in the message cannot cross isolates. Placement goes
      // back in-frame rather than failing the frame that sent it.
      _fail();
    }
  }

  void _onMessage(Object? message) {
    switch (message) {
      case final SendPort port:
        _port = port;
        final queued = [..._queue];
        _queue.clear();
        queued.forEach(_send);
      case (final int epoch, final LabelPassResult result):
        final onResult = _waiting.remove(result.id);
        if (epoch == _epoch && onResult != null) onResult(result);
      case null:
        // The isolate exited (onExit): placement goes back in-frame.
        _fail();
      default:
        // An uncaught error report from the isolate; errors are not
        // fatal there, so keep going.
        break;
    }
  }

  void _fail() {
    _failed = true;
    _waiting.clear();
    _queue.clear();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _waiting.clear();
    _queue.clear();
    _isolate?.kill(priority: Isolate.immediate);
    _inbox.close();
  }
}

/// The worker isolate: a [LabelPainter.worker] over the mirrored lists.
void _main(SendPort out) {
  final inbox = ReceivePort();
  out.send(inbox.sendPort);
  final painter = LabelPainter.worker();
  Theme? theme;
  var epoch = 0;
  final mirrors = <int, List<SymbolInstance?>>{};
  inbox.listen((message) {
    switch (message) {
      case (
          'install',
          final int e,
          final Theme t,
          final Map<String, Sprite>? sprites
        ):
        epoch = e;
        theme = t;
        mirrors.clear();
        painter.installWorker(sprites);
      case ('mirror', final int id, final LabelMirror mirror):
        final current = theme;
        if (current != null) mirrors[id] = painter.adoptMirror(mirror, current);
      case ('subset', final int id, final int parent, final Int32List indices):
        final list = mirrors[parent];
        if (list != null) mirrors[id] = [for (final i in indices) list[i]];
      case ('drop', final int id):
        mirrors.remove(id);
      case ('pass', final int e, final LabelPassRequest request):
        out.send((e, _pass(painter, mirrors, request, current: e == epoch)));
    }
  });
}

LabelPassResult _pass(
  LabelPainter painter,
  Map<int, List<SymbolInstance?>> mirrors,
  LabelPassRequest request, {
  required bool current,
}) {
  final stopwatch = Stopwatch()..start();
  final symbols = <PlacedSymbol>[];
  var missing = 0;
  if (current) {
    for (final cohort in request.cohorts) {
      final list = mirrors[cohort.mirror];
      if (list == null || list.length != cohort.ids.length) {
        missing++;
        continue;
      }
      final transform = TileTransform(
        origin: Offset(cohort.originX, cohort.originY),
        scale: cohort.scale,
        rotation: cohort.rotation,
      );
      for (var i = 0; i < list.length; i++) {
        final symbol = list[i];
        if (symbol == null) continue;
        symbols.add(PlacedSymbol(
          instance: symbol,
          id: cohort.ids[i],
          screenAnchor: transform.apply(symbol.anchor),
          screenAngle: symbol.angle + cohort.rotation,
          transform: transform,
          retained: cohort.retained,
          order: cohort.order + i,
        ));
      }
    }
  }
  final winners = symbols.isEmpty
      ? const <PlacedSymbol>[]
      : painter.placeForWorker(
          screenSize: Size(request.width, request.height),
          styleZoom: request.styleZoom,
          symbols: symbols,
          incumbents: request.incumbents,
          drawnCopies: request.drawnCopies,
        );
  final ids = Int32List(winners.length);
  final copies = Int32List(winners.length);
  final anchors = List<String?>.filled(winners.length, null);
  final textDropped = Uint8List(winners.length);
  final iconDropped = Uint8List(winners.length);
  for (var w = 0; w < winners.length; w++) {
    final winner = winners[w];
    ids[w] = winner.id;
    copies[w] = winner.order;
    final decision = painter.decisionOf(winner);
    anchors[w] = decision.anchor;
    textDropped[w] = decision.textDropped ? 1 : 0;
    iconDropped[w] = decision.iconDropped ? 1 : 0;
  }
  return (
    id: request.id,
    winners: ids,
    copies: copies,
    missingCohorts: missing,
    anchors: anchors,
    textDropped: textDropped,
    iconDropped: iconDropped,
    micros: stopwatch.elapsedMicroseconds,
  );
}
