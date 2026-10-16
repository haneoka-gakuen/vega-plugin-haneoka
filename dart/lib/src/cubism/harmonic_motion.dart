import 'dart:math' as math;
import 'dart:typed_data';

final _single = Float32List(1);
double _f32(double value) {
  _single[0] = value;
  return _single[0];
}

double advanceUnityHarmonicTime(
  double elapsed,
  double delta,
  double timescale,
  double duration,
) {
  var next = _f32(elapsed + _f32(delta * timescale));
  while (next > duration) {
    next = _f32(next - duration);
  }
  return next;
}

/// CubismHarmonicMotionParameter.Evaluate/Clamp, preserving the native single
/// operations and the controller's persistent NormalizedRange adjustment.
({double value, double normalizedRange}) evaluateUnityHarmonic({
  required double minimum,
  required double maximum,
  required double normalizedOrigin,
  required double normalizedRange,
  required int direction,
  required double elapsed,
  required double duration,
}) {
  final range = _f32(maximum - minimum);
  var origin = _f32(minimum + _f32(normalizedOrigin * range));
  var amplitude = _f32(normalizedRange * range);
  var nextRange = normalizedRange;
  if (direction == 0) {
    if (_f32(origin - amplitude) < minimum) {
      amplitude = _f32(_f32(origin - minimum) * .5);
      origin = _f32(minimum + amplitude);
      nextRange = _f32(_f32(amplitude + amplitude) / range);
    } else {
      amplitude = _f32(amplitude * .5);
      origin = _f32(origin - amplitude);
    }
  } else if (direction == 1) {
    if (_f32(origin + amplitude) > maximum) {
      amplitude = _f32(_f32(maximum - origin) * .5);
      origin = _f32(maximum - amplitude);
      nextRange = _f32(_f32(amplitude + amplitude) / range);
    } else {
      amplitude = _f32(amplitude * .5);
      origin = _f32(origin + amplitude);
    }
  }
  if (_f32(origin - amplitude) < minimum) {
    amplitude = _f32(origin - minimum);
    nextRange = _f32(amplitude / range);
  } else if (_f32(origin + amplitude) > maximum) {
    amplitude = _f32(maximum - origin);
    nextRange = _f32(amplitude / range);
  }
  final phase = _f32(_f32(elapsed * _f32(2 * math.pi)) / duration);
  return (
    value: _f32(origin + _f32(amplitude * _f32(math.sin(phase)))),
    normalizedRange: nextRange,
  );
}
