import 'dart:ffi';
import 'dart:math' as math;
import 'dart:typed_data';

import 'native_cubism_core.dart';

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

/// Managed source parameter values remain separate from the Core's evaluated
/// deformation state, including the LateUpdate save/restore boundary.
final class NativeCubismParameterState {
  NativeCubismParameterState(this.model) {
    final count = model.parameters.length,
        core = model.core,
        pointer = model.pointer;
    indices = Map.unmodifiable(model.parameters);
    minimum = Float32List.fromList(
      core.parameterMinimum(pointer).asTypedList(count),
    );
    maximum = Float32List.fromList(
      core.parameterMaximum(pointer).asTypedList(count),
    );
    defaults = Float32List.fromList(
      core.parameterDefaults(pointer).asTypedList(count),
    );
    values = Float32List.fromList(
      core.parameterValues(pointer).asTypedList(count),
    );
    parts = Float32List.fromList(
      core.partOpacities(pointer).asTypedList(model.parts.length),
    );
    saved = Float32List.fromList(values);
    savedParts = Float32List.fromList(parts);
  }
  final NativeCubismModel model;
  late final Map<String, int> indices;
  late final Float32List minimum,
      maximum,
      defaults,
      values,
      saved,
      parts,
      savedParts;
  int require(String id) =>
      indices[id] ?? (throw StateError('native_cubism_parameter:$id'));
  void overwrite(int index, double value, [double weight = 1]) {
    final rounded = cubismF32(value);
    final clamped = rounded.isNaN
        ? minimum[index]
        : rounded.clamp(minimum[index], maximum[index]);
    values[index] = cubismF32(
      cubismF32(clamped * weight) +
          cubismF32(cubismF32(1 - weight) * values[index]),
    );
  }

  void add(int index, double value, [double weight = 1]) =>
      overwrite(index, cubismF32(cubismF32(value * weight) + values[index]));
  void multiply(int index, double value, [double weight = 1]) => overwrite(
    index,
    cubismF32(
      cubismF32(cubismF32(cubismF32(value - 1) * weight) + 1) * values[index],
    ),
  );
  void save() {
    saved.setAll(0, values);
    savedParts.setAll(0, parts);
  }

  void restore() {
    for (var index = 0; index < values.length; index++) {
      overwrite(index, saved[index]);
    }
    parts.setAll(0, savedParts);
  }

  void writeCore() {
    model.core
        .parameterValues(model.pointer)
        .asTypedList(values.length)
        .setAll(0, values);
    model.core
        .partOpacities(model.pointer)
        .asTypedList(parts.length)
        .setAll(0, parts);
  }
}

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
