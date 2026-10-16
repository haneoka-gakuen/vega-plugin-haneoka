import 'dart:math' as math;
import 'dart:typed_data';

import 'cubism_parameter_state.dart';

/// Fixed-step particle _chains from the original CubismPhysicsRig component.
/// The Story owner supplies accepted game delta; this solver owns no timer.
final class NativeCubismUnityPhysics {
  NativeCubismUnityPhysics(Map rig, this.parameters)
    : fps = (rig['Fps'] as num).toDouble(),
      _gravity = _point(rig['Gravity'] as Map),
      _wind = _point(rig['Wind'] as Map) {
    if (!fps.isFinite || fps < 0) throw const FormatException('cubism_rig_fps');
    _chains = [
      for (final source in (rig['SubRigs'] as List).cast<Map>())
        _Chain(source, parameters, _gravity),
    ];
    filtered = Float32List(parameters.values.length);
    incoming = Float32List(parameters.values.length);
  }
  final NativeCubismParameterState parameters;
  final double fps;
  final _Point _gravity, _wind;
  late final List<_Chain> _chains;
  late final Float32List filtered, incoming;
  double remainder = 0;

  Map<String, Object?> snapshotData() => {
    'version': 1,
    'fps': fps,
    'remainder': remainder,
    'filtered': filtered.toList(),
    'incoming': incoming.toList(),
    'chains': [
      for (final chain in _chains)
        {
          'previousOutputs': chain.previousOutputs.toList(),
          'currentOutputs': chain.currentOutputs.toList(),
          'points': [
            for (final point in chain.points)
              [
                point.position.x,
                point.position.y,
                point.previous.x,
                point.previous.y,
                point.velocity.x,
                point.velocity.y,
                point.previousGravity.x,
                point.previousGravity.y,
              ],
          ],
        },
    ],
  };

  void restoreData(Map data) {
    final chains = data['chains'] as List;
    if (data['version'] != 1 ||
        data['fps'] != fps ||
        chains.length != _chains.length) {
      throw const FormatException('cubism_physics_data_source');
    }
    Float32List array(Object? value, int length) {
      final values = value as List;
      if (values.length != length)
        throw const FormatException('cubism_physics_data_array');
      return Float32List.fromList([
        for (final value in values) (value as num).toDouble(),
      ]);
    }

    filtered.setAll(0, array(data['filtered'], filtered.length));
    incoming.setAll(0, array(data['incoming'], incoming.length));
    remainder = (data['remainder'] as num).toDouble();
    for (var i = 0; i < chains.length; i++) {
      final saved = chains[i] as Map, chain = _chains[i];
      chain.previousOutputs.setAll(
        0,
        array(saved['previousOutputs'], chain.previousOutputs.length),
      );
      chain.currentOutputs.setAll(
        0,
        array(saved['currentOutputs'], chain.currentOutputs.length),
      );
      final points = saved['points'] as List;
      if (points.length != chain.points.length)
        throw const FormatException('cubism_physics_data_points');
      for (var j = 0; j < points.length; j++) {
        final values = array(points[j], 8), point = chain.points[j];
        point.position.set(values[0], values[1]);
        point.previous.set(values[2], values[3]);
        point.velocity.set(values[4], values[5]);
        point.previousGravity.set(values[6], values[7]);
      }
    }
  }

  NativeCubismPhysicsSnapshot snapshot() {
    final savedRemainder = remainder;
    final savedFiltered = Float32List.fromList(filtered);
    final savedIncoming = Float32List.fromList(incoming);
    final outputs = [
      for (final chain in _chains)
        (
          Float32List.fromList(chain.previousOutputs),
          Float32List.fromList(chain.currentOutputs),
        ),
    ];
    final points = [
      for (final chain in _chains)
        [
          for (final point in chain.points)
            [
              point.position.x,
              point.position.y,
              point.previous.x,
              point.previous.y,
              point.velocity.x,
              point.velocity.y,
              point.previousGravity.x,
              point.previousGravity.y,
            ],
        ],
    ];
    return NativeCubismPhysicsSnapshot._(this, () {
      remainder = savedRemainder;
      filtered.setAll(0, savedFiltered);
      incoming.setAll(0, savedIncoming);
      for (var i = 0; i < _chains.length; i++) {
        final chain = _chains[i];
        chain.previousOutputs.setAll(0, outputs[i].$1);
        chain.currentOutputs.setAll(0, outputs[i].$2);
        for (var j = 0; j < chain.points.length; j++) {
          final point = chain.points[j], saved = points[i][j];
          point.position.set(saved[0], saved[1]);
          point.previous.set(saved[2], saved[3]);
          point.velocity.set(saved[4], saved[5]);
          point.previousGravity.set(saved[6], saved[7]);
        }
      }
    });
  }

