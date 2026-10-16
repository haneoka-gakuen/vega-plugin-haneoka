import 'dart:typed_data';

/// Resolved source hierarchy binding. An absent transform remains unbound.
final class NativeCubismClipBinding {
  const NativeCubismClipBinding.parameter(this.parameter) : field = null;
  const NativeCubismClipBinding.field(this.field) : parameter = null;
  const NativeCubismClipBinding.unbound() : parameter = null, field = null;
  final String? parameter, field;
}

/// An actual Unity streamed clip, kept separate from projected motion3 data.
final class NativeCubismUnityClip {
  NativeCubismUnityClip(Map record, List<NativeCubismClipBinding> bindings)
    : name = record['m_Name'] as String {
    final muscle = record['m_MuscleClip'] as Map;
    duration = _number(muscle['m_StopTime']);
    loop = muscle['m_LoopTime'] == true;
    if (_number(muscle['m_StartTime']) != 0 ||
        _number(muscle['m_CycleOffset']) != 0 ||
        duration < 0) {
      throw FormatException('native_cubism_clip_origin:$name');
    }
    final data = ((muscle['m_Clip'] as Map)['data'] as Map);
    final dense = data['m_DenseClip'] as Map;
    if (dense['m_CurveCount'] != 0) {
      throw UnsupportedError('native_cubism_dense_clip:$name');
    }
    final stream = data['m_StreamedClip'] as Map;
    final count = stream['curveCount'] as int;
    if ((stream['discreteCurveCount'] as int? ?? 0) != 0) {
      throw UnsupportedError('native_cubism_discrete_clip:$name');
    }
    final constants = (data['m_ConstantClip'] as Map)['data'] as List;
    if (count < 0 || bindings.length != count + constants.length) {
      throw FormatException('native_cubism_clip_bindings:$name');
    }
    _bindings = List<NativeCubismClipBinding>.unmodifiable(bindings);
    _constants = List<double>.unmodifiable(constants.map(_number));
    final words = stream['data'] as List;
    final packed = ByteData(words.length * 4);
    for (var index = 0; index < words.length; index++) {
      final word = words[index];
      if (word is! int || word < 0 || word > 0xffffffff) {
        throw FormatException('native_cubism_clip_word:$name');
      }
      packed.setUint32(index * 4, word, Endian.little);
    }
    final tracks = List.generate(count, (_) => <_CubicKey>[]);
    var offset = 0;
    double previousTime = double.negativeInfinity;
    while (offset < packed.lengthInBytes) {
      if (offset + 8 > packed.lengthInBytes) {
        throw FormatException('native_cubism_clip_frame_size:$name');
      }
      final time = packed.getFloat32(offset, Endian.little);
      final keyCount = packed.getUint32(offset + 4, Endian.little);
      offset += 8;
      // Unity closes a streamed clip with +Infinity and no keys.
      if (time == double.infinity &&
          keyCount == 0 &&
          offset == packed.lengthInBytes) {
        break;
      }
      if (!time.isFinite ||
          time < previousTime ||
          keyCount > count ||
          offset + keyCount * 20 > packed.lengthInBytes) {
        throw FormatException('native_cubism_clip_frame:$name');
      }
      previousTime = time;
      final seen = <int>{};
      for (var key = 0; key < keyCount; key++) {
        final curve = packed.getUint32(offset, Endian.little);
        if (curve >= count || !seen.add(curve)) {
          throw FormatException('native_cubism_clip_curve:$name:$curve');
        }
        final coefficients = List.generate(
          4,
          (index) => packed.getFloat32(offset + 4 + index * 4, Endian.little),
        );
        if (coefficients.any((value) => !value.isFinite)) {
          throw FormatException('native_cubism_clip_coefficient:$name');
        }
        tracks[curve].add(_CubicKey(time, coefficients));
        offset += 20;
      }
    }
    if (tracks.any((track) => track.isEmpty)) {
      throw FormatException('native_cubism_clip_empty_curve:$name');
    }
    _tracks = List<List<_CubicKey>>.unmodifiable([
      for (final track in tracks) List<_CubicKey>.unmodifiable(track),
    ]);
    final events = (record['m_Events'] as List).cast<Map>();
    final ids = events.where((event) => event['functionName'] == 'InstanceId');
    instanceId = ids.isEmpty ? -1 : ids.last['intParameter'] as int;
  }
  final String name;
  late final double duration;
  late final bool loop;
  late final int instanceId;
  late final List<NativeCubismClipBinding> _bindings;
  late final List<double> _constants;
  late final List<List<_CubicKey>> _tracks;
  final _single = Float32List(1);
  double _f(double value) {
    _single[0] = value;
    return _single[0];
  }

  void sampleInto(
    double elapsed,
    Map<String, double> parameters,
    Map<String, double> fields,
  ) {
    if (!elapsed.isFinite || elapsed < 0) {
      throw ArgumentError('native_cubism_clip_time');
    }
    final time = _f(
      loop && duration > 0 && elapsed > duration
          ? elapsed % duration
          : elapsed.clamp(0.0, duration),
    );
    void write(int index, double value) {
      final binding = _bindings[index];
      if (binding.parameter != null) parameters[binding.parameter!] = value;
      if (binding.field != null) fields[binding.field!] = value;
    }

    for (var index = 0; index < _tracks.length; index++) {
      final track = _tracks[index];
      var low = 0, high = track.length - 1;
      while (low < high) {
        final middle = (low + high + 1) ~/ 2;
        if (track[middle].time <= time) {
          low = middle;
        } else {
          high = middle - 1;
        }
      }
      final key = track[low], x = _f(time - key.time), c = key.coefficients;
      var value = _f(c[0] * x);
      value = _f(_f(value + c[1]) * x);
      value = _f(_f(value + c[2]) * x);
      write(index, _f(value + c[3]));
    }
    for (var index = 0; index < _constants.length; index++) {
      write(_tracks.length + index, _f(_constants[index]));
    }
  }
}

final class _CubicKey {
  _CubicKey(this.time, this.coefficients);
  final double time;
  final List<double> coefficients;
}

double _number(Object? value) {
  if (value is! num || !value.isFinite) {
    throw const FormatException('native_cubism_clip_number');
  }
  return value.toDouble();
}
