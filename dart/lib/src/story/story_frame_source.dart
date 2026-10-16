import 'package:haneoka_render_profile/core.dart';

import 'story_frame_particle_source.dart';

Map<String, Object?> _map(Object? value) =>
    Map<String, Object?>.from(value as Map);
double _number(Object? value) => value is num && value.isFinite
    ? value.toDouble()
    : throw const FormatException('story_frame_source_number');
List<double> _vector(Object? value, List<String> axes) {
  final m = _map(value);
  return List.unmodifiable([for (final axis in axes) _number(m[axis])]);
}

String _pointer(Object? pointer) => (_map(pointer)['m_PathID']).toString();
String? _script(Map<String, Object?> record) {
  final s = (_map(record['data']))['m_Script'];
  if (s is! Map || s['reference'] is! Map) return null;
  return (s['reference'] as Map)['name'] as String?;
}

enum StoryFrameProperty {
  scale,
  position,
  rotation,
  anchoredX,
  anchoredY,
  sizeX,
  sizeY,
  opacity,
  active,
  imageR,
  imageG,
  imageB,
  imageA,
  stretchPositionPercent,
}

final class StoryFramePose {
  StoryFramePose({
    required List<double> position,
    required List<double> size,
    required List<double> scale,
    required List<double> rotation,
    required this.opacity,
    required this.active,
    required List<double> localPosition,
    List<double>? localPositionOverride,
    this.stretchPositionPercent,
    List<double>? imageColor,
  }) : position = List.unmodifiable(position),
       size = List.unmodifiable(size),
       scale = List.unmodifiable(scale),
       rotation = List.unmodifiable(rotation),
       imageColor = imageColor == null ? null : List.unmodifiable(imageColor),
       localPosition = List.unmodifiable(localPosition),
       localPositionOverride = localPositionOverride == null
           ? null
           : List.unmodifiable(localPositionOverride);
  final List<double> position, size, scale, rotation;
  final List<double> localPosition;
  final List<double>? localPositionOverride;
  final double? stretchPositionPercent;
  final List<double>? imageColor;
  final double opacity;
  final bool active;
  Map<String, Object?> toData() => {
    'position': position,
    'size': size,
    'scale': scale,
    'rotation': rotation,
    'opacity': opacity,
    'active': active,
    'localPosition': localPosition,
    'localOverride': localPositionOverride,
    'stretch': stretchPositionPercent,
    'imageColor': imageColor,
  };
  factory StoryFramePose.fromData(Map data) {
    List<double> vector(Object? value, int length) {
      final result = [for (final v in value as List) _number(v)];
      if (result.length != length) {
        throw const FormatException('frame_data_vector');
      }
      return result;
    }

    return StoryFramePose(
      position: vector(data['position'], 3),
      size: vector(data['size'], 2),
      scale: vector(data['scale'], 3),
      rotation: vector(data['rotation'], 4),
      opacity: _number(data['opacity']),
      active: data['active'] as bool,
      localPosition: vector(data['localPosition'], 3),
      localPositionOverride: data['localOverride'] == null
          ? null
          : vector(data['localOverride'], 3),
      stretchPositionPercent: data['stretch'] == null
          ? null
          : _number(data['stretch']),
      imageColor: data['imageColor'] == null
          ? null
          : vector(data['imageColor'], 4),
    );
  }
  StoryFramePose set(StoryFrameProperty property, List<double> values) {
    final p = position.toList(),
        sz = size.toList(),
        sc = scale.toList(),
        r = rotation.toList(),
        c = imageColor?.toList();
    var a = active, o = opacity;
    var localOverride = localPositionOverride;
    var stretch = stretchPositionPercent;
    switch (property) {
      case StoryFrameProperty.position:
        localOverride = List.of(values);
      case StoryFrameProperty.scale:
        sc.setAll(0, values);
      case StoryFrameProperty.rotation:
        r.setAll(0, values);
      case StoryFrameProperty.anchoredX:
        p[0] = values.single;
      case StoryFrameProperty.anchoredY:
        p[1] = values.single;
      case StoryFrameProperty.sizeX:
        sz[0] = values.single;
      case StoryFrameProperty.sizeY:
        sz[1] = values.single;
      case StoryFrameProperty.opacity:
        o = values.single;
      case StoryFrameProperty.active:
        a = values.single > .5;
      case StoryFrameProperty.imageR:
        if (c == null) throw const FormatException('frame_animation_image');
        c[0] = values.single;
      case StoryFrameProperty.imageG:
        if (c == null) throw const FormatException('frame_animation_image');
        c[1] = values.single;
      case StoryFrameProperty.imageB:
        if (c == null) throw const FormatException('frame_animation_image');
        c[2] = values.single;
      case StoryFrameProperty.imageA:
        if (c == null) throw const FormatException('frame_animation_image');
        c[3] = values.single;
      case StoryFrameProperty.stretchPositionPercent:
        if (stretch == null) {
          throw const FormatException('frame_animation_stretch');
        }
        stretch = values.single;
    }
    return StoryFramePose(
      position: p,
      size: sz,
      scale: sc,
      rotation: r,
      opacity: o,
      active: a,
      localPosition: localPosition,
      localPositionOverride: localOverride,
      stretchPositionPercent: stretch,
      imageColor: c,
    );
  }

