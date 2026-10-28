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
/// Matching is one-to-one per publish, nearest pairs first, and within
/// one zoom level it is reserved for twins: two labels of one tile never
/// share an id, and a tile may only share an id with a *different* tile
/// of its own level when its anchor coincides with the copy that tile
/// holds ([twinRadius]) — the one feature on a seam that both
/// neighbours lay out (the layouter lets both claim it rather than risk
/// neither doing so). Every holding keeps its own copy's position for
/// that reason: judged against whichever copy registered last (another
/// level's, say), the rule would merge a neighbour's different label and
/// miss a true twin. Without that rule two distinct
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
///
/// Most names are rare, and a publish simply compares each symbol with
/// the few labels known under its name. Some are not: icon-only labels
/// all share an empty text, so a city centre offers hundreds of one-way
/// arrows or waste baskets under a single key, and comparing every
/// symbol with every one of them made a tile publish cost milliseconds
/// on a phone. A name with more than [gridFrom] labels is therefore
/// also filed by where its copies are, and only the copies around a
/// symbol are compared — the same candidates, found without the scan.
class LabelIdentityIndex {
  /// [gridFrom]: how many labels a name holds before [assign] looks its
  /// candidates up by position rather than scanning them all. Only tests
  /// change it — at 0 every name is looked up by position, which must
  /// match exactly what the scan matches.
  LabelIdentityIndex({this.gridFrom = 16});

  final int gridFrom;

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

  final _byKey = <Object, _KeyLabels>{};
  final _byId = <int, _LabelEntry>{};
  var _nextId = 1;
  var _batch = 0;
  var _visit = 0;

  /// Distinct labels currently held — for tests asserting that what was
  /// assigned is also released.
  int get length => _byId.length;

  static final _none = Int32List(0);

