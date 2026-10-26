import 'dart:math' as math;
import 'dart:typed_data';

import '../core/tile_key.dart';
import 'symbol_layouter.dart';
import 'tile_rasterizer.dart';

/// Gives every label on offer a stable integer identity that outlives
/// the [SymbolInstance] carrying it — the cross-tile symbol index of
/// this package.
///
/// A `SymbolInstance` is built per display-tile layout, so a
/// provisional→final republish, a refresh, a zoom crossing or a cache
/// hit hands the label pass a brand-new object for a label that never
/// left the screen. Everything the pass remembers about a label — the
/// winner set, its fade, its placement choices — is keyed on the id
/// this index hands out instead, so it carries over to the successor
/// unchanged. Without it, all of that had to be keyed by instance (lost
/// at every replacement) or re-matched by screen position every frame.
///
/// Ids are assigned when a tile publishes its symbols ([assign]), by
/// matching each instance against the labels already on offer: the
/// same continuity key (`(layer, text, icon)`, see
/// `SymbolInstance.continuityKey`) at the same place in world space,
/// within [matchRadius]. A match inherits that label's id; anything
/// else gets a fresh one. The tolerance is what absorbs the noise
/// between two layouts of one label — a coarser level simplifies the
/// geometry differently, an ancestor-data (provisional) layout clips it
/// differently — while staying well inside the default
/// `symbol-spacing`, so the repeats of one name along a street keep
/// their own ids. MapLibre's `CrossTileSymbolIndex` matches the same
/// way, for the same reason.
///
/// Matching is one-to-one per publish, and within one zoom level it is
/// reserved for twins: two labels of one tile never share an id, and a
/// tile may only share an id with a *different* tile of its own level
/// when the two anchors coincide ([twinRadius]) — the one feature on a
/// seam that both neighbours lay out (the layouter lets both claim it
/// rather than risk neither doing so). Without that rule two distinct
/// same-named labels a few pixels apart on either side of a seam would
/// merge into one, and only one of them would draw. Across levels, and
/// against the tile's own previous layout, the full [matchRadius]
/// applies, preferring the tile's own previous ids: whatever was on
/// screen from this tile stays the label it was.
///
/// Holders own their ids: [assign] returns one id per symbol, and the
/// holder — a current or retained tile, or a parked ghost cohort —
/// hands them back with [release] when it stops offering them. A label
/// stays known for as long as any holder offers it, which is exactly as
/// long as the label pass can draw it. Pure Dart, no clock.
class LabelIdentityIndex {
  /// How far apart two layouts of one label may be and still share its
  /// id, in logical pixels of the finer of the two levels. A zoom
  /// crossing over the same data moves nothing (along-line anchors are
  /// nested, point anchors are vertices); new data moves polygon
  /// centroids and along-line anchors by however differently it clips.
  /// The same radius the per-frame screen-space matching used before
  /// this index existed.
  static const double matchRadius = 32.0;

  /// How close a same-level copy on another tile must be to count as
  /// the twin of a seam label, in logical pixels: both neighbours
  /// compute it from the same data, so it coincides up to float noise
  /// (or quantization, when one side is still provisional).
  static const double twinRadius = 1.0;

  final _byKey = <Object, List<_LabelEntry>>{};
  final _byId = <int, _LabelEntry>{};
  var _nextId = 1;
  var _batch = 0;

  /// Distinct labels currently held — for tests asserting that what was
  /// assigned is also released.
  int get length => _byId.length;

  static final _none = Int32List(0);