  List<double> values(StoryFrameProperty property) => switch (property) {
    StoryFrameProperty.position => localPositionOverride ?? localPosition,
    StoryFrameProperty.scale => scale,
    StoryFrameProperty.rotation => rotation,
    StoryFrameProperty.anchoredX => [position[0]],
    StoryFrameProperty.anchoredY => [position[1]],
    StoryFrameProperty.sizeX => [size[0]],
    StoryFrameProperty.sizeY => [size[1]],
    StoryFrameProperty.opacity => [opacity],
    StoryFrameProperty.active => [active ? 1 : 0],
    StoryFrameProperty.imageR => [imageColor![0]],
    StoryFrameProperty.imageG => [imageColor![1]],
    StoryFrameProperty.imageB => [imageColor![2]],
    StoryFrameProperty.imageA => [imageColor![3]],
    StoryFrameProperty.stretchPositionPercent => [stretchPositionPercent!],
  };
}

final class StoryFrameImageData {
  StoryFrameImageData({
    required this.objectId,
    required this.raw,
    required this.spriteRaw,
    required this.texture,
    required this.textureHash,
    required this.materialRaw,
    required this.shaderMetadata,
  });
  final String objectId;
  final Map<String, Object?> raw;
  final Map<String, Object?>? spriteRaw, materialRaw, shaderMetadata;

  /// Exact declared Sprite PNG output; it is a cropped sprite, not a full atlas.
  final String? texture, textureHash;
  bool get enabled => raw['m_Enabled'] == 1 || raw['m_Enabled'] == true;
  int get type => (raw['m_Type'] as num).toInt();
  bool get preserveAspect =>
      raw['m_PreserveAspect'] == 1 || raw['m_PreserveAspect'] == true;
  bool get fillCenter =>
      raw['m_FillCenter'] == 1 || raw['m_FillCenter'] == true;
  double get pixelsPerUnitMultiplier =>
      _number(raw['m_PixelsPerUnitMultiplier']);
  double? get spritePixelsPerUnit =>
      spriteRaw == null ? null : _number(spriteRaw!['m_PixelsToUnits']);
  List<double> get color => _vector(raw['m_Color'], const ['r', 'g', 'b', 'a']);
  List<double>? get border => spriteRaw == null
      ? null
      : _vector(spriteRaw!['m_Border'], const ['x', 'y', 'z', 'w']);
  Map<String, Object?>? get spriteRect =>
      spriteRaw == null ? null : _map(spriteRaw!['m_Rect']);
  Map<String, Object?>? get atlasData =>
      spriteRaw == null ? null : _map(spriteRaw!['m_RD']);
  String? get shaderName => materialRaw == null
      ? null
      : ((_map(materialRaw!['m_Shader'])['reference'] as Map?)?['name']
            as String?);
}

