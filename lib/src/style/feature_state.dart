/// Feature state: key/value pairs an app attaches to individual features
/// at runtime, per source, source layer and feature id, and the
/// `feature-state` expression reads in paint properties — MapLibre's
/// `setFeatureState`. Owned by a `VectorTileLayerController`; the layer
/// reads it while drawing.
///
/// Ids are matched the way MapLibre matches them, which stringifies
/// both sides: a number and its decimal string are the same feature.
/// Here they meet in the other direction — integral numbers and
/// canonical integer strings normalize to an `int` ([normalizeId]) — so
/// the lookup for an MVT id, the common case, is a plain map probe with
/// no string built per feature.
class FeatureStates {
  /// source → source layer → normalized feature id → state.
  final _states = <String, Map<String, Map<Object, Map<String, Object?>>>>{};

  /// Changes with every change, so anything memoizing a style evaluated
  /// against state can tell it is stale. Drawn from one process-wide
  /// counter, so two stores — a layer handed a new controller — never
  /// share a version once either has changed.
  int get version => _version;
  var _version = 0;
  static var _versions = 0;

  bool get isEmpty => _states.isEmpty;

  /// [id] in the form state is keyed by: an integral number or a
  /// canonical integer string becomes an `int`, anything else is kept.
  static Object normalizeId(Object id) {
    if (id is int) return id;
    if (id is num) {
      // Non-finite first: under dart2js `infinity is int` is true.
      return id.isFinite && id == id.roundToDouble() ? id.toInt() : id;
    }
    if (id is String) {
      final asInt = int.tryParse(id);
      if (asInt != null && asInt.toString() == id) return asInt;
    }
    return id;
  }

  /// The states set in one source layer, keyed by normalized id; null
  /// when none is. Callers drawing many features fetch this once and
  /// probe it per feature (see [stateOf]).
  Map<Object, Map<String, Object?>>? sourceLayer(
          String? source, String? sourceLayer) =>
      source == null || sourceLayer == null
          ? null
          : _states[source]?[sourceLayer];

  /// The state of feature [id] in [states] — the map [sourceLayer]
  /// returned — or null.
  static Map<String, Object?>? stateOf(
          Map<Object, Map<String, Object?>>? states, Object? id) =>
      states == null || id == null ? null : states[normalizeId(id)];

  /// The state of one feature, or null when it has none.
  Map<String, Object?>? lookup(
          String? source, String? sourceLayer, Object? id) =>
      stateOf(this.sourceLayer(source, sourceLayer), id);

  /// Merges [state] into the feature's state, as MapLibre does: keys
  /// not named keep their values. Returns whether anything changed.
  bool set(String source, String sourceLayer, Object id,
      Map<String, Object?> state) {
    if (state.isEmpty) return false;
    final byId = (_states[source] ??= {})[sourceLayer] ??=
        <Object, Map<String, Object?>>{};
    final key = normalizeId(id);
    final current = byId[key];
    if (current != null &&
        state.entries.every(
            (e) => current.containsKey(e.key) && current[e.key] == e.value)) {
      return false;
    }
    byId[key] = {...?current, ...state};
    _version = ++_versions;
    return true;
  }

  /// Removes state: one [key] of feature [id], all of [id]'s state when
  /// [key] is null, or the state of every feature in the source layer
  /// when [id] is null too. Returns the normalized ids whose state
  /// changed — empty when nothing did.
  Set<Object> remove(String source, String sourceLayer,
      {Object? id, String? key}) {
    final bySourceLayer = _states[source];
    final byId = bySourceLayer?[sourceLayer];
    if (byId == null) return const {};
    final Set<Object> changed;
    if (id == null) {
      changed = byId.keys.toSet();
      byId.clear();
    } else {
      final normalized = normalizeId(id);
      final current = byId[normalized];
      if (current == null) return const {};
      if (key == null) {
        byId.remove(normalized);
      } else {
        if (!current.containsKey(key)) return const {};
        final next = {...current}..remove(key);
        if (next.isEmpty) {
          byId.remove(normalized);
        } else {
          byId[normalized] = next;
        }
      }
      changed = {normalized};
    }
    if (byId.isEmpty) bySourceLayer!.remove(sourceLayer);
    if (bySourceLayer!.isEmpty) _states.remove(source);
    if (changed.isNotEmpty) _version = ++_versions;
    return changed;
  }
}
