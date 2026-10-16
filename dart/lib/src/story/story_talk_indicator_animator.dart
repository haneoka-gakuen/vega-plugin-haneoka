import 'dart:math' as math;
import 'dart:typed_data';

import 'package:haneoka_render_profile/core.dart';

import 'story_scene_state.dart';

Map<String, Object?> _map(Object? value) =>
    Map<String, Object?>.from(value as Map);
double _number(Object? value) => value is num && value.isFinite
    ? value.toDouble()
    : throw const FormatException('talk_indicator_number');
bool _flag(Object? value) => switch (value) {
  true || 1 => true,
  false || 0 => false,
  _ => throw const FormatException('talk_indicator_flag'),
};
String _id(Object? pointer) => _map(pointer)['m_PathID'].toString();
final _slot = Float32List(1);
double _f(double value) {
  _slot[0] = value;
  return _slot[0];
}

List<double> _vector(Object? value, List<String> keys) {
  final raw = _map(value);
  return List.unmodifiable([for (final key in keys) _number(raw[key])]);
}

/// Default Transform.localEulerAngles setter -> Quaternion.Euler: ZXY.
/// The clip carries Euler property curves, not a serialized rotation order.
/// Input is three authored degree curves; output is [x,y,z,w] for local TRS.
List<double> _zxyQuaternion(List<double> degrees) {
  final x = degrees[0] * math.pi / 360,
      y = degrees[1] * math.pi / 360,
      z = degrees[2] * math.pi / 360;
  final sx = math.sin(x),
      cx = math.cos(x),
      sy = math.sin(y),
      cy = math.cos(y),
      sz = math.sin(z),
      cz = math.cos(z);
  return List.unmodifiable([
    _f(cy * sx * cz + sy * cx * sz),
    _f(sy * cx * cz - cy * sx * sz),
    _f(cy * cx * sz - sy * sx * cz),
    _f(cy * cx * cz + sy * sx * sz),
  ]);
}

enum StoryTalkIndicatorProperty { anchoredY, eulerXYZ }

bool _hasExplicitRotationOrder(Object? value) {
  if (value is Map) {
    for (final entry in value.entries) {
      if ((entry.key as String).toLowerCase().contains('rotationorder') ||
          _hasExplicitRotationOrder(entry.value)) {
        return true;
      }
    }
  } else if (value is List) {
    for (final item in value) {
      if (_hasExplicitRotationOrder(item)) return true;
    }
  }
  return false;
}

final class StoryTalkIndicatorPose {
  StoryTalkIndicatorPose({
    required this.transformId,
    required this.anchoredY,
    required List<double>? eulerDegrees,
    required List<double>? localRotationQuaternion,
  }) : eulerDegrees = eulerDegrees == null
           ? null
           : List.unmodifiable(eulerDegrees),
       localRotationQuaternion = localRotationQuaternion == null
           ? null
           : List.unmodifiable(localRotationQuaternion);
  final String transformId;

  /// Only animated channels are present; null preserves the host's driven TRS.
  final double? anchoredY;
  final List<double>? eulerDegrees, localRotationQuaternion;
}