final class StoryFrameNodeData {
  StoryFrameNodeData({
    required this.id,
    required this.gameObjectId,
    required this.path,
    required this.parent,
    required this.rawTransform,
    required this.initial,
    required this.image,
    required this.components,
  });
  final String id, gameObjectId, path;
  final String? parent;
  final Map<String, Object?> rawTransform;
  final StoryFramePose initial;
  final StoryFrameImageData? image;
  final List<Map<String, Object?>> components;
  List<double> get anchorMin =>
      _vector(rawTransform['m_AnchorMin'], const ['x', 'y']);
  List<double> get anchorMax =>
      _vector(rawTransform['m_AnchorMax'], const ['x', 'y']);
  List<double> get pivot => _vector(rawTransform['m_Pivot'], const ['x', 'y']);
  Map<String, Object?> layout(StoryFramePose pose) => {
    'id': id,
    if (parent != null) 'parent': parent,
    'path': path,
    'anchorMin': anchorMin,
    'anchorMax': anchorMax,
    'pivot': pivot,
    'position': pose.position.take(2).toList(),
    'positionZ': pose.position[2],
    if (pose.localPositionOverride != null)
      'localPositionOverride': pose.localPositionOverride,
    if (pose.stretchPositionPercent != null)
      'stretchPositionPercent': pose.stretchPositionPercent,
    'size': pose.size,
    'scale': pose.scale.take(2).toList(),
    'scaleZ': pose.scale[2],
    'rotationQuaternion': pose.rotation,
    'active': pose.active,
    'opacity': pose.opacity,
    if (image != null)
      'image': {
        'enabled': image!.enabled,
        'type': image!.type,
        'color': pose.imageColor,
        'preserveAspect': image!.preserveAspect,
        'fillCenter': image!.fillCenter,
        'pixelsPerUnitMultiplier': image!.pixelsPerUnitMultiplier,
        'spritePixelsPerUnit': image!.spritePixelsPerUnit,
        'border': image!.border,
        if (image!.texture != null) 'texture': image!.texture,
        'textureHash': image!.textureHash,
        'spriteRaw': image!.spriteRaw,
        'imageRaw': image!.raw,
        'materialRaw': image!.materialRaw,
        'shaderMetadata': image!.shaderMetadata,
      },
    'components': components,
  };
}

final class _Binding {
  const _Binding(this.node, this.property, this.start, this.count);
  final String node;
  final StoryFrameProperty property;
  final int start, count;
}

final class StoryFrameClipData {
  StoryFrameClipData(this.id, this.raw, this.clip, this._bindings);
  final String id;
  final Map<String, Object?> raw;
  final NativeAuthoredAnimationClip clip;
  final List<_Binding> _bindings;
  double get duration => clip.duration;
  bool get loop => _map(raw['m_MuscleClip'])['m_LoopTime'] == true;
}

final class StoryFrameTransitionData {
  const StoryFrameTransitionData(this.destination, this.exitTime, this.offset);
  final String destination;
  final double exitTime, offset;
}

final class StoryFrameStateData {
  StoryFrameStateData({
    required this.name,
    required this.speed,
    required this.clip,
    required this.writeDefaults,
    required this.transitions,
  });
  final String name;
  final double speed;
  final StoryFrameClipData? clip;
  final bool writeDefaults;
  final List<StoryFrameTransitionData> transitions;
  double get normalizedLength =>
      clip != null && clip!.duration > 0 ? clip!.duration : 1;
}

/// Compiles the immutable original prefab/controller/clip packet admitted by
/// Root. Hierarchy and animation bindings use original IDs and UTF-8 path CRCs.
final class StoryFrameSource {
  StoryFrameSource._(
    this.ref,
    this.sourcePath,
    this.sourceHash,
    this.rootNodeId,
    this.canvasGroupNodeId,
    this.animatorNodeId,
    this.animatorEnabled,
    this.nodes,
    this.states,
    this.defaultState,
    this.unsupported,
    this.particleSource,
  );
  final StoryFrameParticleSource? particleSource;
  final String ref, sourcePath, sourceHash, rootNodeId, canvasGroupNodeId;
  final String? animatorNodeId, defaultState;
  final bool animatorEnabled;
  final List<StoryFrameNodeData> nodes;
  final Map<String, StoryFrameStateData> states;
  final List<String> unsupported;
  bool get usable => unsupported.isEmpty && !requiresViewportGeometry;
  bool get requiresViewportGeometry => nodes.any(
    (node) => node.components.any((component) {
      final raw = _map(component['data']);
      if (raw['m_Enabled'] != 1 && raw['m_Enabled'] != true) return false;
      return switch (_script(component)) {
        'AspectRatioFitter' => raw['m_AspectMode'] != 0,
        'HorizontalLayoutGroup' ||
        'VerticalLayoutGroup' ||
        'StretchPosition' => true,
        _ => false,
      };
    }),
  );
  Map<String, StoryFramePose> get initialPoses =>
      Map.unmodifiable({for (final node in nodes) node.id: node.initial});
  Map<String, Object?> layout(Map<String, StoryFramePose> poses) {
    if (requiresViewportGeometry) {
      throw UnsupportedError('frame_viewport_geometry_required:$ref');
    }
    return {
      'nodes': [for (final node in nodes) node.layout(poses[node.id]!)],
    };
  }

