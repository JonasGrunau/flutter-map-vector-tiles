import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../style/sprite_atlas.dart';
import '../style/theme.dart';
import 'label_worker_stub.dart' if (dart.library.io) 'label_worker_isolate.dart'
    as impl;
import 'symbol_layouter.dart';

/// A symbol list as a placement worker receives it: everything the label
/// pass reads of its instances, plus the metrics of the text the UI
/// shaped for them. Built by `LabelPainter.mirrorOf`, turned back into
/// instances by `LabelPainter.adoptMirror` on the worker's side.
///
/// Transferable on purpose: an instance references its style layer in
/// the UI isolate's theme, so sending the instances themselves would copy
/// that layer — closures and all — with every list. A mirror names the
/// layer by index into the worker's own copy of the theme instead.
@internal
class LabelMirror {
  /// Per symbol, [intsPerSymbol] values: layer index, flags (see
  /// [flagAlongLine]), path index (-1 for none), index into the feature
  /// lists below, and what placement orders ties by: the feature's
  /// position in its source layer, the geometry part, and the data tile
  /// it came from (z, x, y).
  final Int32List ints;

  /// Per symbol, [realsPerSymbol] values: anchor x and y, angle, path
  /// distance, sort key, and the shaped text's width and height at the
  /// reference size (-1 when the UI shaped none).
  final Float64List reals;
  final List<String> texts;
  final List<String?> icons;

  /// Per symbol: the shaped text's grapheme clusters as centre, width
  /// pairs, for curved text; null otherwise.
  final List<Float32List?> clusters;

  /// The lines along-line symbols sit on, shared by their anchors.
  final List<Float32List> pathPoints;
  final List<Float32List> pathCumulative;

  /// Per feature: properties, geometry type and id, shared by the
  /// feature's symbols.
  final List<Map<String, Object?>> properties;
  final List<String> geometryTypes;
  final List<Object?> featureIds;

  static const intsPerSymbol = 9;
  static const realsPerSymbol = 7;
  static const flagAlongLine = 1;

  LabelMirror({
    required this.ints,
    required this.reals,
    required this.texts,
    required this.icons,
    required this.clusters,
    required this.pathPoints,
    required this.pathCumulative,
    required this.properties,
    required this.geometryTypes,
    required this.featureIds,
  });

  int get length => texts.length;

  /// A rough size, for the mirror-memory figure the bench reports.
  int get byteSize {
    var bytes = ints.lengthInBytes + reals.lengthInBytes;
    for (final text in texts) {
      bytes += 16 + text.length * 2;
    }
    for (final list in clusters) {
      bytes += 8 + (list?.lengthInBytes ?? 0);
    }
    for (var i = 0; i < pathPoints.length; i++) {
      bytes += pathPoints[i].lengthInBytes + pathCumulative[i].lengthInBytes;
    }
    for (final map in properties) {
      bytes += 32 + map.length * 32;
    }
    return bytes;
  }
}

/// One display tile's candidates in a pass request: which mirror, the
/// label ids the tile holds for it, how the tile maps to the screen, and
/// the flags its candidates compete with — the worker projects them
/// itself, exactly as the layer does. The ids travel with every request
/// rather than with the mirror: they belong to the tile that offers the
/// list, and the finished-tile cache hands one list to several tiles.
@internal
typedef LabelCohort = ({
  int mirror,
  Int32List ids,
  double originX,
  double originY,
  double scale,
  double rotation,
  bool retained,
  int order,
});

/// A placement pass for the worker: the screen it places on, the
/// cohorts on offer, and the decision in force on the UI — the label ids
/// whose candidates are incumbents, and by [PlacedSymbol.order] the copy
/// each label was last drawn from, which a pass tries ahead of the
/// label's other copies.
@internal
typedef LabelPassRequest = ({
  int id,
  double width,
  double height,
  double styleZoom,
  List<LabelCohort> cohorts,
  Int32List incumbents,
  Int32List drawnCopies,
});

/// A pass's winners, by label id, with the copy each was placed from
/// (its [PlacedSymbol.order] in the request), the variable anchor it
/// took (null when none applies), and whether its text or its icon was
/// dropped for the other (`text-optional`, `icon-optional`). [micros] is
/// the worker's time for the pass.
@internal
typedef LabelPassResult = ({
  int id,
  Int32List winners,
  Int32List copies,
  int missingCohorts,
  List<String?> anchors,
  Uint8List textDropped,
  Uint8List iconDropped,
  int micros,
});

/// Where placement passes run off the UI thread: a dedicated isolate
/// that holds a copy of the theme and mirrors of the published symbol
/// lists, and answers each pass request with its winners. Null on
/// platforms without isolates (web), where passes stay in-frame.
@internal
abstract class LabelPlacementWorker {
  /// Starts a worker, or returns null where none can run — and always
  /// null while [debugDisabled] is set.
  static LabelPlacementWorker? create() =>
      debugDisabled ? null : impl.createLabelWorker();

  /// Keeps placement in-frame. The test suite sets it (see
  /// `test/flutter_test_config.dart`): widget tests run on a fake clock
  /// that never waits for another isolate's answer, and a frame's
  /// placement has to be decided within it to be asserted on.
  @visibleForTesting
  static var debugDisabled = false;

  /// Bench counters (UI isolate): symbol lists mirrored, their estimated
  /// bytes and the UI microseconds spent packing and sending them; the
  /// estimated bytes of the mirrors the worker holds now.
  static int debugMirrorCount = 0;
  static int debugMirrorBytes = 0;
  static int debugMirrorMicros = 0;
  static int debugMirrorLiveBytes = 0;

  /// Bench counters (UI isolate): pass requests sent and the UI
  /// microseconds spent building them; results adopted, the frames each
  /// waited from its request, and the worker's own microseconds for the
  /// passes they report.
  static int debugRequests = 0;
  static int debugRequestMicros = 0;
  static int debugCommits = 0;
  static int debugCommitLatencyFrames = 0;
  static int debugWorkerMicros = 0;

  /// Bench diagnostics (UI isolate): mirrored symbols with text but no
  /// shaped metrics (the worker places them without text); cohorts a
  /// worker pass could not find a mirror for; winners adopted, and how
  /// many of them drew on the frame that adopted them.
  static int debugUnmeasured = 0;
  static int debugMissingCohorts = 0;
  static int debugAdoptedWinners = 0;
  static int debugAdoptedDrawn = 0;

  /// Whether the isolate is up and a theme is installed.
  bool get ready;

  /// Replaces the theme and sprites every later mirror and pass is
  /// interpreted against. Drops every mirror and any pass in flight.
  void install(Theme theme, Map<String, Sprite>? sprites);

  /// The mirror id of [symbols], mirroring the list first (with [build])
  /// if the worker does not hold it yet.
  int mirror(List<SymbolInstance> symbols, LabelMirror Function() build);

  /// Sends [request]; [onResult] receives its answer on the UI isolate,
  /// unless a later [install] or [dispose] made it moot.
  void place(LabelPassRequest request, void Function(LabelPassResult) onResult);

  void dispose();
}
