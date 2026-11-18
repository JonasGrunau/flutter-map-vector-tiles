// The line formats `summarize.py` and the plan tools parse: a change here
// breaks every comparison against an older run's log.
library;

import 'package:flutter_map_vector_tiles_bench/report.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('frameStats: percentiles in ms and the frames over each budget', () {
    expect(
        frameStats('BUILD ', [20000, 1000, 9000, 2000]),
        'BUILD  n=4 p50=9.00 p90=20.00 p99=20.00 max=20.00 '
        '>8.3=2 (50.0%) >16.7=1 (25.0%)');
    expect(frameStats('RASTER', []), 'RASTER: no frames');
  });

  test('distribution: thousandths shown as units', () {
    expect(distribution([3000, 1000, 2000]),
        'n=3 p50=2.00 p90=3.00 p99=3.00 max=3.00');
    expect(distribution([]), 'n=0');
  });

  test('ms: one decimal', () {
    expect(ms(1260), '1.3');
    expect(ms(0), '0.0');
  });
}