  factory StoryFrameSource.fromRaw(
    Map<String, Object?> packet, {
    Map<String, Map<String, Object?>> actualShaderMetadata = const {},
  }) {
    final source = _map(packet['source']),
        sourcePath = source['source_path'] as String,
        hash = source['content_sha256'] as String;
    const prefix = 'Assets/AddressableResources/Adv/Frame/';
    if (!sourcePath.startsWith(prefix) ||
        !sourcePath.endsWith('.prefab') ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
      throw const FormatException('story_frame_source_identity');
    }
    final ref = sourcePath.substring(prefix.length, sourcePath.length - 7);
    final particleSource = packet['particleGraph'] == null
        ? null
        : StoryFrameParticleSource.fromRaw(packet);
    final records = {
      for (final r in (packet['objects'] as List).cast<Map>())
        r['pathId'].toString(): _map(r),
    };
    final transforms = <String, Map<String, Object?>>{},
        transformOfGame = <String, String>{};
    for (final r in records.values) {
      if (r['type'] == 'RectTransform') {
        final id = r['pathId'].toString(), d = _map(r['data']);
        transforms[id] = d;
        transformOfGame[_pointer(d['m_GameObject'])] = id;
      }
    }
    final adv = _map(_map(packet['advFrame'])['data']);
    final root = transformOfGame[_pointer(adv['m_GameObject'])]!;
    final groupId = _pointer(adv['_canvasGroup']);
    final groupNode =
        transformOfGame[_pointer(
          _map(records[groupId]!['data'])['m_GameObject'],
        )]!;
    if (_pointer(adv['_screenPadding']) != '0') {
      throw UnsupportedError('frame_screen_padding:$ref');
    }
    final animator = packet['animator'] == null
        ? null
        : _map(_map(packet['animator'])['data']);
    final animatorNode = animator == null
        ? null
        : transformOfGame[_pointer(animator['m_GameObject'])];
    final unsupported = <String>[];
    final scriptRecords = _map(packet['resolvedScripts']);
    for (final record in records.values.where(
      (r) => r['type'] == 'MonoBehaviour',
    )) {
      final raw = _map(record['data']);
      if (raw['m_Enabled'] != 1 && raw['m_Enabled'] != true) continue;
      final pointer = _map(raw['m_Script']);
      final reference = _map(pointer['reference']);
      final scriptRecord = _map(scriptRecords[reference['pathId']]);
      final script = _map(scriptRecord['data']);
      final name = reference['name'];
      final identity = switch (name) {
        'AdvFrame' => ('AdvSystem.Asset.UI', 'AdvAsset'),
        'Image' ||
        'AspectRatioFitter' ||
        'HorizontalLayoutGroup' => ('UnityEngine.UI', 'UnityEngine.UI'),
        'StretchPosition' => ('', 'AdvAsset'),
        'UIParticle' when particleSource != null => (
          'Coffee.UIExtensions',
          'Coffee.UIParticle',
        ),
        _ => null,
      };
      if (identity == null) {
        unsupported.add('frame_enabled_component:$name');
      } else if (scriptRecord['serializedFile'] !=
              reference['serializedFile'] ||
          scriptRecord['pathId'] != reference['pathId'] ||
          script['m_ClassName'] != name ||
          script['m_Namespace'] != identity.$1 ||
          script['m_AssemblyName'] != identity.$2) {
        throw const FormatException('frame_component_script_identity');
      }
    }
    if (animator != null &&
        (animator['m_UpdateMode'] != 0 ||
            animator['m_CullingMode'] != 0 ||
            animator['m_ApplyRootMotion'] == true)) {
      unsupported.add('frame_animator_mode');
    }
    final sprites = _map(packet['sprites']),
        materials = _map(packet['materials']),
        outputs = _map(packet['resourceOutputs']);
    String resourceKey(Map pointer) {
      final reference = pointer['reference'] as Map;
      return '${reference['serializedFile']}:${reference['pathId']}';
    }

    final nodes = <StoryFrameNodeData>[], seen = <String>{};
    void visit(String id, String? parent, String prefixPath) {
      if (!seen.add(id)) throw const FormatException('frame_hierarchy_cycle');
      final tr = transforms[id]!;
      final go = records[_pointer(tr['m_GameObject'])]!;
      final gd = _map(go['data']), name = gd['m_Name'] as String;
      final path = prefixPath.isEmpty ? name : '$prefixPath/$name';
      final componentIds = (gd['m_Component'] as List).map(
        (v) => _pointer((v as Map)['component']),
      );
      final components = [
        for (final cid in componentIds)
          if (records[cid] != null &&
              (particleSource == null ||
                  !const {
                    'ParticleSystem',
                    'ParticleSystemRenderer',
                  }.contains(records[cid]!['type'])))
            records[cid]!,
      ];
      final imageRecord = components
          .where((c) => _script(c) == 'Image')
          .firstOrNull;
      StoryFrameImageData? image;
      if (imageRecord != null) {
        final raw = _map(imageRecord['data']),
            spritePointer = _map(raw['m_Sprite']),
            materialPointer = _map(raw['m_Material']);
        Map<String, Object?>? sprite, material, shader;
        String? texture, textureHash;
        if (_pointer(spritePointer) != '0') {
          final key = resourceKey(spritePointer);
          sprite = _map(_map(sprites[key])['data']);
          final candidates = (outputs[key] as List)
              .cast<Map>()
              .where(
                (o) =>
                    o['type'] == 'Sprite' &&
                    (o['path'] as String).endsWith('.png'),
              )
              .toList();
          if (candidates.length != 1) {
            throw UnsupportedError('frame_sprite_output:$ref:$key');
          }
          final output = candidates.single;
          texture =
              '/runtime/intl/${(output['path'] as String).substring('runtime/'.length)}';
          textureHash = output['sha256'] as String;
        }
        if (_pointer(materialPointer) != '0') {
          final key = resourceKey(materialPointer);
          material = _map(_map(materials[key])['data']);
          shader = actualShaderMetadata[key];
          if (shader == null) unsupported.add('frame_shader_metadata:$key');
          if (shader != null) {
            final original = _map(_map(material['m_Shader'])['reference']);
            if (shader['serializedFile'] != original['serializedFile'] ||
                shader['pathId'] != original['pathId'] ||
                shader['name'] != original['name']) {
              throw const FormatException('frame_shader_source_identity');
            }
          }
        }
        image = StoryFrameImageData(
          objectId: imageRecord['pathId'].toString(),
          raw: Map.unmodifiable(raw),
          spriteRaw: sprite == null ? null : Map.unmodifiable(sprite),
          texture: texture,
          textureHash: textureHash,
          materialRaw: material == null ? null : Map.unmodifiable(material),
          shaderMetadata: shader,
        );
      }
      final cg = components
          .where((c) => c['type'] == 'CanvasGroup')
          .firstOrNull;
      final position = _vector(tr['m_AnchoredPosition'], const ['x', 'y']);
      final local = _vector(tr['m_LocalPosition'], const ['x', 'y', 'z']);
      final pose = StoryFramePose(
        position: [...position, local[2]],
        localPosition: local,
        size: _vector(tr['m_SizeDelta'], const ['x', 'y']),
        scale: _vector(tr['m_LocalScale'], const ['x', 'y', 'z']),
        rotation: _vector(tr['m_LocalRotation'], const ['x', 'y', 'z', 'w']),
        opacity: cg == null ? 1 : _number(_map(cg['data'])['m_Alpha']),
        active: gd['m_IsActive'] == true || gd['m_IsActive'] == 1,
        imageColor: image?.color,
        stretchPositionPercent:
            components
                    .where((c) => _script(c) == 'StretchPosition')
                    .firstOrNull ==
                null
            ? null
            : _number(
                _map(
                  components.firstWhere(
                    (c) => _script(c) == 'StretchPosition',
                  )['data'],
                )['positionPercent'],
              ),
      );
      nodes.add(
        StoryFrameNodeData(
          id: id,
          gameObjectId: go['pathId'].toString(),
          path: path,
          parent: parent,
          rawTransform: Map.unmodifiable(tr),
          initial: pose,
          image: image,
          components: List.unmodifiable(components),
        ),
      );
      for (final child in (tr['m_Children'] as List)) {
        visit(_pointer(child), id, path);
      }
    }

    visit(root, null, '');
    final states = <String, StoryFrameStateData>{};
    String? defaultState;
    if (animator != null) {
      final pathToNode = <int, String>{};
      final byId = {for (final n in nodes) n.id: n};
      final ar = byId[animatorNode]!;
      for (final node in nodes.where(
        (n) => n.path == ar.path || n.path.startsWith('${ar.path}/'),
      )) {
        final relative = node.id == ar.id
            ? ''
            : node.path.substring(ar.path.length + 1);
        final code = nativeEffectPathHash(relative);
        if (pathToNode.containsKey(code)) {
          throw const FormatException('frame_animation_path_collision');
        }
        pathToNode[code] = node.id;
      }
      final clips = <StoryFrameClipData>[];
      for (final item in (packet['clips'] as List).cast<Map>()) {
        final record = _map(item['object']), raw = _map(record['data']);
        final clip = NativeAuthoredAnimationClip(raw);
        final bindings = <_Binding>[];
        var cursor = 0;
        if ((raw['m_Events'] as List).isNotEmpty) {
          unsupported.add('frame_animation_events:${record['pathId']}');
        }
        for (final b in clip.bindings) {
          final type = (b['typeID'] as num).toInt(),
              attr = (b['attribute'] as num).toInt();
          final node = pathToNode[(b['path'] as num).toInt()];
          final property = switch ((type, attr)) {
            (4, 1) => StoryFrameProperty.position,
            (4, 2) => StoryFrameProperty.rotation,
            (4, 3) => StoryFrameProperty.scale,
            (224, 1460864421) => StoryFrameProperty.anchoredX,
            (224, 538195251) => StoryFrameProperty.anchoredY,
            (224, 1967290853) => StoryFrameProperty.sizeX,
            (224, 38095219) => StoryFrameProperty.sizeY,
            (225, 1574349066) => StoryFrameProperty.opacity,
            (1, 2086281974) => StoryFrameProperty.active,
            (114, 2526845255) => StoryFrameProperty.imageR,
            (114, 4215373228) => StoryFrameProperty.imageG,
            (114, 2334886179) => StoryFrameProperty.imageB,
            (114, 304273561) => StoryFrameProperty.imageA,
            (114, 2950049963) => StoryFrameProperty.stretchPositionPercent,
            _ => throw UnsupportedError(
              'frame_animation_binding:$ref:$type:$attr',
            ),
          };
          if (node == null || b['isPPtrCurve'] != 0) {
            throw UnsupportedError('frame_animation_target:$ref:${b['path']}');
          }
          if (property == StoryFrameProperty.stretchPositionPercent) {
            final script = _map(_map(b['script'])['reference']);
            final components = byId[node]!.components.where(
              (c) => _script(c) == 'StretchPosition',
            );
            if (components.length != 1 ||
                script['name'] != 'StretchPosition' ||
                script['serializedFile'] !=
                    'CAB-26bec939c462ea1051f1dd59d8bb943a' ||
                script['pathId'] != '6366304539093746799') {
              throw UnsupportedError('frame_stretch_binding_identity');
            }
          }
          final count =
              property == StoryFrameProperty.position ||
                  property == StoryFrameProperty.scale
              ? 3
              : property == StoryFrameProperty.rotation
              ? 4
              : 1;
          bindings.add(_Binding(node, property, cursor, count));
          cursor += count;
        }
        if (cursor != clip.curveCount) {
          throw const FormatException('frame_animation_curve_count');
        }
        clips.add(
          StoryFrameClipData(
            record['pathId'].toString(),
            Map.unmodifiable(raw),
            clip,
            List.unmodifiable(bindings),
          ),
        );
      }
      final controller = _map(_map(packet['controller'])['data']);
      final ctl = _map(controller['m_Controller']),
          layers = ctl['m_LayerArray'] as List;
      if (layers.length != 1) {
        throw UnsupportedError('frame_animator_layers:$ref');
      }
      final machines = ctl['m_StateMachineArray'] as List;
      final machine = _map(
        _map(
          machines[(_map(_map(layers.single)['data'])['m_StateMachineIndex']
                  as num)
              .toInt()],
        )['data'],
      );
      if ((machine['m_AnyStateTransitionConstantArray'] as List).isNotEmpty) {
        throw UnsupportedError('frame_animator_any_transition:$ref');
      }
      final originals = (machine['m_StateConstantArray'] as List)
          .map((s) => _map(_map(s)['data']))
          .toList();
      final names = {
        for (final pair in (controller['m_TOS'] as List))
          (pair as List)[0]: (pair)[1] as String,
      };
      final stateNames = [for (final s in originals) names[s['m_NameID']]!];
      for (var index = 0; index < originals.length; index++) {
        final s = originals[index],
            trees = s['m_BlendTreeConstantArray'] as List;
        if (s['m_SpeedParamID'] != 0 ||
            s['m_TimeParamID'] != 0 ||
            s['m_Mirror'] == true ||
            _number(s['m_CycleOffset']) != 0) {
          throw UnsupportedError('frame_animator_state_options:$ref');
        }
        StoryFrameClipData? clip;
        if (trees.isNotEmpty) {
          final tree = _map(_map(trees.single)['data']),
              array = tree['m_NodeArray'] as List;
          if (array.length != 1 ||
              (_map(_map(array.single)['data'])['m_ChildIndices'] as List)
                  .isNotEmpty) {
            throw UnsupportedError('frame_animator_blendtree:$ref');
          }
          clip =
              clips[(_map(_map(array.single)['data'])['m_ClipID'] as num)
                  .toInt()];
        }
        final transitions = <StoryFrameTransitionData>[];
        for (final transition in (s['m_TransitionConstantArray'] as List)) {
          final tr = _map(_map(transition)['data']);
          if (tr['m_HasExitTime'] != true ||
              (tr['m_ConditionConstantArray'] as List).isNotEmpty ||
              _number(tr['m_TransitionDuration']) != 0) {
            throw UnsupportedError('frame_animator_transition:$ref');
          }
          transitions.add(
            StoryFrameTransitionData(
              stateNames[(tr['m_DestinationState'] as num).toInt()],
              _number(tr['m_ExitTime']),
              _number(tr['m_TransitionOffset']),
            ),
          );
        }
        states[stateNames[index]] = StoryFrameStateData(
          name: stateNames[index],
          speed: _number(s['m_Speed']),
          clip: clip,
          writeDefaults: s['m_WriteDefaultValues'] == true,
          transitions: List.unmodifiable(transitions),
        );
      }
      defaultState = stateNames[(machine['m_DefaultState'] as num).toInt()];
    }
    return StoryFrameSource._(
      ref,
      sourcePath,
      hash,
      root,
      groupNode,
      animatorNode,
      animator != null &&
          (animator['m_Enabled'] == true || animator['m_Enabled'] == 1),
      List.unmodifiable(nodes),
      Map.unmodifiable(states),
      defaultState,
      List.unmodifiable(unsupported),
      particleSource,
    );
  }

  Map<String, StoryFramePose> sample(
    StoryFrameStateData state,
    double seconds,
    Map<String, StoryFramePose> current,
  ) {
    final poses = Map<String, StoryFramePose>.of(current);
    if (state.writeDefaults) {
      for (final s in states.values) {
        for (final b in s.clip?._bindings ?? const <_Binding>[]) {
          poses[b.node] = poses[b.node]!.set(
            b.property,
            initialPoses[b.node]!.values(b.property),
          );
        }
      }
    }
    final clip = state.clip;
    if (clip != null) {
      final values = clip.clip.sampleAt(seconds, loop: clip.loop);
      for (final binding in clip._bindings) {
        poses[binding.node] = poses[binding.node]!.set(
          binding.property,
          values.sublist(binding.start, binding.start + binding.count),
        );
      }
    }
    return Map.unmodifiable(poses);
  }
}