  /// Assigns an id to each of [symbols], laid out for display tile
  /// [tile], and registers [tile] as their holder. [replacing] is the
  /// tile's previous ids, if it is republishing: they are matched first
  /// and released afterwards, so a label the new layout still carries
  /// keeps its id.
  ///
  /// Within one name, the closest pairs are matched first (the tile's
  /// own previous labels ahead of everyone else's), so a label never
  /// loses its nearest predecessor to a neighbour that merely came
  /// first in layout order.
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
    final unit = _unit(tile.z);
    final ids = Int32List(symbols.length);
    final xs = Float64List(symbols.length);
    final ys = Float64List(symbols.length);
    final byKey = <Object, List<int>>{};
    for (var i = 0; i < symbols.length; i++) {
      final anchor = symbols[i].anchor;
      xs[i] = (tile.x * TileRasterizer.logicalTileSize + anchor.dx) * unit;
      ys[i] = (tile.y * TileRasterizer.logicalTileSize + anchor.dy) * unit;
      (byKey[symbols[i].continuityKey] ??= <int>[]).add(i);
    }
    byKey.forEach((key, group) {
      final labels = _byKey[key] ??= _KeyLabels();
      final entries = labels.entries;
      if (entries.isNotEmpty) {
        final pairs = <_Pair>[];
        final grid = labels.grid;
        for (final i in group) {
          if (grid == null) {
            for (final entry in entries) {
              final pair = _pair(entry, tile, i, xs[i], ys[i], unit);
              if (pair != null) pairs.add(pair);
            }
            continue;
          }
          // Every label with a copy close enough to match has one in
          // the 3×3 cells around the symbol on that copy's level, since
          // a cell is as wide as the widest radius a copy there matches
          // at. Each is judged by [_pair] on all its copies, as above.
          final visit = ++_visit;
          for (final level in grid.entries) {
            final size = _cellSize(level.key);
            final cx = (xs[i] / size).floor();
            final cy = (ys[i] / size).floor();
            for (var dx = -1; dx <= 1; dx++) {
              for (var dy = -1; dy <= 1; dy++) {
                final cell = level.value[_cell(cx + dx, cy + dy)];
                if (cell == null) continue;
                for (final entry in cell) {
                  if (entry.visit == visit) continue;
                  entry.visit = visit;
                  final pair = _pair(entry, tile, i, xs[i], ys[i], unit);
                  if (pair != null) pairs.add(pair);
                }
              }
            }
          }
        }
        pairs.sort(_Pair.compare);
        for (final pair in pairs) {
          final entry = pair.entry;
          // One-to-one: a symbol takes one label, a label one symbol.
          if (ids[pair.symbol] != 0 || entry.batch == batch) continue;
          entry.batch = batch;
          ids[pair.symbol] = entry.id;
        }
      }
      for (final i in group) {
        var entry = _byId[ids[i]];
        if (entry == null) {
          entry = _LabelEntry(_freshId(), key)..batch = batch;
          entry.slot = entries.length;
          entries.add(entry);
          _byId[entry.id] = entry;
          ids[i] = entry.id;
          if (labels.grid == null && entries.length > gridFrom) {
            // Common enough now: file everything known so far.
            final grid = labels.grid = {};
            for (final known in entries) {
              for (final holding in known.holdings) {
                _file(grid, known, holding);
              }
            }
          }
        }
        final holding = _Holding(tile, xs[i], ys[i]);
        entry.holdings.add(holding);
        final grid = labels.grid;
        if (grid != null) _file(grid, entry, holding);
      }
    });
    if (replacing != null) release(tile, replacing);
    return ids;
  }

  /// How symbol [symbol] of [tile], at world position ([x], [y]), would
  /// match [entry] — or null when it may not. It may when one of the
  /// entry's copies is within [matchRadius] (in the finer level's
  /// pixels: the tolerance a crossing is seen at), and every copy on
  /// [tile]'s own level that another tile holds is its twin. The
  /// distance that ranks the pair is to the nearest copy.
  static _Pair? _pair(_LabelEntry entry, TileKey tile, int symbol, double x,
      double y, double unit) {
    final twin = twinRadius * unit;
    var own = false;
    var nearest = double.infinity;
    for (final holding in entry.holdings) {
      final dx = holding.x - x;
      final dy = holding.y - y;
      final distance = dx * dx + dy * dy;
      final holder = holding.tile;
      if (holder == tile) {
        own = true;
      } else if (holder.z == tile.z && distance >= twin * twin) {
        return null;
      }
      final radius = matchRadius * math.min(unit, _unit(holder.z));
      if (distance < radius * radius && distance < nearest) nearest = distance;
    }
    if (nearest == double.infinity) return null;
    return _Pair(symbol, entry, own, nearest);
  }

  /// [tile] stops offering the labels [ids]: each loses that holding,
  /// and a label no holder offers any more is forgotten.
  void release(TileKey tile, Int32List ids) {
    for (final id in ids) {
      final entry = _byId[id];
      if (entry == null) continue;
      final holdings = entry.holdings;
      final at = holdings.indexWhere((holding) => holding.tile == tile);
      if (at < 0) continue;
      final holding = holdings.removeAt(at);
      final labels = _byKey[entry.key]!;
      final grid = labels.grid;
      if (grid != null) _unfile(grid, entry, holding);
      if (holdings.isNotEmpty) continue;
      _byId.remove(id);
      // Swapped out rather than removed in place: a common name holds
      // hundreds of labels, and a tile hands back hundreds at once.
      final entries = labels.entries;
      final last = entries.removeLast();
      if (!identical(last, entry)) {
        entries[entry.slot] = last;
        last.slot = entry.slot;
      }
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

  /// The width of a level-[z] cell of [_KeyLabels.grid], in world units:
  /// the widest radius a copy on that level matches at.
  static double _cellSize(int z) => matchRadius * _unit(z);

  /// The [_KeyLabels.grid] key of cell ([cx], [cy]). Distinct cells may
  /// share one far out (past 2^26 cells a row, or on the web's doubles),
  /// which only adds candidates that [_pair] then turns down.
  static int _cell(int cx, int cy) => cx * 67108864 + cy;

  static void _file(Map<int, Map<int, List<_LabelEntry>>> grid,
      _LabelEntry entry, _Holding holding) {
    final size = _cellSize(holding.tile.z);
    final cell = _cell((holding.x / size).floor(), (holding.y / size).floor());
    ((grid[holding.tile.z] ??= {})[cell] ??= []).add(entry);
  }

  static void _unfile(Map<int, Map<int, List<_LabelEntry>>> grid,
      _LabelEntry entry, _Holding holding) {
    final cells = grid[holding.tile.z];
    if (cells == null) return;
    final size = _cellSize(holding.tile.z);
    final cell = _cell((holding.x / size).floor(), (holding.y / size).floor());
    final filed = cells[cell];
    if (filed == null) return;
    filed.remove(entry);
    if (filed.isNotEmpty) return;
    cells.remove(cell);
    if (cells.isEmpty) grid.remove(holding.tile.z);
  }

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

/// The labels known under one continuity key.
class _KeyLabels {
  final entries = <_LabelEntry>[];

  /// Once the name is common ([LabelIdentityIndex.gridFrom]): per level,
  /// the labels with a copy in each cell of that level (see
  /// [LabelIdentityIndex._cellSize]), one listing per copy.
  Map<int, Map<int, List<_LabelEntry>>>? grid;
}

class _LabelEntry {
  final int id;
  final Object key;

  /// The [LabelIdentityIndex.assign] call that last claimed this label.
  var batch = 0;

  /// The grid lookup that last visited this label, so a label with
  /// copies in several cells is judged once per symbol.
  var visit = 0;

  /// Where this label sits in its [_KeyLabels.entries].
  var slot = 0;

  /// One copy per tile offering this label, where that tile has it.
  final holdings = <_Holding>[];

  _LabelEntry(this.id, this.key);
}

/// One tile's copy of a label: the tile, and the copy's world position
/// (the world is 1 wide).
class _Holding {
  final TileKey tile;
  final double x;
  final double y;

  _Holding(this.tile, this.x, this.y);
}

/// A candidate match between a symbol being assigned and a known label.
class _Pair {
  final int symbol;
  final _LabelEntry entry;

  /// Whether the label is one of the assigning tile's own previous ones.
  final bool own;

  /// Squared world distance to the label's nearest copy.
  final double distance;

  _Pair(this.symbol, this.entry, this.own, this.distance);

  /// Own labels first, then nearest first; exact ties by the older label,
  /// then layout order, so the outcome never depends on the order the
  /// candidates were found in.
  static int compare(_Pair a, _Pair b) {
    if (a.own != b.own) return a.own ? -1 : 1;
    final byDistance = a.distance.compareTo(b.distance);
    if (byDistance != 0) return byDistance;
    final byId = a.entry.id - b.entry.id;
    if (byId != 0) return byId;
    return a.symbol - b.symbol;
  }
}
