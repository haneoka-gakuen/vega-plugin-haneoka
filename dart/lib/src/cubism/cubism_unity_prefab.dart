import 'dart:convert';

import 'cubism_unity_clip.dart';

/// Generic original-prefab data. The application supplies source-bound records;
/// transport, releases and game-specific model IDs remain outside the backend.
final class NativeCubismUnityPrefab {
  NativeCubismUnityPrefab(List<Map> records) {
    for (final record in records) {
      final id = record['pathId'];
      if (id is! String || !_id.hasMatch(id) || _records.containsKey(id)) {
        throw const FormatException('native_cubism_record_identity');
      }
      _records[id] = record;
    }
    final animators = _records.values.where((row) => row['type'] == 'Animator');
    if (animators.length != 1) {
      throw const FormatException('native_cubism_animator_root');
    }
    final transforms = <String, Map>{};
    final byGame = <String, String>{};
    for (final row in _records.values) {
      if (row['type'] != 'Transform') continue;
      final data = row['data'] as Map, id = row['pathId'] as String;
      final game = _local(data['m_GameObject']);
      if (byGame.containsKey(game)) {
        throw const FormatException('native_cubism_transform_game');
      }
      transforms[id] = data;
      byGame[game] = id;
    }
    final animator = animators.single['data'] as Map;
    rootGame = _local(animator['m_GameObject']);
    final rootTransform = byGame[rootGame];
    if (rootTransform == null) {
      throw const FormatException('native_cubism_root_transform');
    }
    final paths = <int, String>{}, visiting = <String>{};
    void walk(String node, String path) {
      if (!visiting.add(node)) {
        throw const FormatException('native_cubism_transform_cycle');
      }
      final hash = _crc32(path);
      if (paths.containsKey(hash)) {
        throw const FormatException('native_cubism_path_crc_collision');
      }
      paths[hash] = path;
      final transform = transforms[node];
      if (transform == null) {
        throw const FormatException('native_cubism_transform_reference');
      }
      for (final pointer in (transform['m_Children'] as List).cast<Map>()) {
        final child = _local(pointer), data = transforms[child];
        if (data == null) {
          throw const FormatException('native_cubism_child_transform');
        }
        final game = _record(_local(data['m_GameObject']), 'GameObject');
        final name = (game['data'] as Map)['m_Name'];
        if (name is! String || name.isEmpty || name.contains('/')) {
          throw const FormatException('native_cubism_transform_name');
        }
        walk(child, path.isEmpty ? name : '$path/$name');
      }
      visiting.remove(node);
    }

    walk(rootTransform, '');
    transformPaths = Map.unmodifiable(paths);
    final components = <String, Map>{};
    for (final row in _records.values) {
      if (row['type'] != 'MonoBehaviour') continue;
      final data = row['data'] as Map;
      if (_local(data['m_GameObject']) != rootGame) continue;
      final name = _script(data['m_Script']);
      if (components.containsKey(name)) {
        throw FormatException('native_cubism_root_component_duplicate:$name');
      }
      components[name] = data;
    }
    rootComponents = Map.unmodifiable(components);
    final character = component('Live2DCharacter');
    final result = <String, NativeCubismUnityClip>{};
    for (final ref in (character['_motionList'] as List).cast<Map>()) {
      final data = _record(_local(ref), 'AnimationClip')['data'] as Map;
      final bindings = <NativeCubismClipBinding>[];
      for (final binding
          in ((data['m_ClipBindingConstant'] as Map)['genericBindings'] as List)
              .cast<Map>()) {
        final path = paths[binding['path']];
        if (path == null) {
          bindings.add(const NativeCubismClipBinding.unbound());
          continue;
        }
        if (binding['typeID'] != 114 ||
            binding['isPPtrCurve'] != 0 ||
            binding['isIntCurve'] != 0) {
          throw const FormatException('native_cubism_clip_binding_type');
        }
        final name = _script(binding['script']);
        final attribute = binding['attribute'];
        if (name == 'CubismParameter' &&
            attribute == _crc32('Value') &&
            path.startsWith('Parameters/')) {
          bindings.add(
            NativeCubismClipBinding.parameter(
              path.substring('Parameters/'.length),
            ),
          );
        } else if (path.isEmpty) {
          final field = _controllerFields['$name:$attribute'];
          if (field == null) {
            throw FormatException(
              'native_cubism_controller_binding:$name:$attribute',
            );
          }
          bindings.add(NativeCubismClipBinding.field(field));
        } else {
          throw FormatException(
            'native_cubism_clip_binding:$name:$path:$attribute',
          );
        }
      }
      final clip = NativeCubismUnityClip(data, bindings);
      if (result.containsKey(clip.name)) {
        throw FormatException('native_cubism_clip_duplicate:${clip.name}');
      }
      result[clip.name] = clip;
    }
    clips = Map.unmodifiable(result);
    final fadeController = component('CubismFadeController');
    final fadeList = _mono(
      fadeController['CubismFadeMotionList'],
      'CubismFadeMotionList',
    );
    fadeInstanceIds = List.unmodifiable(
      (fadeList['MotionInstanceIds'] as List).cast<int>(),
    );
    fadeMotions = List.unmodifiable([
      for (final pointer
          in (fadeList['CubismFadeMotionObjects'] as List).cast<Map>())
        Map<String, Object?>.unmodifiable(
          _mono(pointer, 'CubismFadeMotionData').cast<String, Object?>(),
        ),
    ]);
    if (fadeMotions.length != fadeInstanceIds.length) {
      throw const FormatException('native_cubism_fade_list_size');
    }
    final expressionController = component('CubismExpressionController');
    if (expressionController['UseLegacyBlendCalculation'] == true) {
      throw UnsupportedError('native_cubism_legacy_expression');
    }
    final expressionPtr = expressionController['ExpressionsList'] as Map;
    if (expressionPtr['m_PathID'] == '0') {
      expressions = const [];
    } else {
      final list = _mono(expressionPtr, 'CubismExpressionList');
      expressions = List.unmodifiable([
        for (final pointer
            in (list['CubismExpressionObjects'] as List).cast<Map>())
          Map<String, Object?>.unmodifiable(
            _mono(pointer, 'CubismExpressionData').cast<String, Object?>(),
          ),
      ]);
    }
  }
  final _records = <String, Map>{};
  late final String rootGame;
  late final Map<int, String> transformPaths;
  late final Map<String, Map> rootComponents;
  late final Map<String, NativeCubismUnityClip> clips;
  late final List<int> fadeInstanceIds;
  late final List<Map<String, Object?>> fadeMotions, expressions;

