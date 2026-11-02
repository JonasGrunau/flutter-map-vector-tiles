/// Label ids for hand-built `PlacedSymbol`s, standing in for the
/// `LabelIdentityIndex` a real layer runs: one stable id per distinct
/// [label] value, so two candidates built from the same value are copies
/// of one label (a republish, a seam twin, the other level's copy) and
/// different values are different labels. Use the label's text when a
/// test has one label per text, or a record of whatever tells its labels
/// apart.
int labelIdOf(Object label) => _ids.putIfAbsent(label, () => _ids.length + 1);

final _ids = <Object, int>{};
