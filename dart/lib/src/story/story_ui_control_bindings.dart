import 'dart:typed_data';

import 'story_scene_state.dart';
import 'story_talk_indicator_animator.dart';
import 'story_talk_window_visibility.dart';
import 'story_ui_layout_data.dart';

Map _map(Object? v) =>
    v is Map ? v : throw const FormatException('ui_control_map');
String _id(Object? v) {
  if (v is! String || !RegExp(r'^-?\d+$').hasMatch(v)) {
    throw const FormatException('ui_control_decimal_id');
  }
  return v;
}

String _pointer(Object? v) {
  final p = _map(v);
  if (p['m_FileID'] != 0) {
    throw const FormatException('ui_control_local_pointer');
  }
  return _id(p['m_PathID']);
}

List<double> _vector(Object? v, List<String> axes) {
  final raw = _map(v);
  return List.unmodifiable([
    for (final axis in axes)
      if (raw[axis] is num && (raw[axis] as num).isFinite)
        (raw[axis] as num).toDouble()
      else
        throw const FormatException('ui_control_vector'),
  ]);
}

bool _same(List<double> a, List<double> b) =>
    a.length == b.length &&
    [for (var i = 0; i < a.length; i++) a[i] == b[i]].every((v) => v);

/// A complete original transform binding; this batch does not perform layout.
final class StoryUiControlTransform {
  StoryUiControlTransform._(
    this.id,
    this.gameObjectId,
    this.parentId,
    this.path,
    this.serializedFile,
    this.sourceHash,
    this.active,
    this.anchorMin,
    this.anchorMax,
    this.anchoredPosition,
    this.sizeDelta,
    this.pivot,
    this.localPosition,
    this.quaternion,
    this.scale,
  );
  final String id, gameObjectId, path, serializedFile, sourceHash;
  final String? parentId;
  final bool active;
  final List<double> anchorMin, anchorMax, anchoredPosition, sizeDelta, pivot;
  final List<double> localPosition, quaternion, scale;
}

final class StoryUiControlEndpoint {
  const StoryUiControlEndpoint({
    required this.objectId,
    required this.objectType,
    required this.gameObjectId,
    required this.transformId,
    required this.path,
  });
  final String objectId, objectType, gameObjectId, transformId, path;
}

final class StoryUiControlWindow {
  StoryUiControlWindow._(
    this.visibility,
    this.controllerId,
    this.serializedFile,
    Map<String, StoryUiControlTransform> transforms,
    Map<String, StoryUiControlEndpoint?> endpoints,
  ) : transforms = Map.unmodifiable(transforms),
      endpoints = Map.unmodifiable(endpoints);
  final StoryTalkWindowVisibilitySource visibility;
  final String controllerId, serializedFile;
  final Map<String, StoryUiControlTransform> transforms;
  final Map<String, StoryUiControlEndpoint?> endpoints;
}

/// Source-owned binding graph, compiled once when the normal UI assets load.
final class StoryUiControlBindings {
  StoryUiControlBindings._(
    this.sourceId,
    this.packetSHA256,
    this.sceneSHA256,
    this.defaultEase,
    Map<String, StoryUiControlWindow> windows,
    Map<String, StoryTalkIndicatorAnimatorSource> indicators,
    this.backdrop,
  ) : windows = Map.unmodifiable(windows),
      indicators = Map.unmodifiable(indicators);
  final String sourceId, packetSHA256, sceneSHA256;
  final int defaultEase;
  final Map<String, StoryUiControlWindow> windows;
  final Map<String, StoryTalkIndicatorAnimatorSource> indicators;
  final StoryTalkBackdropSource backdrop;

