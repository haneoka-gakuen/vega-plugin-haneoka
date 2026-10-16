import 'dart:math' as math;
import 'dart:typed_data';

import 'package:render_contracts/math.dart';

final class HaneokaSphericalHarmonics {
  const HaneokaSphericalHarmonics({
    required this.ar,
    required this.ag,
    required this.ab,
    required this.br,
    required this.bg,
    required this.bb,
    required this.c,
  });

  static const flatWhite = HaneokaSphericalHarmonics(
    ar: [0, 0, 0, 1],
    ag: [0, 0, 0, 1],
    ab: [0, 0, 0, 1],
    br: [0, 0, 0, 0],
    bg: [0, 0, 0, 0],
    bb: [0, 0, 0, 0],
    c: [0, 0, 0, 0],
  );

  final List<double> ar, ag, ab, br, bg, bb, c;

  Float32List shade(double x, double y, double z) {
    double channel(List<double> a, List<double> b, double quadratic) =>
        b[0] * y * x +
        b[1] * z * y +
        b[2] * z * z +
        b[3] * x * z +
        quadratic * (x * x - y * y) +
        a[0] * x +
        a[1] * y +
        a[2] * z +
        a[3];
    return Float32List.fromList([
      channel(ar, br, c[0]),
      channel(ag, bg, c[1]),
      channel(ab, bb, c[2]),
    ]);
  }
}

/// Serialized stage lighting stays with the game profile, in Unity world units.
final class HaneokaStageLight {
  HaneokaStageLight({
    required this.kind,
    required this.active,
    required this.position,
    required this.forward,
    required this.color,
    required this.intensity,
    required this.range,
    required this.spotAngle,
    required this.innerSpotAngle,
  });

  final int kind;
  final bool active;
  final Float32List position, forward, color;
  final double intensity, range, spotAngle, innerSpotAngle;

  factory HaneokaStageLight.fromCatalog(Map value) {
    return HaneokaStageLight(
      kind: value['type'] as int,
      active: value['active'] != false,
      position: _vector(value['worldPosition'] as Map),
      forward: _unit(_vector(value['worldForward'] as Map)),
      color: _vector(value['color'] as Map, const ['r', 'g', 'b']),
      intensity: _number(value['intensity']),
      range: _number(value['range']),
      spotAngle: _number(value['spotAngle']),
      innerSpotAngle: _number(value['innerSpotAngle']),
    );
  }
}

final class HaneokaStageLighting {
  HaneokaStageLighting(Iterable<Iterable<HaneokaStageLight>> groups)
    : groups = List.unmodifiable(
        groups.map((group) => List<HaneokaStageLight>.unmodifiable(group)),
      );

  final List<List<HaneokaStageLight>> groups;

  factory HaneokaStageLighting.fromCatalog(Map stage) => HaneokaStageLighting([
    for (final group in (stage['environmentLightGroups'] as List).cast<Map>())
      [
        for (final light in (group['lights'] as List).cast<Map>())
          HaneokaStageLight.fromCatalog(light),
      ],
  ]);

  factory HaneokaStageLighting.fromUnityRecords(
    Iterable<Map> sourceRecords, {
    required Map stageRecord,
  }) {
    final records = <String, Map>{};
    final transforms = <String, Map>{};
    final lights = <String, List<Map>>{};
    String key(Map record) => '${record['serializedFile']}:${record['pathId']}';
    String pointer(Map owner, Object? raw) {
      final p = raw as Map;
      if (p['m_FileID'] == 0) {
        return '${owner['serializedFile']}:${p['m_PathID']}';
      }
      final reference = p['reference'] as Map;
      if (reference['status'] != 'resolved' ||
          '${reference['pathId']}' != '${p['m_PathID']}') {
        throw const FormatException('story_light_pointer');
      }
      return '${reference['serializedFile']}:${reference['pathId']}';
    }

    for (final record in sourceRecords) {
      final id = key(record);
      if (records.containsKey(id)) {
        throw const FormatException('story_light_duplicate_record');
      }
      records[id] = record;
      if (record['type'] == 'Transform' || record['type'] == 'RectTransform') {
        transforms[pointer(record, (record['data'] as Map)['m_GameObject'])] =
            record;
      } else if (record['type'] == 'Light') {
        (lights[pointer(record, (record['data'] as Map)['m_GameObject'])] ??=
                [])
            .add(record);
      }
    }
    Map require(String id, String type) {
      final record = records[id];
      if (record == null ||
          (record['type'] != type &&
              !(type == 'Transform' && record['type'] == 'RectTransform'))) {
        throw FormatException('story_light_source_record:$type:$id');
      }
      return record;
    }

    final matrices = <String, Float32List>{};
    final visiting = <String>{};
    Float32List world(Map transform) {
      final id = key(transform);
      if (matrices[id] case final cached?) return cached;
      if (!visiting.add(id)) {
        throw const FormatException('story_light_transform_cycle');
      }
      final raw = transform['data'] as Map;
      final local = trsMatrix4(
        translation: _vector(raw['m_LocalPosition'] as Map),
        quaternion: _vector(raw['m_LocalRotation'] as Map, const [
          'x',
          'y',
          'z',
          'w',
        ]),
        scale: _vector(raw['m_LocalScale'] as Map),
      );
      final father = raw['m_Father'] as Map;
      final result = '${father['m_PathID']}' == '0'
          ? local
          : multiplyMatrix4(
              world(require(pointer(transform, father), 'Transform')),
              local,
            );
      visiting.remove(id);
      return matrices[id] = result;
    }

    bool active(Map transform) {
      final visited = <String>{};
      var node = transform;
      while (true) {
        if (!visited.add(key(node))) {
          throw const FormatException('story_light_active_cycle');
        }
        final data = node['data'] as Map;
        final go = require(pointer(node, data['m_GameObject']), 'GameObject');
        if ((go['data'] as Map)['m_IsActive'] != true) return false;
        final father = data['m_Father'] as Map;
        if ('${father['m_PathID']}' == '0') return true;
        node = require(pointer(node, father), 'Transform');
      }
    }

    final stage = stageRecord['data'] as Map;
    return HaneokaStageLighting([
      for (final group
          in ((stage['_lightGroupCollection'] as Map)['_groups'] as List)
              .cast<Map>())
        [
          for (final reference in group['_lights'] as List)
            (() {
              final controller = require(
                pointer(stageRecord, reference),
                'MonoBehaviour',
              );
              final controllerData = controller['data'] as Map;
              final script =
                  (controllerData['m_Script'] as Map)['reference'] as Map;
              if (script['name'] != 'AdvLight') {
                throw const FormatException('story_light_controller');
              }
              final go = pointer(controller, controllerData['m_GameObject']);
              final sourceLights = lights[go];
              final transform = transforms[go];
              if (sourceLights == null ||
                  sourceLights.length != 1 ||
                  transform == null) {
                throw const FormatException('story_light_components');
              }
              final raw = sourceLights.single['data'] as Map;
              final matrix = world(transform);
              return HaneokaStageLight(
                kind: raw['m_Type'] as int,
                active:
                    _enabled(controllerData['m_Enabled']) &&
                    _enabled(raw['m_Enabled']) &&
                    active(transform),
                position: Float32List.fromList(matrix.sublist(12, 15)),
                forward: _unit(Float32List.fromList(matrix.sublist(8, 11))),
                color: _vector(raw['m_Color'] as Map, const ['r', 'g', 'b']),
                intensity: _number(raw['m_Intensity']),
                range: _number(raw['m_Range']),
                spotAngle: _number(raw['m_SpotAngle']),
                innerSpotAngle: _number(raw['m_InnerSpotAngle']),
              );
            })(),
        ],
    ]);
  }

