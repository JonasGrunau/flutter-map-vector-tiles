/// A deterministic LRU cache with optional per-entry cost accounting
/// (e.g. bytes) and an eviction callback for entries owning native
/// resources (images).
class LruCache<K, V> {
  final int maxEntries;
  int? _maxCost;
  final int Function(V value)? costOf;
  final void Function(K key, V value)? onEvict;

  final _entries = <K, V>{};
  var _totalCost = 0;

  LruCache({
    required this.maxEntries,
    int? maxCost,
    this.costOf,
    this.onEvict,
  })  : _maxCost = maxCost,
        assert(maxEntries > 0);

  int? get maxCost => _maxCost;

  /// Adjusts the cost budget, evicting immediately when the new budget
  /// is tighter than the current contents.
  void setMaxCost(int? value) {
    _maxCost = value;
    _shrink();
  }

  int get length => _entries.length;
  int get totalCost => _totalCost;

  V? get(K key) {
    final value = _entries.remove(key);
    if (value == null) return null;
    _entries[key] = value; // re-insert as most recently used
    return value;
  }

  /// Returns the value without promoting it to most-recently-used.
  V? peek(K key) => _entries[key];

  bool containsKey(K key) => _entries.containsKey(key);

  void put(K key, V value) {
    final previous = _entries.remove(key);
    if (previous != null) {
      _totalCost -= costOf?.call(previous) ?? 0;
      if (!identical(previous, value)) onEvict?.call(key, previous);
    }
    _entries[key] = value;
    _totalCost += costOf?.call(value) ?? 0;
    _shrink();
  }

  V? remove(K key) {
    final value = _entries.remove(key);
    if (value != null) {
      _totalCost -= costOf?.call(value) ?? 0;
    }
    return value;
  }

  /// Removes and disposes (via [onEvict]) all entries.
  void clear() {
    final entries = Map.of(_entries);
    _entries.clear();
    _totalCost = 0;
    entries.forEach((k, v) => onEvict?.call(k, v));
  }

  /// Evicts least-recently-used entries matching [test].
  void removeWhere(bool Function(K key, V value) test) {
    final toRemove = <K>[];
    _entries.forEach((k, v) {
      if (test(k, v)) toRemove.add(k);
    });
    for (final k in toRemove) {
      final v = _entries.remove(k);
      if (v != null) {
        _totalCost -= costOf?.call(v) ?? 0;
        onEvict?.call(k, v);
      }
    }
  }

  Iterable<K> get keys => _entries.keys;

  void _shrink() {
    final maxCost = _maxCost;
    while (_entries.length > maxEntries ||
        (maxCost != null && _totalCost > maxCost && _entries.length > 1)) {
      final key = _entries.keys.first;
      final value = _entries.remove(key) as V;
      _totalCost -= costOf?.call(value) ?? 0;
      onEvict?.call(key, value);
    }
  }
}