  List<(String, Map)> tagged(String type) {
    final result = <(String, Map)>[];
    for (final row in _records.values) {
      if (row['type'] != 'MonoBehaviour') continue;
      final data = row['data'] as Map;
      if (_script(data['m_Script']) != type) continue;
      final game = _record(_local(data['m_GameObject']), 'GameObject');
      final name = (game['data'] as Map)['m_Name'];
      if (name is! String) {
        throw const FormatException('native_cubism_tag_name');
      }
      result.add((name, data));
    }
    return List.unmodifiable(result);
  }

  Map component(String type) =>
      rootComponents[type] ??
      (throw FormatException('native_cubism_component_missing:$type'));

  Map _record(String id, String type) {
    final value = _records[id];
    if (value == null || value['type'] != type) {
      throw FormatException('native_cubism_record_missing:$type:$id');
    }
    return value;
  }

  Map _mono(Object? pointer, String expected) {
    final record = _record(_local(pointer), 'MonoBehaviour');
    final data = record['data'] as Map;
    if (_script(data['m_Script']) != expected) {
      throw FormatException('native_cubism_pointer_type:$expected');
    }
    return data;
  }
}

final _id = RegExp(r'^-?[0-9]+$');
String _local(Object? value) {
  if (value is! Map ||
      value['m_FileID'] != 0 ||
      value['m_PathID'] is! String ||
      !_id.hasMatch(value['m_PathID'] as String)) {
    throw const FormatException('native_cubism_local_pointer');
  }
  return value['m_PathID'] as String;
}

String _script(Object? pointer) {
  if (pointer is! Map || pointer['m_PathID'] is! String) {
    throw const FormatException('native_cubism_script_pointer');
  }
  final reference = pointer['reference'];
  if (reference is! Map ||
      reference['status'] != 'resolved' ||
      reference['type'] != 'MonoScript' ||
      reference['pathId'] != pointer['m_PathID'] ||
      reference['name'] is! String) {
    throw const FormatException('native_cubism_script_reference');
  }
  return reference['name'] as String;
}

int _crc32(String value) {
  var crc = 0xffffffff;
  for (final byte in utf8.encode(value)) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc >>> 1) ^ ((crc & 1) == 1 ? 0xedb88320 : 0);
    }
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}

final _controllerFields = <String, String>{
  'CubismEyeBlinkController:${_crc32('EyeOpening')}': 'eyeOpening',
  'CubismMouthController:${_crc32('MouthOpening')}': 'mouthOpening',
  'CubismRenderController:${_crc32('Opacity')}': 'renderOpacity',
};