/// The selected original Default Next/Auto controllers have one layer, one
/// default Loop state and one rooted binding. Other controller recipes refuse.
final class StoryTalkIndicatorAnimatorSource {
  StoryTalkIndicatorAnimatorSource._(
    this.mode,
    this.field,
    this.rootGameObjectId,
    this.rootTransformId,
    this.rootHierarchyPath,
    this.stateName,
    this.stateSpeed,
    this.writeDefaults,
    this.keepStateOnDisable,
    this.initialPose,
    this.property,
    this.clip,
    this.loop,
    this.controllerIdentity,
    this.clipIdentity,
    this.originalNodeTree,
  );
  final String mode,
      field,
      rootGameObjectId,
      rootTransformId,
      rootHierarchyPath,
      stateName;
  final String controllerIdentity, clipIdentity;
  final double stateSpeed;
  final bool writeDefaults, keepStateOnDisable, loop;
  final StoryTalkIndicatorPose initialPose;
  final StoryTalkIndicatorProperty property;
  final NativeAuthoredAnimationClip clip;
  final List<Map<String, Object?>> originalNodeTree;
  double get duration => clip.duration;
  String get key => '$mode:$field';
  static StoryTalkIndicatorAnimatorSource? fromRaw(
    String mode,
    String field,
    Map<String, Object?> actualReference,
    Map<String, Object?> actualContract,
  ) {
    if (!const [
      '_talkNextIndicator',
      '_autoIcon',
      '_fastIcon',
    ].contains(field)) {
      throw UnsupportedError('talk_indicator_field:$field');
    }
    final pointer = _map(actualReference['pointer']);
    final animators = (actualContract['animators'] as List).cast<Map>();
    if (_id(pointer) == '0') {
      if (actualReference['endpoint'] != null ||
          animators.isNotEmpty ||
          (actualContract['originalNodeTree'] as List).isNotEmpty) {
        throw const FormatException('talk_indicator_null_reference');
      }
      return null;
    }
    if (animators.isEmpty) return null;
    if (animators.length != 1 || field == '_fastIcon') {
      throw UnsupportedError('talk_indicator_animator_count');
    }
    final endpoint = _map(actualReference['endpoint']),
        boundObject = _map(endpoint['object']);
    final tree = (actualContract['originalNodeTree'] as List)
        .map((value) => _map(value))
        .toList();
    final a = _map(animators.single['animator']), ar = _map(a['data']);
    if (boundObject['type'] != 'GameObject' ||
        boundObject['pathId'] != _id(pointer) ||
        _id(ar['m_GameObject']) != boundObject['pathId'] ||
        !_flag(ar['m_Enabled']) ||
        ar['m_UpdateMode'] != 0 ||
        ar['m_CullingMode'] != 0 ||
        _flag(ar['m_ApplyRootMotion']) ||
        _flag(ar['m_KeepAnimatorStateOnDisable']) ||
        _flag(ar['m_WriteDefaultValuesOnDisable'])) {
      throw UnsupportedError('talk_indicator_animator_recipe');
    }
    final rootNodes = tree
        .where(
          (node) =>
              _map(node['gameObject'])['pathId'] == _id(ar['m_GameObject']),
        )
        .toList();
    if (rootNodes.length != 1) {
      throw const FormatException('talk_indicator_root_node');
    }
    final transform = _map(rootNodes.single['transform']),
        tr = _map(transform['data']);
    final controller = _map(animators.single['controller']),
        co = _map(controller['data']);
    final controllerPointer = _map(ar['m_Controller']),
        controllerReference = _map(controllerPointer['reference']);
    if (controller['type'] != 'AnimatorController' ||
        controller['pathId'] != _id(controllerPointer) ||
        controller['serializedFile'] != controllerReference['serializedFile']) {
      throw const FormatException('talk_indicator_controller_identity');
    }
    final data = _map(co['m_Controller']),
        layers = data['m_LayerArray'] as List,
        machines = data['m_StateMachineArray'] as List;
    if (layers.length != 1 ||
        machines.length != 1 ||
        _map(_map(layers.single)['data'])['m_StateMachineIndex'] != 0) {
      throw UnsupportedError('talk_indicator_layers');
    }
    final machine = _map(_map(machines.single)['data']),
        states = machine['m_StateConstantArray'] as List;
    if (states.length != 1 ||
        machine['m_DefaultState'] != 0 ||
        (machine['m_AnyStateTransitionConstantArray'] as List).isNotEmpty) {
      throw UnsupportedError('talk_indicator_states');
    }
    final state = _map(_map(states.single)['data']);
    if ((state['m_TransitionConstantArray'] as List).isNotEmpty ||
        state['m_SpeedParamID'] != 0 ||
        state['m_TimeParamID'] != 0 ||
        state['m_CycleOffsetParamID'] != 0 ||
        state['m_MirrorParamID'] != 0 ||
        _number(state['m_CycleOffset']) != 0 ||
        _flag(state['m_Mirror'])) {
      throw UnsupportedError('talk_indicator_state_options');
    }
    final trees = state['m_BlendTreeConstantArray'] as List;
    if (trees.length != 1) throw UnsupportedError('talk_indicator_blendtree');
    final leaves = _map(_map(trees.single)['data'])['m_NodeArray'] as List;
    if (leaves.length != 1 ||
        _map(_map(leaves.single)['data'])['m_ClipID'] != 0 ||
        (_map(_map(leaves.single)['data'])['m_ChildIndices'] as List)
            .isNotEmpty) {
      throw UnsupportedError('talk_indicator_clip_leaf');
    }
    final clips = (animators.single['clips'] as List).cast<Map>(),
        controllerClips = co['m_AnimationClips'] as List;
    if (clips.length != 1 || controllerClips.length != 1) {
      throw UnsupportedError('talk_indicator_clip_count');
    }
    final clipRecord = _map(clips.single['object']),
        rawClip = _map(clipRecord['data']);
    final clipPointer = _map(controllerClips.single),
        clipReference = _map(clipPointer['reference']);
    if (clipRecord['type'] != 'AnimationClip' ||
        clipRecord['pathId'] != _id(clipPointer) ||
        clipRecord['serializedFile'] != clipReference['serializedFile']) {
      throw const FormatException('talk_indicator_clip_identity');
    }
    if ((rawClip['m_Events'] as List).isNotEmpty) {
      throw UnsupportedError('talk_indicator_clip_events');
    }
    final clip = NativeAuthoredAnimationClip(rawClip), bindings = clip.bindings;
    if (bindings.length != 1) throw UnsupportedError('talk_indicator_bindings');
    final binding = bindings.single;
    if (binding['path'] != 0 ||
        binding['isPPtrCurve'] != 0 ||
        binding['isIntCurve'] != 0 ||
        binding['isSerializeReferenceCurve'] != 0 ||
        _id(binding['script']) != '0') {
      throw UnsupportedError('talk_indicator_binding_target');
    }
    final property = switch ((
      binding['typeID'],
      binding['attribute'],
      binding['customType'],
    )) {
      (224, 538195251, 28) => StoryTalkIndicatorProperty.anchoredY,
      (4, 4, 4) => StoryTalkIndicatorProperty.eulerXYZ,
      _ => throw UnsupportedError('talk_indicator_binding_property'),
    };
    if (property == StoryTalkIndicatorProperty.eulerXYZ &&
        (_hasExplicitRotationOrder(rawClip) ||
            (rawClip['m_EulerCurves'] as List).isNotEmpty ||
            (rawClip['m_RotationCurves'] as List).isNotEmpty ||
            (rawClip['m_CompressedRotationCurves'] as List).isNotEmpty)) {
      throw UnsupportedError(
        'talk_indicator_alternative_rotation_representation',
      );
    }
    if ((field == '_talkNextIndicator') !=
            (property == StoryTalkIndicatorProperty.anchoredY) ||
        clip.curveCount !=
            (property == StoryTalkIndicatorProperty.anchoredY ? 1 : 3)) {
      throw const FormatException('talk_indicator_curve_count');
    }
    final names = {
      for (final pair in co['m_TOS'] as List)
        (pair as List)[0]: pair[1] as String,
    };
    final stateName = names[state['m_NameID']];
    if (stateName != 'Loop') {
      throw UnsupportedError('talk_indicator_default_state');
    }
    final loop = _flag(_map(rawClip['m_MuscleClip'])['m_LoopTime']);
    if (!loop || clip.duration <= 0) {
      throw UnsupportedError('talk_indicator_loop');
    }
    final rotation = _vector(tr['m_LocalRotation'], ['x', 'y', 'z', 'w']);
    if (rotation[0] != 0 ||
        rotation[1] != 0 ||
        rotation[2] != 0 ||
        rotation[3] != 1) {
      throw UnsupportedError('talk_indicator_initial_euler_recipe');
    }
    final initial = StoryTalkIndicatorPose(
      transformId: transform['pathId'] as String,
      anchoredY: property == StoryTalkIndicatorProperty.anchoredY
          ? _number(_map(tr['m_AnchoredPosition'])['y'])
          : null,
      eulerDegrees: property == StoryTalkIndicatorProperty.eulerXYZ
          ? const [0, 0, 0]
          : null,
      localRotationQuaternion: property == StoryTalkIndicatorProperty.eulerXYZ
          ? rotation
          : null,
    );
    return StoryTalkIndicatorAnimatorSource._(
      mode,
      field,
      boundObject['pathId'] as String,
      transform['pathId'] as String,
      endpoint['hierarchyPath'] as String,
      stateName!,
      _number(state['m_Speed']),
      _flag(state['m_WriteDefaultValues']),
      _flag(ar['m_KeepAnimatorStateOnDisable']),
      initial,
      property,
      clip,
      loop,
      '${controller['serializedFile']}:${controller['pathId']}',
      '${clipRecord['serializedFile']}:${clipRecord['pathId']}',
      List.unmodifiable(tree),
    );
  }

