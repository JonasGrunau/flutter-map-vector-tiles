import 'package:flutter_map_vector_tiles/src/render/fade.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final start = DateTime.utc(2026, 8, 11);

  group('fadeProgressOf', () {
    test('runs from 0 to 1 across the duration', () {
      const total = Duration(milliseconds: 150);
      expect(fadeProgressOf(start, start, total), 0);
      expect(
          fadeProgressOf(
              start, start.add(const Duration(milliseconds: 75)), total),
          closeTo(0.5, 1e-9));
      expect(
          fadeProgressOf(
              start, start.add(const Duration(milliseconds: 150)), total),
          1);
    });

    test('clamps past the end and treats no start as finished', () {
      const total = Duration(milliseconds: 150);
      expect(
          fadeProgressOf(start, start.add(const Duration(seconds: 5)), total),
          1);
      expect(fadeProgressOf(null, start, total), 1);
      expect(fadeProgressOf(start, start, Duration.zero), 1);
    });

    test('a sub-millisecond duration stays a finite fraction', () {
      // Regression: whole-millisecond arithmetic made this 0 / 0. The
      // NaN passed `clamp` unchanged — every comparison against NaN is
      // false — and then threw in the caller that rounds progress up to
      // a fade step, taking down the frame.
      const total = Duration(microseconds: 500);
      final atStart = fadeProgressOf(start, start, total);
      expect(atStart.isNaN, isFalse);
      expect(atStart, 0);
      expect(
          fadeProgressOf(
              start, start.add(const Duration(microseconds: 250)), total),
          closeTo(0.5, 1e-9));
      expect(
          fadeProgressOf(
              start, start.add(const Duration(microseconds: 500)), total),
          1);
    });

    test('a fade painted immediately has already left zero', () {
      // The first paint lands microseconds after the content is
      // published; truncating to milliseconds reported exactly 0, so a
      // fresh cohort drew its first frame fully transparent.
      expect(
        fadeProgressOf(start, start.add(const Duration(microseconds: 200)),
            const Duration(milliseconds: 150)),
        greaterThan(0),
      );
    });
  });
}
