import 'dart:math' as math;
import 'dart:typed_data';

final _single = Float32List(1);
double cubismF32(double value) {
  _single[0] = value;
  return _single[0];
}

double cubismFadeEase(double fraction) {
  if (fraction <= 0) return 0;
  if (fraction >= 1) return 1;
  return cubismF32(
    .5 - .5 * math.cos(cubismF32(fraction * cubismF32(math.pi))),
  );
}