  StoryTalkIndicatorPose sample(double seconds) {
    final values = clip.sampleAt(seconds, loop: loop);
    if (property == StoryTalkIndicatorProperty.anchoredY) {
      return StoryTalkIndicatorPose(
        transformId: rootTransformId,
        anchoredY: values.single,
        eulerDegrees: initialPose.eulerDegrees,
        localRotationQuaternion: initialPose.localRotationQuaternion,
      );
    }
    final euler = List<double>.of(values);
    return StoryTalkIndicatorPose(
      transformId: rootTransformId,
      anchoredY: initialPose.anchoredY,
      eulerDegrees: euler,
      localRotationQuaternion: _zxyQuaternion(euler),
    );
  }
}

final class StoryTalkIndicatorFrame {
  StoryTalkIndicatorFrame._(
    this.source,
    this.actualUIUpdateUs,
    this.actualUpdateIndex,
    this.activeHierarchy,
    this.stateSeconds,
    this.pose,
  );
  final StoryTalkIndicatorAnimatorSource source;
  final int actualUIUpdateUs, actualUpdateIndex;
  final bool activeHierarchy;
  final double stateSeconds;
  final StoryTalkIndicatorPose pose;
  double get normalizedTime => stateSeconds / source.duration;
  double get clipPhaseSeconds => stateSeconds % source.duration;
  Map<String, StoryTalkIndicatorPose> get poseOverrides =>
      Map.unmodifiable({source.rootTransformId: pose});
}