  void restore(NativeCubismPhysicsSnapshot snapshot) {
    if (!identical(snapshot._owner, this)) {
      throw const FormatException('cubism_physics_snapshot_owner');
    }
    snapshot._restore();
  }

  void stabilize() {
    filtered.setAll(0, parameters.values);
    incoming.setAll(0, parameters.values);
    for (final chain in _chains) {
      final (translation, angle) = _input(chain, parameters.values);
      for (final input in chain.inputs) {
        if (input.index != null) {
          filtered[input.index!] = parameters.values[input.index!];
        }
      }
      chain.points.first.position.assign(translation);
      final direction = _directionForAngle(angle);
      for (var i = 1; i < chain.points.length; i++) {
        final point = chain.points[i], parent = chain.points[i - 1];
        point.previous.assign(point.position);
        point.velocity.set(0, 0);
        final force = _Point(
          cubismF32(_wind.x + cubismF32(direction.x * point.acceleration)),
          cubismF32(_wind.y + cubismF32(direction.y * point.acceleration)),
        );
        final unit = force.unit();
        var x = cubismF32(parent.position.x + cubismF32(unit.x * point.radius));
        if (x.abs() < chain.threshold) x = 0;
        point.position.set(
          x,
          cubismF32(parent.position.y + cubismF32(unit.y * point.radius)),
        );
        point.previousGravity.assign(direction);
      }
      for (var i = 0; i < chain.outputs.length; i++) {
        final out = chain.outputs[i];
        if (!_valid(chain, out)) continue;
        final raw = _read(chain, out);
        chain.previousOutputs[i] = raw;
        chain.currentOutputs[i] = raw;
        _write(out, parameters.values, raw);
        filtered[out.index!] = parameters.values[out.index!];
      }
    }
  }

  void advance(double delta) {
    if (!delta.isFinite || delta < 0) throw ArgumentError('cubism_rig_delta');
    if (delta == 0) return;
    final sum = cubismF32(remainder + delta);
    remainder = sum <= 5 ? sum : 0;
    final interval = fps > 0 ? cubismF32(1 / fps) : delta;
    while (remainder >= interval) {
      final weight = cubismF32(interval / remainder);
      for (var i = 0; i < filtered.length; i++) {
        final value = cubismF32(
          cubismF32(cubismF32(1 - weight) * incoming[i]) +
              cubismF32(weight * parameters.values[i]),
        );
        incoming[i] = value;
        filtered[i] = value;
      }
      for (final chain in _chains) {
        final (position, angle) = _input(chain, filtered);
        _integrate(chain, position, angle, interval);
        for (var i = 0; i < chain.outputs.length; i++) {
          chain.previousOutputs[i] = chain.currentOutputs[i];
          final out = chain.outputs[i];
          if (!_valid(chain, out)) continue;
          final raw = _read(chain, out);
          chain.currentOutputs[i] = raw;
          _write(out, filtered, raw);
        }
      }
      remainder = cubismF32(remainder - interval);
    }
    final fraction = cubismF32(remainder / interval);
    for (final chain in _chains) {
      for (var i = 0; i < chain.outputs.length; i++) {
        final out = chain.outputs[i];
        if (!_valid(chain, out)) continue;
        _write(
          out,
          parameters.values,
          cubismF32(
            cubismF32(cubismF32(1 - fraction) * chain.previousOutputs[i]) +
                cubismF32(fraction * chain.currentOutputs[i]),
          ),
        );
      }
    }
  }

  (_Point, double) _input(_Chain chain, Float32List values) {
    var x = 0.0, y = 0.0, angle = 0.0;
    for (final source in chain.inputs) {
      final index = source.index;
      if (index == null) continue;
      final limits = source.component == 2
          ? chain.angleRange
          : chain.positionRange;
      final normalized = _normalize(index, values, limits, source.inverted);
      final contribution = cubismF32(normalized * source.weight);
      switch (source.component) {
        case 0:
          x = cubismF32(x + contribution);
        case 1:
          y = cubismF32(y + contribution);
        case 2:
          angle = cubismF32(angle + contribution);
      }
    }
    final radians = cubismF32(cubismF32(angle / -180) * cubismF32(math.pi));
    final cosine = cubismF32(math.cos(radians)),
        sine = cubismF32(math.sin(radians));
    // The source SDK uses the already-updated x in its y rotation expression.
    x = cubismF32(cubismF32(x * cosine) - cubismF32(y * sine));
    y = cubismF32(cubismF32(y * cosine) + cubismF32(sine * x));
    return (_Point(x, y), angle);
  }

