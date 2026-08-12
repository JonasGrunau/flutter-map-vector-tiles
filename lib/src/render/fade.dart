/// Steps of the opacity grid all label fade opacities are quantized
/// onto. Fading labels draw through one `saveLayer` bucket per distinct
/// opacity, so the grid is coarse on purpose. The widget's fade-progress
/// quantization and the label painter's ramp/compound quantization must
/// share this value: if they disagreed, the painter's re-rounding would
/// silently move opacities off the caller's grid and multiply buckets.
const int labelOpacitySteps = 8;

/// Elapsed fraction of a fade that began at [start], in the range
/// `[0, 1]`. A null [start] (nothing is fading) or a non-positive
/// [total] means "finished": 1.
///
/// Measured in microseconds, which is not a precision nicety. Whole
/// milliseconds truncate to zero at both ends: a duration under 1ms —
/// accepted, since it is greater than zero — makes the divisor 0, and a
/// frame painted in the same millisecond the fade started makes the
/// dividend 0. `0 / 0` is NaN, which survives `clamp` (its comparisons
/// are all false) and throws in the callers that round it to a step.
/// Even at a normal duration the dividend matters: the first paint after
/// content is published lands microseconds later, so it would round down
/// to a progress of exactly 0 and draw that frame fully transparent.
double fadeProgressOf(DateTime? start, DateTime now, Duration total) {
  final span = total.inMicroseconds;
  if (start == null || span <= 0) return 1;
  return (now.difference(start).inMicroseconds / span).clamp(0.0, 1.0);
}