  /// Assigns an id to each of [symbols], laid out for display tile
  /// [tile], and registers [tile] as their holder. [replacing] is the
  /// tile's previous ids, if it is republishing: they are matched first
  /// and released afterwards, so a label the new layout still carries
  /// keeps its id.
  Int32List assign(
    TileKey tile,
    List<SymbolInstance> symbols, {
    Int32List? replacing,
  }) {
    if (symbols.isEmpty) {
      if (replacing != null) release(tile, replacing);
      return _none;
    }
    final batch = ++_batch;
    final z = tile.z;
    final unit = _unit(z);
    final ids = Int32List(symbols.length);
    for (var i = 0; i < symbols.length; i++) {
      final symbol = symbols[i];
      final key = symbol.continuityKey;
      final x =
          (tile.x * TileRasterizer.logicalTileSize + symbol.anchor.dx) * unit;
      final y =
          (tile.y * TileRasterizer.logicalTileSize + symbol.anchor.dy) * unit;
      final entries = _byKey[key] ??= <_LabelEntry>[];
      var entry = _match(entries, tile, x, y, unit, batch);
      if (entry == null) {
        entry = _LabelEntry(_freshId(), key);
        entries.add(entry);
        _byId[entry.id] = entry;
      }
      entry
        ..x = x
        ..y = y
        ..z = z
        ..batch = batch
        ..holders.add(tile);
      ids[i] = entry.id;
    }
    if (replacing != null) release(tile, replacing);
    return ids;
  }

  /// The entry among [entries] that a symbol of [tile] at world
  /// position ([x], [y]) is a copy of, or null. See the class comment
  /// for the rules.
  static _LabelEntry? _match(
    List<_LabelEntry> entries,
    TileKey tile,
    double x,
    double y,
    double unit,
    int batch,
  ) {
    _LabelEntry? best;
    var bestOwn = false;
    var bestDistance = double.infinity;
    for (final entry in entries) {
      // Already claimed by another symbol of this tile.
      if (entry.batch == batch) continue;
      final dx = entry.x - x;
      final dy = entry.y - y;
      final distance = dx * dx + dy * dy;
      // The finer level's pixels: the tolerance a crossing is seen at.
      final radius = matchRadius * math.min(unit, _unit(entry.z));
      if (distance >= radius * radius) continue;
      final own = entry.holders.contains(tile);
      if (!own && !_twinOrOtherLevel(entry, tile, distance, unit)) continue;
      if (best == null ||
          (own && !bestOwn) ||
          (own == bestOwn && distance < bestDistance)) {
        best = entry;
        bestOwn = own;
        bestDistance = distance;
      }
    }
    return best;
  }

  /// Whether [entry], held by tiles other than [tile], may be shared
  /// with it: every holder on [tile]'s own level must be a seam twin.
  static bool _twinOrOtherLevel(
      _LabelEntry entry, TileKey tile, double distance, double unit) {
    final twin = twinRadius * unit;
    for (final holder in entry.holders) {
      if (holder.z == tile.z && holder != tile && distance >= twin * twin) {
        return false;
      }
    }
    return true;
  }

  /// [tile] stops offering the labels [ids]: each loses that holder, and
  /// a label no holder offers any more is forgotten.
  void release(TileKey tile, Int32List ids) {
    for (final id in ids) {
      final entry = _byId[id];
      if (entry == null) continue;
      entry.holders.remove(tile);
      if (entry.holders.isNotEmpty) continue;
      _byId.remove(id);
      final entries = _byKey[entry.key];
      if (entries == null) continue;
      entries.remove(entry);
      if (entries.isEmpty) _byKey.remove(entry.key);
    }
  }

  /// Forgets everything — for theme/provider swaps, where every holder
  /// goes at once and layer indices change meaning.
  void clear() {
    _byKey.clear();
    _byId.clear();
  }

  /// One logical pixel of a level-[z] display tile, in world units (the
  /// world is 1 wide).
  static double _unit(int z) =>
      1 / (TileRasterizer.logicalTileSize * math.pow(2, z));

  int _freshId() {
    // Ids stay within 31 bits (an Int32List holds them, and web ints
    // are doubles). Wrapping takes two billion labels; skipping live
    // ids keeps it safe even then.
    while (true) {
      final id = _nextId;
      _nextId = _nextId >= 0x7fffffff ? 1 : _nextId + 1;
      if (!_byId.containsKey(id)) return id;
    }
  }
}

class _LabelEntry {
  final int id;
  final Object key;

  /// World position of the copy registered last (the world is 1 wide),
  /// and the display level it was laid out at.
  var x = 0.0;
  var y = 0.0;
  var z = 0;

  /// The [LabelIdentityIndex.assign] call that last claimed this label.
  var batch = 0;

  /// The tiles offering this label, one entry per holding.
  final holders = <TileKey>[];

  _LabelEntry(this.id, this.key);
}