  double _normalize(
    int index,
    Float32List values,
    _Range range,
    bool inverted,
  ) {
    final lo = math.min(parameters.minimum[index], parameters.maximum[index]);
    final hi = math.max(parameters.minimum[index], parameters.maximum[index]);
    final value = values[index].clamp(lo, hi);
    values[index] = value;
    final midpoint = cubismF32(lo + cubismF32(cubismF32(hi - lo) * .5));
    final upper = cubismF32(value - midpoint) >= 0;
    final width = cubismF32((upper ? hi : lo) - midpoint);
    final bound = upper
        ? math.max(range.minimum, range.maximum)
        : math.min(range.minimum, range.maximum);
    final result = width == 0
        ? 0.0
        : cubismF32(
            cubismF32(
                  cubismF32(cubismF32(bound - range.normal) / width) *
                      cubismF32(value - midpoint),
                ) +
                range.normal,
          );
    return inverted ? result : -result;
  }

  void _integrate(
    _Chain chain,
    _Point translation,
    double angle,
    double delta,
  ) {
    chain.points.first.position.assign(translation);
    final direction = _directionForAngle(angle);
    final directionAngle = cubismF32(math.atan2(direction.y, direction.x));
    for (var i = 1; i < chain.points.length; i++) {
      final point = chain.points[i], parent = chain.points[i - 1];
      point.previous.assign(point.position);
      final change = cubismF32(
        _wrapped(
              cubismF32(
                directionAngle -
                    cubismF32(
                      math.atan2(
                        point.previousGravity.y,
                        point.previousGravity.x,
                      ),
                    ),
              ),
            ) /
            5,
      );
      final delay = cubismF32(cubismF32(point.delay * delta) * 30);
      final cosine = cubismF32(math.cos(change)),
          sine = cubismF32(math.sin(change));
      final oldX = cubismF32(point.position.x - parent.position.x);
      final oldY = cubismF32(point.position.y - parent.position.y);
      final dx = cubismF32(cubismF32(oldX * cosine) - cubismF32(oldY * sine));
      final dy = cubismF32(cubismF32(oldY * cosine) + cubismF32(sine * dx));
      final forceX = cubismF32(
        _wind.x + cubismF32(direction.x * point.acceleration),
      );
      final forceY = cubismF32(
        _wind.y + cubismF32(direction.y * point.acceleration),
      );
      final x = cubismF32(
        cubismF32(
              cubismF32(parent.position.x + dx) +
                  cubismF32(point.velocity.x * delay),
            ) +
            cubismF32(cubismF32(forceX * delay) * delay),
      );
      final y = cubismF32(
        cubismF32(
              cubismF32(parent.position.y + dy) +
                  cubismF32(point.velocity.y * delay),
            ) +
            cubismF32(cubismF32(forceY * delay) * delay),
      );
      final unit = _Point(
        cubismF32(x - parent.position.x),
        cubismF32(y - parent.position.y),
      ).unit();
      var boundedX = cubismF32(
        parent.position.x + cubismF32(unit.x * point.radius),
      );
      if (boundedX.abs() < chain.threshold) boundedX = 0;
      point.position.set(
        boundedX,
        cubismF32(parent.position.y + cubismF32(unit.y * point.radius)),
      );
      if (delay != 0) {
        point.velocity.set(
          cubismF32(
            cubismF32(cubismF32(point.position.x - point.previous.x) / delay) *
                point.mobility,
          ),
          cubismF32(
            cubismF32(cubismF32(point.position.y - point.previous.y) / delay) *
                point.mobility,
          ),
        );
      }
      point.previousGravity.assign(direction);
    }
  }

  bool _valid(_Chain chain, _Output out) =>
      out.index != null &&
      out.particle > 0 &&
      out.particle < chain.points.length;
  double _read(_Chain chain, _Output out) {
    final p = chain.points[out.particle].position,
        before = chain.points[out.particle - 1].position;
    final dx = cubismF32(p.x - before.x), dy = cubismF32(p.y - before.y);
    double value;
    if (out.component == 0) {
      value = dx;
    } else if (out.component == 1) {
      value = dy;
    } else {
      final base = out.particle >= 2
          ? _Point(
              cubismF32(before.x - chain.points[out.particle - 2].position.x),
              cubismF32(before.y - chain.points[out.particle - 2].position.y),
            )
          : _Point(_gravity.x, cubismF32(-_gravity.y));
      value = _wrapped(
        cubismF32(
          cubismF32(math.atan2(dy, dx)) - cubismF32(math.atan2(base.y, base.x)),
        ),
      );
    }
    return out.inverted ? -value : value;
  }