  factory StoryUiControlBindings.fromPacket({
    required Map<String, Object?> packet,
    required StorySourceIdentity source,
    required String packetSHA256,
    required StoryUiSceneData scenes,
  }) {
    if (source.server != 'intl' ||
        source.sourceId != 'v25-c0b6a1541e45-3a5d2eec9935-n653c6392' ||
        packet['sourceId'] != source.sourceId ||
        packet['schema'] != 'haneoka-talk-window-visibility-source-v1' ||
        packetSHA256 !=
            '777b064e58c76a24d1ef17479de8299b7640625966673fb29e87b9ab07083414' ||
        scenes.sourceHash !=
            'eeedec45154d1f305a342418be78bec956446c037c94144cc6fcd588b32225fd' ||
        packet['actualDefaultEase'] != 6) {
      throw const FormatException('ui_control_source_identity');
    }
    final scripts = Map<String, Object?>.from(_map(packet['scriptMetadata']));
    final windows = <String, StoryUiControlWindow>{};
    final indicators = <String, StoryTalkIndicatorAnimatorSource>{};
    for (final mode in ['Default', 'Center']) {
      final entry = Map<String, Object?>.from(
        _map(_map(packet['windows'])[mode]),
      );
      final visibility = StoryTalkWindowVisibilitySource.fromRaw(
        mode,
        entry,
        actualScriptMetadata: scripts,
      );
      final controller = _map(entry['controller']);
      final controllerData = _map(controller['data']);
      final file = controller['serializedFile'] as String;
      final sceneNodes = <String, StoryUiLayoutNode>{};
      void collect(StoryUiLayoutNode node) {
        if (sceneNodes.containsKey(node.path)) {
          throw const FormatException('ui_control_duplicate_scene_path');
        }
        sceneNodes[node.path] = node;
        for (final child in node.children) {
          collect(child);
        }
      }

      final sceneName = mode == 'Default'
          ? 'UIDefaultTalkWindow'
          : 'UICenterTalkWindow';
      final roots = scenes.scenes[sceneName];
      if (roots == null) {
        throw const FormatException('ui_control_scene_missing');
      }
      for (final root in roots) {
        collect(root);
      }
      final transforms = <String, StoryUiControlTransform>{};
      final goToTransform = <String, String>{};
      StoryUiControlTransform add(Map row, String path) {
        final transform = _map(row['transform']),
            game = _map(row['gameObject']);
        final tr = _map(transform['data']), gd = _map(game['data']);
        final id = _id(transform['pathId']), go = _id(game['pathId']);
        final parent = _pointer(tr['m_Father']);
        if (transform['type'] != 'RectTransform' ||
            transform['serializedFile'] != file ||
            game['serializedFile'] != file ||
            game['type'] != 'GameObject' ||
            _pointer(tr['m_GameObject']) != go ||
            !(gd['m_Component'] as List).any(
              (c) => _pointer(_map(c)['component']) == id,
            )) {
          throw const FormatException('ui_control_transform_binding');
        }
        final node = sceneNodes[path];
        if (node == null) throw FormatException('ui_control_scene_path:$path');
        final rect = [
          _vector(tr['m_AnchorMin'], ['x', 'y']),
          _vector(tr['m_AnchorMax'], ['x', 'y']),
          _vector(tr['m_AnchoredPosition'], ['x', 'y']),
          _vector(tr['m_SizeDelta'], ['x', 'y']),
          _vector(tr['m_Pivot'], ['x', 'y']),
        ];
        final scale = _vector(tr['m_LocalScale'], ['x', 'y', 'z']);
        final compactScale = (node.raw['scale'] as List)
            .cast<num>()
            .map((v) => v.toDouble())
            .toList();
        if ([for (var i = 0; i < 5; i++) _same(rect[i], node.rect[i])]
                .any((v) => !v) ||
            !_same(scale.sublist(0, 2), compactScale)) {
          throw FormatException('ui_control_compact_geometry:$path');
        }
        final result = StoryUiControlTransform._(
          id,
          go,
          parent == '0' ? null : parent,
          path,
          file,
          visibility.sourceUiHash,
          gd['m_IsActive'] == true,
          rect[0],
          rect[1],
          rect[2],
          rect[3],
          rect[4],
          _vector(tr['m_LocalPosition'], ['x', 'y', 'z']),
          _vector(tr['m_LocalRotation'], ['x', 'y', 'z', 'w']),
          scale,
        );
        final existing = transforms[id];
        if (existing != null &&
            (existing.path != path ||
                existing.gameObjectId != go ||
                existing.parentId != result.parentId ||
                !_same(existing.localPosition, result.localPosition) ||
                !_same(existing.quaternion, result.quaternion) ||
                !_same(existing.scale, result.scale))) {
          throw const FormatException('ui_control_duplicate_transform');
        }
        if (goToTransform[go] != null && goToTransform[go] != id) {
          throw const FormatException('ui_control_duplicate_game_object');
        }
        transforms[id] = existing ?? result;
        goToTransform[go] = id;
        return transforms[id]!;
      }

      String chain(List rows) {
        var path = '';
        String? previous;
        for (final value in rows) {
          final row = _map(value), gd = _map(_map(row['gameObject'])['data']);
          final name = gd['m_Name'];
          if (name is! String || name.isEmpty || name.contains('/')) {
            throw const FormatException('ui_control_hierarchy_name');
          }
          final bound = add(row, path = '$path/$name');
          if (bound.parentId != previous) {
            throw const FormatException('ui_control_hierarchy_parent');
          }
          previous = bound.id;
        }
        return path;
      }

      final root = _map(entry['root']);
      if (chain(root['hierarchy'] as List) != '/${root['hierarchyPath']}') {
        throw const FormatException('ui_control_root_path');
      }
      final endpoints = <String, StoryUiControlEndpoint?>{};
      final references = _map(entry['references']);
      for (final binding in references.entries) {
        final field = binding.key as String, ref = _map(binding.value);
        final id = _pointer(ref['pointer']);
        if (_pointer(controllerData[field]) != id) {
          throw const FormatException('ui_control_controller_pointer');
        }
        if (id == '0') {
          if (ref['endpoint'] != null) {
            throw const FormatException('ui_control_null_endpoint');
          }
          endpoints[field] = null;
          continue;
        }
        final endpoint = _map(ref['endpoint']);
        final path = chain(endpoint['hierarchy'] as List);
        final object = _map(endpoint['object']);
        final go = _id(_map(endpoint['gameObject'])['pathId']);
        if (path != '/${endpoint['hierarchyPath']}' ||
            _id(object['pathId']) != id ||
            object['serializedFile'] != file ||
            goToTransform[go] == null ||
            (object['type'] == 'GameObject'
                ? id != go
                : _pointer(_map(object['data'])['m_GameObject']) != go)) {
          throw const FormatException('ui_control_endpoint_identity');
        }
        endpoints[field] = StoryUiControlEndpoint(
          objectId: id,
          objectType: object['type'] as String,
          gameObjectId: go,
          transformId: goToTransform[go]!,
          path: path,
        );
      }
      final contracts = _map(entry['indicatorAnimationContracts']);
      for (final field in ['_talkNextIndicator', '_autoIcon', '_fastIcon']) {
        final contract = Map<String, Object?>.from(_map(contracts[field]));
        final remaining = List<Map>.from(contract['originalNodeTree'] as List);
        while (remaining.isNotEmpty) {
          var progress = false;
          for (final row in List<Map>.of(remaining)) {
            final tr = _map(_map(row['transform'])['data']);
            final id = _id(_map(row['transform'])['pathId']);
            final known = transforms[id];
            final parent = transforms[_pointer(tr['m_Father'])];
            if (known == null && parent == null) continue;
            final name = _map(_map(row['gameObject'])['data'])['m_Name'];
            add(row, known?.path ?? '${parent!.path}/$name');
            remaining.remove(row);
            progress = true;
          }
          if (!progress) {
            throw const FormatException('ui_control_subtree_parent');
          }
        }
        final parsed = StoryTalkIndicatorAnimatorSource.fromRaw(
          mode,
          field,
          Map<String, Object?>.from(_map(references[field])),
          contract,
        );
        if (parsed != null) {
          if (transforms[parsed.rootTransformId]?.path !=
              '/${parsed.rootHierarchyPath}') {
            throw const FormatException('ui_control_indicator_root');
          }
          indicators[parsed.key] = parsed;
        }
      }
      windows[mode] = StoryUiControlWindow._(
        visibility,
        _id(controller['pathId']),
        file,
        transforms,
        endpoints,
      );
    }
    return StoryUiControlBindings._(
      source.sourceId,
      packetSHA256,
      scenes.sourceHash,
      packet['actualDefaultEase'] as int,
      windows,
      indicators,
      StoryTalkBackdropSource.fromRaw(
        Map<String, Object?>.from(_map(packet['widgetBackdropReferences'])),
      ),
    );
  }
}

