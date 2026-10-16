import 'dart:convert';
import 'dart:math' as math;

/// Applies actual zero-duration source sequence endpoints. Animated/ease/runtime
/// commands remain explicit unsupported input, not substituted static timelines.
Map<String, Object?> applyStillInstantSequence(
  Map<String, Object?> document,
  String id,
) {
  final result = Map<String, Object?>.from(
    jsonDecode(jsonEncode(document)) as Map,
  );
  final layout = result['layout'] as Map;
  final nodes = {
    for (final node in layout['nodes'] as List)
      (node as Map)['id'] as String: node,
  };
  final sequences = result['sequences'] as List;
  final matching = sequences.where((s) => (s as Map)['id'] == id).toList();
  if (matching.length != 1) {
    throw FormatException('native_still_sequence_identity');
  }
  final sequence = matching.single as Map;
  if ((sequence['nativeActions'] as List).isNotEmpty) {
    throw UnsupportedError('native_still_callbacks');
  }
  List<double> qmul(List<double> a, List<double> b) => [
    a[3] * b[0] + a[0] * b[3] + a[1] * b[2] - a[2] * b[1],
    a[3] * b[1] - a[0] * b[2] + a[1] * b[3] + a[2] * b[0],
    a[3] * b[2] + a[0] * b[1] - a[1] * b[0] + a[2] * b[3],
    a[3] * b[3] - a[0] * b[0] - a[1] * b[1] - a[2] * b[2],
  ];
  List<double> worldQuaternion(String nodeId, Set<String> path) {
    if (!path.add(nodeId)) throw FormatException('native_still_rotation_cycle');
    final node = nodes[nodeId];
    if (node == null) throw FormatException('native_still_rotation_parent');
    final local = (node['rotationQuaternion'] as List)
        .map((v) => (v as num).toDouble())
        .toList();
    final parent = node['parent'];
    final value = parent == null
        ? local
        : qmul(worldQuaternion(parent as String, path), local);
    path.remove(nodeId);
    return value;
  }

  for (final record in sequence['nativeTweens'] as List) {
    final tween = record as Map, raw = tween['raw'] as Map;
    if ((tween['duration'] as num) != 0 ||
        (tween['at'] as num) != 0 ||
        (raw['isRelative'] == 1 || raw['isRelative'] == true) ||
        (raw['isFrom'] == 1 || raw['isFrom'] == true) ||
        raw['loops'] != 1) {
      throw UnsupportedError('native_still_noninstant_or_relative_tween');
    }
    final node = nodes[tween['node']];
    if (node == null) throw FormatException('native_still_tween_node');
    switch (tween['animationType']) {
      case 6:
        if (tween['targetKind'] != 'image' || node['image'] is! Map) {
          throw UnsupportedError('native_still_tween_color_target');
        }
        final color = raw['endValueColor'] as Map;
        (node['image'] as Map)['color'] = [
          for (final k in ['r', 'g', 'b', 'a']) (color[k] as num).toDouble(),
        ];
      case 5:
        if (tween['targetKind'] != 'transform' || raw['targetType'] != 11) {
          throw UnsupportedError('native_still_tween_scale_target');
        }
        final value = raw['endValueV3'] as Map;
        final xyz = raw['optionalBool0'] == 1
            ? List<double>.filled(3, (raw['endValueFloat'] as num).toDouble())
            : [
                for (final k in ['x', 'y', 'z']) (value[k] as num).toDouble(),
              ];
        node['scale'] = xyz.sublist(0, 2);
        node['scaleZ'] = xyz[2];
      case 3:
        if (tween['targetKind'] != 'transform' ||
            raw['targetType'] != 11 ||
            ![0, 1].contains(raw['optionalInt0'])) {
          throw UnsupportedError('native_still_tween_rotation_target');
        }
        final v = raw['endValueV3'] as Map;
        final angles = [
          for (final k in ['x', 'y', 'z'])
            (v[k] as num).toDouble() * math.pi / 360,
        ];
        final qx = [math.sin(angles[0]), 0.0, 0.0, math.cos(angles[0])];
        final qy = [0.0, math.sin(angles[1]), 0.0, math.cos(angles[1])];
        final qz = [0.0, 0.0, math.sin(angles[2]), math.cos(angles[2])];
        final world = qmul(qmul(qy, qx), qz);
        final parent = node['parent'];
        final p = parent == null
            ? [0.0, 0.0, 0.0, 1.0]
            : worldQuaternion(parent as String, {});
        node['rotationQuaternion'] = qmul([-p[0], -p[1], -p[2], p[3]], world);
      default:
        throw UnsupportedError(
          'native_still_tween_type:${tween['animationType']}',
        );
    }
  }
  return result;
}
