@TestOn('vm')
library;

import 'package:flutter/painting.dart';
import 'package:flutter_map_vector_tiles/src/render/label_painter.dart';
import 'package:flutter_test/flutter_test.dart';

import 'script_harness.dart';
import 'script_samples.dart';
import 'tolerant_golden_comparator.dart'
    if (dart.library.js_interop) 'tolerant_golden_comparator_web.dart';

/// How every script looks today, pinned as goldens: per script its
/// name with a halo, the same name on a curved line, and a longer label
/// wrapped at `text-max-width` — plus mixed-direction labels, emoji and
/// combining marks. `script_rendering_test.dart` says what must hold of
/// these drawings; the goldens catch any change at all, within what two
/// rasterizers differ by (see `TolerantGoldenComparator`).
///
/// VM only: the web renderers draw text differently. After a deliberate
/// change, regenerate them (on macOS, where they were made) with
///
///   flutter test --update-goldens test/scripts/script_goldens_test.dart
///
/// and look at every image that changed before committing it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await loadScriptFonts();
    useTolerantGoldens('script_goldens_test.dart');
  });

  const background = Color(0xffc8c8c8);
  const size = Size(420, 220);
  const halo = <String, Object?>{
    'text-color': '#202020',
    'text-halo-color': '#ffffff',
    'text-halo-width': 1.5,
  };

  Future<void> expectGolden(String name, List<PlacedSymbol> labels) async {
    final (image, placed) =
        await paintLabels(labels, size: size, background: background);
    expect(placed, labels.length, reason: 'every label is placed');
    await expectLater(image, matchesGoldenFile('goldens/$name.png'));
    image.dispose();
  }

  for (final sample in scriptSamples) {
    test(sample.script, () async {
      final arc = await arcFor(sample.name, apex: const Offset(110, 120));
      await expectGolden(sample.script.toLowerCase().replaceAll(' ', '_'), [
        label(sample.name, paint: halo, at: const Offset(110, 40)),
        label(sample.name, paint: halo, path: arc, layerIndex: 1),
        label(sample.wrapped,
            layout: {'text-max-width': 5},
            paint: halo,
            at: const Offset(315, 110),
            layerIndex: 2),
      ]);
    });
  }

  test('mixed directions', () async {
    await expectGolden('mixed_directions', [
      for (final (i, text) in [
        mixedRtlDigits,
        hebrewDigits,
        mixedRtlFirst,
        mixedLtrFirst,
      ].indexed)
        label(text, paint: halo, at: Offset(110, 30 + 50.0 * i), layerIndex: i),
      label('Cairo\n$mixedRtlFirst',
          paint: halo, at: const Offset(315, 50), layerIndex: 4),
      label('شارع الملك Fahd الرياض',
          layout: {'text-max-width': 6},
          paint: halo,
          at: const Offset(315, 150),
          layerIndex: 5),
    ]);
  });

  test('emoji and combining marks', () async {
    await expectGolden('emoji_and_marks', [
      for (final (i, text) in [
        emojiFamily,
        emojiFlag,
        emojiThumbsSkinTone,
        emojiInLatin,
      ].indexed)
        label(text, paint: halo, at: Offset(110, 30 + 50.0 * i), layerIndex: i),
      for (final (i, text) in [
        arabicVowelled,
        for (final (_, decomposed) in combiningPairs) decomposed,
      ].indexed)
        label(text,
            paint: halo, at: Offset(315, 30 + 50.0 * i), layerIndex: 4 + i),
    ]);
  });
}
