import 'cubism_math.dart';

/// Source AnimationCurve Hermite interpolation with float32 operation bounds.
final class NativeCubismFadeCurve {
  NativeCubismFadeCurve(Map record)
    : keys = List.unmodifiable((record['m_Curve'] as List).cast<Map>()) {
    if (keys.isEmpty ||
        record['m_PreInfinity'] != 2 ||
        record['m_PostInfinity'] != 2) {
      throw const FormatException('native_cubism_fade_curve');
    }
    var previous = double.negativeInfinity;
    for (final key in keys) {
      final time = (key['time'] as num).toDouble();
      if (!time.isFinite || time < previous || key['weightedMode'] != 0) {
        throw const FormatException('native_cubism_fade_key');
      }
      previous = time;
    }
  }
  final List<Map> keys;
  double sample(double time) {
    if (time <= (keys.first['time'] as num)) {
      return (keys.first['value'] as num).toDouble();
    }
    if (time >= (keys.last['time'] as num)) {
      return (keys.last['value'] as num).toDouble();
    }
    var left = 0, right = keys.length - 1;
    while (right - left > 1) {
      final mid = (left + right) ~/ 2;
      if ((keys[mid]['time'] as num) <= time) {
        left = mid;
      } else {
        right = mid;
      }
    }
    final a = keys[left], b = keys[right];
    final outgoing = (a['outSlope'] as num).toDouble(),
        incoming = (b['inSlope'] as num).toDouble();
    final av = (a['value'] as num).toDouble(),
        bv = (b['value'] as num).toDouble();
    if (!outgoing.isFinite || !incoming.isFinite) return av;
    final width = cubismF32(
      (b['time'] as num).toDouble() - (a['time'] as num).toDouble(),
    );
    final t = cubismF32(
      cubismF32(time - (a['time'] as num).toDouble()) / width,
    );
    final t2 = cubismF32(t * t), t3 = cubismF32(t2 * t);
    final aWeight = cubismF32(
      cubismF32(cubismF32(2 * t3) - cubismF32(3 * t2)) + 1,
    );
    final aTangent = cubismF32(cubismF32(t3 - cubismF32(2 * t2)) + t);
    final bWeight = cubismF32(cubismF32(-2 * t3) + cubismF32(3 * t2));
    final bTangent = cubismF32(t3 - t2);
    var result = cubismF32(aWeight * av);
    result = cubismF32(
      result + cubismF32(aTangent * cubismF32(outgoing * width)),
    );
    result = cubismF32(
      result + cubismF32(bTangent * cubismF32(incoming * width)),
    );
    return cubismF32(result + cubismF32(bWeight * bv));
  }
}
