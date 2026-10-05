import 'package:flutter_map_vector_tiles/src/render/label_painter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('drawn text snaps to whole device pixels, never larger', () {
    for (final dpr in [1.0, 2.0, 2.625, 3.0]) {
      for (var size = 8.0; size <= 24; size += 0.05) {
        final exact = size / 16;
        final drawn = LabelPainter.debugSnapTextScale(exact, dpr);
        final devicePx = drawn * 16 * dpr;
        expect(devicePx, closeTo(devicePx.roundToDouble(), 1e-6),
            reason: 'size=$size dpr=$dpr lands on a whole pixel');
        // Collision placed the text at the exact scale.
        expect(drawn, lessThanOrEqualTo(exact + 1e-9),
            reason: 'size=$size dpr=$dpr is never drawn larger');
        expect(exact * 16 * dpr - devicePx, lessThan(1 + 1e-6));
      }
    }
  });

  test('a size already on the grid keeps it', () {
    expect(LabelPainter.debugSnapTextScale(17 / 16, 1), 17 / 16);
    expect(LabelPainter.debugSnapTextScale(42 / 48, 3), 42 / 48);
    expect(LabelPainter.debugSnapTextScale(1, 2.625), 1);
  });
}
