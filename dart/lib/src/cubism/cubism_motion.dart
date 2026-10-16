import 'dart:math' as math;

/// A source-projected Cubism motion3 curve. Unity Animator packets use their
/// separate streamed-clip evaluator; they do not pass through this decoder.
final class NativeCubismMotion {
  NativeCubismMotion(Map document)
    : duration = _number((document['Meta'] as Map)['Duration']),
      loop = (document['Meta'] as Map)['Loop'] == true,
      curves = List.unmodifiable([
        for (final curve in (document['Curves'] as List).cast<Map>())
          NativeCubismMotionCurve(curve),
      ]) {
    if (document['Version'] != 3 || duration < 0) {
      throw const FormatException('native_cubism_motion3');
    }
  }
  final double duration;
  final bool loop;
  final List<NativeCubismMotionCurve> curves;

  double localTime(double elapsed, {bool? looping}) {
    if (!elapsed.isFinite || elapsed < 0) {
      throw ArgumentError('native_cubism_motion_time');
    }
    if ((looping ?? loop) && duration > 0 && elapsed > duration) {
      return elapsed % duration;
    }
    return math.min(elapsed, duration);
  }
}

final class NativeCubismMotionCurve {
  NativeCubismMotionCurve(Map record)
    : id = record['Id'] as String,
      target = record['Target'] as String,
      fadeIn = record['FadeInTime'] is num
          ? _number(record['FadeInTime'])
          : null,
      fadeOut = record['FadeOutTime'] is num
          ? _number(record['FadeOutTime'])
          : null {
    if (!const {'Parameter', 'PartOpacity', 'Model'}.contains(target) ||
        id.isEmpty) {
      throw FormatException('native_cubism_motion_target:$target:$id');
    }
    final encoded = (record['Segments'] as List).map(_number).toList();
    if (encoded.length < 2) {
      throw const FormatException('native_cubism_motion_segments');
    }
    firstTime = encoded[0];
    firstValue = encoded[1];
    var fromTime = firstTime, fromValue = firstValue, cursor = 2;
    final decoded = <_Segment>[];
    while (cursor < encoded.length) {
      final typeNumber = encoded[cursor++];
      final type = typeNumber.toInt();
      if (type != typeNumber || type < 0 || type > 3) {
        throw FormatException('native_cubism_motion_segment:$typeNumber');
      }
      final width = type == 1 ? 6 : 2;
      if (cursor + width > encoded.length) {
        throw const FormatException('native_cubism_motion_segment_size');
      }
      final values = encoded.sublist(cursor, cursor + width);
      final endTime = values[width - 2], endValue = values[width - 1];
      if (endTime < fromTime) {
        throw const FormatException('native_cubism_motion_segment_order');
      }
      if (type == 1 &&
          !(fromTime <= values[0] &&
              values[0] <= values[2] &&
              values[2] <= endTime)) {
        throw const FormatException('native_cubism_motion_bezier_time');
      }
      decoded.add(_Segment(type, fromTime, fromValue, values));
      fromTime = endTime;
      fromValue = endValue;
      cursor += width;
    }
    _segments = List.unmodifiable(decoded);
  }
  final String id, target;
  final double? fadeIn, fadeOut;
  late final double firstTime, firstValue;
  late final List<_Segment> _segments;

  double sample(double time) {
    if (!time.isFinite) throw ArgumentError('native_cubism_curve_time');
    if (time <= firstTime || _segments.isEmpty) return firstValue;
    var low = 0, high = _segments.length - 1;
    while (low < high) {
      final middle = (low + high) ~/ 2;
      if (time <= _segments[middle].endTime) {
        high = middle;
      } else {
        low = middle + 1;
      }
    }
    return _segments[low].sample(time);
  }
}

final class _Segment {
  _Segment(this.type, this.fromTime, this.fromValue, this.values);
  final int type;
  final double fromTime, fromValue;
  final List<double> values;
  double get endTime => values[values.length - 2];
  double get endValue => values.last;
  double sample(double time) {
    if (time >= endTime) return endValue;
    if (type == 2) return fromValue;
    if (type == 3) return endValue;
    final span = endTime - fromTime;
    if (span <= 0) return endValue;
    if (type == 0) {
      return fromValue + (endValue - fromValue) * (time - fromTime) / span;
    }
    // Solve the source cubic's time coordinate, then evaluate its value.
    var lower = 0.0, upper = 1.0;
    for (var iteration = 0; iteration < 40; iteration++) {
      final t = (lower + upper) * .5;
      if (_cubic(fromTime, values[0], values[2], endTime, t) < time) {
        lower = t;
      } else {
        upper = t;
      }
    }
    return _cubic(
      fromValue,
      values[1],
      values[3],
      endValue,
      (lower + upper) * .5,
    );
  }
}

double _number(Object? value) {
  if (value is! num || !value.isFinite) {
    throw const FormatException('native_cubism_motion_number');
  }
  return value.toDouble();
}

double _cubic(double a, double b, double c, double d, double t) {
  final s = 1 - t;
  return s * s * s * a + 3 * s * s * t * b + 3 * s * t * t * c + t * t * t * d;
}
