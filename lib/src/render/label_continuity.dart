import '../core/tile_key.dart';
import '../grid/tile_retention.dart';
import 'symbol_layouter.dart';

/// A retained (previous zoom level) tile's labels, as the continuity
/// rules see them.
typedef RetainedCohort = ({TileKey key, List<SymbolInstance> symbols});

/// Identity of a label for cross-zoom continuity: the same text (or the
/// same icon) on the same style layer.
///
/// Deliberately position-free. Geometry simplification differs per zoom
/// level, so the same feature's anchor lands a fraction of a pixel apart
/// at two levels and a position-sensitive key would miss the match. The
/// two failure directions are not symmetric: a *missed* match re-fades a
/// label that is already on screen — the blink this whole mechanism
/// exists to prevent — while a *spurious* match only makes a genuinely
/// new label appear instantly instead of fading in. So the key errs
/// loose on purpose.
Object labelContinuityKey(SymbolInstance symbol) =>
    Object.hash(symbol.layerIndex, symbol.text, symbol.iconName);

/// The continuity keys of every label in [cohorts], for
/// [partitionCarriedOver].
Set<Object> labelContinuityKeys(Iterable<List<SymbolInstance>> cohorts) {
  final keys = <Object>{};
  for (final cohort in cohorts) {
    for (final symbol in cohort) {
      keys.add(labelContinuityKey(symbol));
    }
  }
  return keys;
}

/// The continuity keys of the labels the retained level is currently
/// showing over [key] — what a cohort arriving at [key] must not fade in
/// again, because copies of it are already on screen.
///
/// Only overlapping cohorts count: a retained tile elsewhere on screen
/// says nothing about what is visible here.
Set<Object> coveringLabelKeys(TileKey key, Iterable<RetainedCohort> retained) =>
    labelContinuityKeys([
      for (final cohort in retained)
        if (cohort.symbols.isNotEmpty && tilesOverlap(cohort.key, key))
          cohort.symbols,
    ]);

/// Splits [symbols] into the ones [covering] is already showing and the
/// rest, as one list with the carried-over ones first and the length of
/// that prefix.
///
/// The caller fades in only the suffix, so a label that survives a zoom
/// level change holds full opacity while its copy on the outgoing level
/// is still drawn — the two are then pixel-identical, and it stops
/// mattering which one the collision index happens to pick.
///
/// Always allocates a new list: the caller may be publishing a list the
/// result cache owns, and sorting that in place would reorder the cache
/// entry itself.
({List<SymbolInstance> symbols, int carriedCount}) partitionCarriedOver(
  List<SymbolInstance> symbols,
  Set<Object> covering,
) {
  if (covering.isEmpty || symbols.isEmpty) {
    return (symbols: symbols, carriedCount: 0);
  }
  final carried = <SymbolInstance>[];
  final fresh = <SymbolInstance>[];
  for (final symbol in symbols) {
    if (covering.contains(labelContinuityKey(symbol))) {
      carried.add(symbol);
    } else {
      fresh.add(symbol);
    }
  }
  if (fresh.isEmpty) return (symbols: symbols, carriedCount: symbols.length);
  if (carried.isEmpty) return (symbols: symbols, carriedCount: 0);
  // Read the prefix length before the cascade: record fields evaluate
  // left to right, so `carriedCount: carried.length` after an inline
  // `carried..addAll(fresh)` would report the combined length.
  final carriedCount = carried.length;
  return (symbols: carried..addAll(fresh), carriedCount: carriedCount);
}
