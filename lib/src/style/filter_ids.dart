import 'dart:convert';

/// Process-wide ids for the layer filters the worker isolates resolve
/// while preparing a tile (see `pipeline/tile_filters.dart`).
///
/// A worker cannot be sent a compiled filter — it is a closure — so it
/// is sent the filter's JSON once, compiles it with the same parser,
/// and is told by number which filters a tile needs. The id is interned
/// by the filter's canonical JSON, never by theme or layer: two layers
/// with the same filter share one, in one theme or across themes (a
/// light and a dark variant of one style, a reopened map that re-read
/// its style), so a tile prepared for one serves the other, and a
/// differing filter can never be mistaken for a stale one.
///
/// Ids are never reused; the table grows with the distinct filters a
/// process compiles, a few hundred for a handful of real styles.
abstract final class FilterIds {
  static final _ids = <String, int>{};
  static final _sources = <String>[];

  /// The id of [filter] — style JSON as decoded, null for "no filter"
  /// — or null when it is not plain JSON, which leaves its layer to be
  /// resolved on the UI isolate.
  static int? intern(Object? filter) {
    final String source;
    try {
      source = jsonEncode(filter);
    } on JsonUnsupportedObjectError {
      return null; // a hand-built style holding NaN, a Set, …
    }
    return _ids.putIfAbsent(source, () {
      _sources.add(source);
      return _sources.length - 1;
    });
  }

  /// The JSON source [id] was interned from, as sent to a worker.
  static String sourceOf(int id) => _sources[id];
}