final class StoryTalkIndicatorSnapshot {
  StoryTalkIndicatorSnapshot._(
    this.identity,
    this.epoch,
    this.key,
    this.controller,
    this.clip,
    this.us,
    this.index,
    this.active,
    this.seconds,
    this.pose,
  );
  final StorySourceIdentity identity;
  final int epoch, us, index;
  final String key, controller, clip;
  final bool active;
  final double seconds;
  final StoryTalkIndicatorPose pose;
  Map<String, Object?> toData() => {
    'version': 1,
    'source': identity.toJson(),
    'key': key,
    'controller': controller,
    'clip': clip,
    'us': us,
    'index': index,
    'active': active,
    'seconds': seconds,
    'pose': {
      'transformId': pose.transformId,
      'anchoredY': pose.anchoredY,
      'euler': pose.eulerDegrees,
      'quaternion': pose.localRotationQuaternion,
    },
  };
}

/// Receives the same actual latched UI Update pair as visibility. The host
/// supplies effective hierarchy activation, including window/TalkArea/icon.
/// OnEnable resets time only; the next real animation Update advances before
/// sampling. Original state speed is independent of locale/playback rate.
final class StoryTalkIndicatorAnimator {
  StoryTalkIndicatorAnimator({
    required this.source,
    required this.sourceIdentity,
    required this.sourceEpoch,
    required int actualUIUpdateUs,
    required int actualUpdateIndex,
  }) : _us = actualUIUpdateUs,
       _index = actualUpdateIndex,
       _pose = source.initialPose {
    if (sourceEpoch < 0 || actualUIUpdateUs < 0 || actualUpdateIndex < 0) {
      throw const FormatException('talk_indicator_clock_input');
    }
  }
  final StoryTalkIndicatorAnimatorSource source;
  final StorySourceIdentity sourceIdentity;
  final int sourceEpoch;
  int _us, _index;
  double _seconds = 0;
  bool _active = false, _closed = false;
  StoryTalkIndicatorPose _pose;
  void _open() {
    if (_closed) throw StateError('talk_indicator_closed');
  }