  HaneokaCharacterLighting select(
    int index, {
    required int baseQualityMode,
    required bool allowUnityLighting,
    HaneokaSphericalHarmonics ambient = HaneokaSphericalHarmonics.flatWhite,
  }) => HaneokaCharacterLighting(
    index >= 0 && index < groups.length ? groups[index] : const [],
    baseQualityMode: baseQualityMode,
    allowUnityLighting: allowUnityLighting,
    ambient: ambient,
  );
}

/// Main-only shader family selected by the original High pipeline.
final class HaneokaCharacterLighting {
  HaneokaCharacterLighting(
    Iterable<HaneokaStageLight> source, {
    required this.baseQualityMode,
    required bool allowUnityLighting,
    this.ambient = HaneokaSphericalHarmonics.flatWhite,
  }) : lights = List.unmodifiable(source.where((light) => light.active)),
       allowed = allowUnityLighting {
    if (baseQualityMode < 0 || baseQualityMode > 4) {
      throw ArgumentError('story_light_quality');
    }
  }

  final int baseQualityMode;
  final bool allowed;
  final List<HaneokaStageLight> lights;
  final HaneokaSphericalHarmonics ambient;
  bool get enabled => allowed && baseQualityMode > 2 && lights.isNotEmpty;

  Float32List factorForModel(Float32List sourceModelWorld) {
    if (!enabled) return Float32List.fromList([1, 1, 1]);
    if (baseQualityMode == 4 && lights.any((light) => light.kind != 1)) {
      throw UnsupportedError('story_best_vertex_lighting_pending');
    }
    if (sourceModelWorld.length != 16 ||
        sourceModelWorld.any((value) => !value.isFinite)) {
      throw ArgumentError('story_light_model_world');
    }
    HaneokaStageLight? main;
    for (final light in lights) {
      if (light.kind == 1) {
        main = light;
        break;
      }
    }
    if (main == null) return Float32List(3);
    // NORMAL0=(0,0,1,0); the packaged shader uses M's third column directly.
    final normal = _unit(
      Float32List.fromList([
        sourceModelWorld[8],
        sourceModelWorld[9],
        sourceModelWorld[10],
      ]),
    );
    final sh = ambient.shade(normal[0], normal[1], normal[2]);
    final ndotl = math.max(
      0.0,
      normal[0] * main.forward[0] +
          normal[1] * main.forward[1] +
          normal[2] * main.forward[2],
    );
    return Float32List.fromList([
      for (var i = 0; i < 3; i++)
        _linearToSrgb(sh[i]) * (main.color[i] * main.intensity * ndotl),
    ]);
  }
}

double _linearToSrgb(double value) => value <= 0.00313080009
    ? value * 12.9232101
    : math.pow(value.abs(), 0.416666657) * 1.05499995 - 0.0549999997;

bool _enabled(Object? value) => value == 1 || value == true;
double _number(Object? value) {
  if (value is! num || !value.isFinite) {
    throw const FormatException('story_light_number');
  }
  return value.toDouble();
}

Float32List _vector(Map value, [List<String> axes = const ['x', 'y', 'z']]) =>
    Float32List.fromList([for (final axis in axes) _number(value[axis])]);

Float32List _unit(Float32List value) {
  final square =
      value[0] * value[0] + value[1] * value[1] + value[2] * value[2];
  if (!(square > 0)) throw const FormatException('story_light_direction');
  final scale = 1 / math.sqrt(square);
  return Float32List.fromList([
    for (final component in value) component * scale,
  ]);
}
