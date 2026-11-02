// Prints the text the script suite draws, for `build.sh`: every sample
// on a line of its own, then a last line of extras — printable ASCII
// for digits and punctuation, and the invisible controls and dotted
// circle shaping can ask for.
//
//   dart run test/scripts/fonts/charset.dart
import '../script_samples.dart';

void main() {
  final extras = <int>[
    for (var c = 0x20; c < 0x7f; c++) c,
    // Joiners, direction marks, isolates, the emoji presentation
    // selector, and the dotted circle a shaper puts under a mark with
    // nothing to sit on.
    0x200c, 0x200d, 0x200e, 0x200f, 0x2066, 0x2067, 0x2068, 0x2069, //
    0xfe0f, 0x25cc,
  ];
  // ignore: avoid_print
  print([...allSampleText, String.fromCharCodes(extras)].join('\n'));
}