  StoryTalkIndicatorFrame get frame =>
      StoryTalkIndicatorFrame._(source, _us, _index, _active, _seconds, _pose);
  void setHierarchyActive(bool effectiveActive) {
    _open();
    if (effectiveActive == _active) return;
    _active = effectiveActive;
    if (effectiveActive && !source.keepStateOnDisable) _seconds = 0;
  }

  StoryTalkIndicatorFrame update(
    int actualUIUpdateUs, {
    required int actualUpdateIndex,
    required bool paused,
    required int epoch,
  }) {
    _open();
    if (epoch != sourceEpoch) {
      close();
      throw StateError('talk_indicator_epoch');
    }
    if (actualUIUpdateUs < _us || actualUpdateIndex < _index) {
      throw const FormatException('talk_indicator_clock_reversed');
    }
    if (actualUpdateIndex == _index) {
      if (actualUIUpdateUs != _us) {
        throw const FormatException('talk_indicator_unlatched_clock');
      }
      return frame;
    }
    final dt = _f((actualUIUpdateUs - _us) / 1000000);
    _us = actualUIUpdateUs;
    _index = actualUpdateIndex;
    if (!paused && _active) {
      _seconds = _f(_seconds + _f(dt * source.stateSpeed));
      _pose = source.sample(_seconds);
    }
    return frame;
  }

  StoryTalkIndicatorSnapshot snapshot() => StoryTalkIndicatorSnapshot._(
    sourceIdentity,
    sourceEpoch,
    source.key,
    source.controllerIdentity,
    source.clipIdentity,
    _us,
    _index,
    _active,
    _seconds,
    _pose,
  );
  void restore(StoryTalkIndicatorSnapshot snapshot) {
    _open();
    if (snapshot.identity != sourceIdentity ||
        snapshot.epoch != sourceEpoch ||
        snapshot.key != source.key ||
        snapshot.controller != source.controllerIdentity ||
        snapshot.clip != source.clipIdentity) {
      throw const FormatException('talk_indicator_snapshot_source');
    }
    _us = snapshot.us;
    _index = snapshot.index;
    _active = snapshot.active;
    _seconds = snapshot.seconds;
    _pose = snapshot.pose;
  }

  Map<String, Object?> snapshotData() => snapshot().toData();
  void restoreData(
    Map data, {
    required int actualUIUpdateUs,
    required int actualUpdateIndex,
  }) {
    if (data['version'] != 1 ||
        StorySourceIdentity.fromJson(data['source'] as Map) != sourceIdentity ||
        data['key'] != source.key ||
        data['controller'] != source.controllerIdentity ||
        data['clip'] != source.clipIdentity ||
        actualUIUpdateUs < 0 ||
        actualUpdateIndex < 0) {
      throw const FormatException('talk_indicator_data_source');
    }
    final pose = data['pose'] as Map;
    List<double>? vector(Object? value, int length) {
      if (value == null) {
        return null;
      }
      final result = [for (final v in value as List) _number(v)];
      if (result.length != length) {
        throw const FormatException('talk_indicator_data_pose');
      }
      return result;
    }

    if (pose['transformId'] != source.rootTransformId) {
      throw const FormatException('talk_indicator_data_pose');
    }
    restore(
      StoryTalkIndicatorSnapshot._(
        sourceIdentity,
        sourceEpoch,
        source.key,
        source.controllerIdentity,
        source.clipIdentity,
        actualUIUpdateUs,
        actualUpdateIndex,
        data['active'] as bool,
        _number(data['seconds']),
        StoryTalkIndicatorPose(
          transformId: pose['transformId'] as String,
          anchoredY: pose['anchoredY'] == null
              ? null
              : _number(pose['anchoredY']),
          eulerDegrees: vector(pose['euler'], 3),
          localRotationQuaternion: vector(pose['quaternion'], 4),
        ),
      ),
    );
  }

  void close() {
    _closed = true;
  }
}