  void _write(_Output out, Float32List values, double raw) {
    final index = out.index!;
    final scale = out.component == 2
        ? out.angleScale
        : (out.component == 1 ? out.translation.y : out.translation.x);
    var result = cubismF32(raw * scale)
        .clamp(parameters.minimum[index], parameters.maximum[index]);
    if (out.weight < 1) {
      result = cubismF32(
        cubismF32(result * out.weight) +
            cubismF32(cubismF32(1 - out.weight) * values[index]),
      );
    }
    values[index] = result;
  }
}

final class NativeCubismPhysicsSnapshot {
  NativeCubismPhysicsSnapshot._(this._owner, this._restore);
  final NativeCubismUnityPhysics _owner;
  final void Function() _restore;
}

final class _Range {
  _Range(Map row)
    : minimum = (row['Minimum'] as num).toDouble(),
      maximum = (row['Maximum'] as num).toDouble(),
      normal = (row['Default'] as num).toDouble();
  final double minimum, maximum, normal;
}

final class _Input {
  _Input(Map row, NativeCubismParameterState p)
    : index = p.indices[row['SourceId']],
      component = row['SourceComponent'] as int,
      inverted = row['IsInverted'] == 1,
      weight = cubismF32((row['Weight'] as num).toDouble() / 100);
  final int? index;
  final int component;
  final bool inverted;
  final double weight;
}

final class _Output {
  _Output(Map row, NativeCubismParameterState p)
    : index = p.indices[row['DestinationId']],
      component = row['SourceComponent'] as int,
      particle = row['ParticleIndex'] as int,
      inverted = row['IsInverted'] == 1,
      weight = cubismF32((row['Weight'] as num).toDouble() / 100),
      angleScale = (row['AngleScale'] as num).toDouble(),
      translation = _point(row['TranslationScale'] as Map);
  final int? index;
  final int component, particle;
  final bool inverted;
  final double weight, angleScale;
  final _Point translation;
}

final class _Particle {
  _Particle(Map row, _Point gravity)
    : radius = (row['Radius'] as num).toDouble(),
      mobility = (row['Mobility'] as num).toDouble(),
      delay = (row['Delay'] as num).toDouble(),
      acceleration = (row['Acceleration'] as num).toDouble(),
      previousGravity = _Point(gravity.x, cubismF32(-gravity.y));
  final double radius, mobility, delay, acceleration;
  final position = _Point(0, 0),
      previous = _Point(0, 0),
      velocity = _Point(0, 0);
  final _Point previousGravity;
}

final class _Chain {
  _Chain(Map row, NativeCubismParameterState p, _Point gravity)
    : inputs = [
        for (final source in (row['Input'] as List).cast<Map>())
          _Input(source, p),
      ],
      outputs = [
        for (final source in (row['Output'] as List).cast<Map>())
          _Output(source, p),
      ],
      points = [
        for (final source in (row['Particles'] as List).cast<Map>())
          _Particle(source, gravity),
      ],
      angleRange = _Range((row['Normalization'] as Map)['Angle'] as Map),
      positionRange = _Range((row['Normalization'] as Map)['Position'] as Map) {
    if (points.isEmpty) throw const FormatException('cubism_rig_chain');
    for (var i = 1; i < points.length; i++) {
      points[i].position.set(
        0,
        cubismF32(points[i - 1].position.y + points[i].radius),
      );
      points[i].previous.assign(points[i].position);
    }
    currentOutputs = Float32List(outputs.length);
    previousOutputs = Float32List(outputs.length);
  }
  final List<_Input> inputs;
  final List<_Output> outputs;
  final List<_Particle> points;
  final _Range angleRange, positionRange;
  late final Float32List currentOutputs, previousOutputs;
  double get threshold => cubismF32(positionRange.maximum * cubismF32(.001));
}

final class _Point {
  _Point(this.x, this.y);
  double x, y;
  void set(double nx, double ny) {
    x = nx;
    y = ny;
  }

  void assign(_Point p) => set(p.x, p.y);
  _Point unit() {
    final length = cubismF32(
      math.sqrt(cubismF32(cubismF32(x * x) + cubismF32(y * y))),
    );
    return length > .00001
        ? _Point(cubismF32(x / length), cubismF32(y / length))
        : _Point(0, 0);
  }
}

_Point _point(Map row) =>
    _Point((row['x'] as num).toDouble(), (row['y'] as num).toDouble());
_Point _directionForAngle(double angle) {
  final radians = cubismF32(cubismF32(angle / 180) * cubismF32(math.pi));
  return _Point(
    cubismF32(math.sin(radians)),
    cubismF32(math.cos(radians)),
  ).unit();
}

double _wrapped(double value) {
  final pi = cubismF32(math.pi), turn = cubismF32(2 * math.pi);
  while (value < -pi) {
    value = cubismF32(value + turn);
  }
  while (value > pi) {
    value = cubismF32(value - turn);
  }
  return value;
}