/// Sparse nullable channels; no rendering or animation-clock updates occur here.
final class StoryUiControlPoseChannels {
  StoryUiControlPoseChannels({
    required this.transformId,
    this.anchoredY,
    List<double>? localQuaternion,
  }) : localQuaternion = localQuaternion == null
           ? null
           : List.unmodifiable(localQuaternion) {
    _id(transformId);
    if ((anchoredY != null && !anchoredY!.isFinite) ||
        (localQuaternion != null &&
            (localQuaternion.length != 4 ||
                localQuaternion.any((v) => !v.isFinite)))) {
      throw const FormatException('ui_control_pose_channels');
    }
  }
  final String transformId;
  final double? anchoredY;
  final List<double>? localQuaternion;
}

/// Placement contract for the later measured-layout consumer; no layout is
/// changed by constructing the current source bindings.
final class StoryUiControlPlacement {
  StoryUiControlPlacement({
    required this.localRect,
    required Float32List localToCanvas,
    required this.activeInHierarchy,
    required this.inheritedAlpha,
  }) : localToCanvas = Float32List.fromList(localToCanvas)
           .asUnmodifiableView() {
    if (localToCanvas.length != 16 ||
        localToCanvas.any((v) => !v.isFinite) ||
        [
          localRect.x,
          localRect.y,
          localRect.width,
          localRect.height,
        ].any((v) => !v.isFinite) ||
        localRect.width < 0 ||
        localRect.height < 0 ||
        !inheritedAlpha.isFinite) {
      throw const FormatException('ui_control_placement');
    }
  }
  final StoryUiRect localRect;
  final Float32List localToCanvas;
  final bool activeInHierarchy;
  final double inheritedAlpha;
}
