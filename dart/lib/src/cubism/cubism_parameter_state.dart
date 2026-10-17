import 'dart:ffi';
import 'dart:typed_data';

import 'cubism_math.dart';
import 'native_cubism_core.dart';

export 'cubism_math.dart';
export 'cubism_fade_curve.dart';

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
