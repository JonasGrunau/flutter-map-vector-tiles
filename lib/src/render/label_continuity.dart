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
/// new label appear instantly instead of fading in, or lets a departing
/// duplicate skip its fade-out because the same text survives elsewhere
/// on the arriving level. So the key errs loose on purpose.
///
/// A record, not an `Object.hash` value: set membership must compare the
/// actual triple, or a hash collision between unrelated labels would
/// silently conflate them.
Object labelContinuityKey(SymbolInstance symbol) =>
    (symbol.layerIndex, symbol.text, symbol.iconName);

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

/// The subset of [symbols] that was actually on screen, per [drawn] —
/// the identity set of the symbols the last label pass drew.
///
/// A cohort is pinned to this subset the moment its level is replaced:
/// an outgoing level exists to *keep* what was visible until the new
/// level covers it, never to introduce labels. Its losing candidates
/// would otherwise pop in mid-transition the instant a zoom-range cut
/// removes whatever was suppressing them — street names flashing up at
/// full opacity just before a level with sparser labelling arrives,
/// only to be faded straight back out by the hand-over.
///
/// The hand-over applies the same filter again at fade-out time: a
/// symbol drawn when its level was replaced may stop being drawn later
/// (losing its spot to an arriving label), and must not be revived just
/// to fade. Returns [symbols] itself when nothing is filtered out.
List<SymbolInstance> drawnLabels(
  List<SymbolInstance> symbols,
  Set<SymbolInstance> drawn,
) {
  if (symbols.isEmpty) return symbols;
  if (drawn.isEmpty) return const [];
  final result = [
    for (final symbol in symbols)
      if (drawn.contains(symbol)) symbol,
  ];
  return result.length == symbols.length ? symbols : result;
}

/// The labels of an outgoing cohort that the arriving level has no
/// counterpart for — the ones about to disappear.
///
/// Some are features the tileset simply stops carrying at the next zoom;
/// others lost their place to the new level's denser labelling. Either
/// way nothing will draw them once the outgoing level is dropped, so
/// they are what a fade-out has to cover. [arriving] is the key set of
/// the cohorts replacing this one.
List<SymbolInstance> orphanedLabels(
  List<SymbolInstance> symbols,
  Set<Object> arriving,
) =>
    [
      for (final symbol in symbols)
        if (!arriving.contains(labelContinuityKey(symbol))) symbol,
    ];

/// Splits [symbols] into the ones [covering] is already showing and the
/// rest, as one list with the carried-over ones first and the length of
/// that prefix.
///
/// The caller fades in only the suffix, so a label that survives a zoom
/// level change holds full opacity while its copy on the outgoing level
/// is still drawn — the two are then pixel-identical, and it stops
/// mattering which one the collision index happens to pick.
///
/// Never reorders [symbols] in place — the caller may be publishing a
/// list the result cache owns, and mutating that would reorder the cache
/// entry itself. When carried and fresh labels must be separated the
/// result is a freshly allocated list; when the split is trivial (all
/// carried, all fresh, or nothing to split) the input list is returned
/// as-is, untouched. Treat the returned list as unowned either way.
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
