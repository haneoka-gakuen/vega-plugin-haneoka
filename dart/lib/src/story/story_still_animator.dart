import 'dart:math' as math;
import 'dart:typed_data';

import 'package:haneoka_render_profile/core.dart';

import 'story_still_external_layout.dart';

enum _Property { position, scale, size, worldRotation, color, opacity }

final class StoryStillPose {
  StoryStillPose({
    required List<double> position,
    required List<double> scale,
    required List<double> size,
    required List<double> rotation,
    required this.opacity,
    List<double>? color,
  }) : position = List.unmodifiable(position),
       scale = List.unmodifiable(scale),
       size = List.unmodifiable(size),
       rotation = List.unmodifiable(rotation),
       color = color == null ? null : List.unmodifiable(color);
  final List<double> position, scale, size, rotation;
  final List<double>? color;
  final double opacity;
  Map<String, Object?> toData() => {
    'position': position,
    'scale': scale,
    'size': size,
    'rotation': rotation,
    'opacity': opacity,
    'color': color,
  };
  factory StoryStillPose.fromData(Map data) => StoryStillPose(
    position: _savedVector(data['position'], 3),
    scale: _savedVector(data['scale'], 3),
    size: _savedVector(data['size'], 2),
    rotation: _savedVector(data['rotation'], 4),
    opacity: _n(data['opacity']),
    color: data['color'] == null ? null : _savedVector(data['color'], 4),
  );
  StoryStillPose _withValue(_Property property, List<double> value) =>
      StoryStillPose(
        position: property == _Property.position ? value : position,
        scale: property == _Property.scale ? value : scale,
        size: property == _Property.size ? value : size,
        rotation: property == _Property.worldRotation ? value : rotation,
        opacity: property == _Property.opacity ? value.single : opacity,
        color: property == _Property.color ? value : color,
      );
}

final class _Track {
  const _Track(
    this.node,
    this.property,
    this.at,
    this.duration,
    this.iterations,
    this.yoyo,
    this.ease,
    this.start,
    this.end, [
    this.path,
  ]);
  final String node;
  final _Property property;
  final double at, duration;
  final int iterations, ease;
  final bool yoyo;
  final List<double> start, end;
  final StoryStillWaypointPath? path;
}

typedef StoryStillWaypointPath = AuthoredWaypointPath;

/// A mathematical waypoint specification, not an imported DOTween program.
StoryStillWaypointPath _punch(
  List<double> direction,
  double duration,
  int vibrato,
  double elasticity,
) {
  final count = math.max(2, (vibrato * duration).truncate()),
      elastic = elasticity.clamp(0, 1);
  final points = <List<double>>[], times = <double>[];
  for (var point = 0; point < count; point++) {
    final amplitude = point == count - 1
        ? 0.0
        : (1 - point / count) * (point.isOdd ? -elastic : 1);
    points.add(direction.map((value) => value * amplitude).toList());
    times.add((point + 1) * (point + 2) / (count * (count + 1)));
  }
  return StoryStillWaypointPath(points, times, 6);
}

StoryStillWaypointPath _shake(
  double strength,
  double duration,
  int vibrato,
  double randomness,
  bool fade,
  math.Random random,
) => createAuthoredShakePath(
  strength: strength,
  duration: duration,
  vibrato: vibrato,
  randomness: randomness,
  fadeOut: fade,
  vectorBased: true,
  randomUnit: random.nextDouble,
);

final class StoryStillSnapshot {
  const StoryStillSnapshot(
    this.sourcePath,
    this.sourceHash,
    this.sequence,
    this.elapsed,
    this.base,
    this.paths,
    this.current,
    this.attachment,
    this.sampledElapsed,
    this.rootPositionStarts, [
    this.programs,
  ]);
  final String sourcePath, sourceHash;
  final String? sequence;
  final double elapsed;
  final Map<String, StoryStillPose> base;
  final Map<int, StoryStillWaypointPath> paths;
  final Map<String, StoryStillPose> current;
  final StoryStillAttachmentSnapshot attachment;
  final double? sampledElapsed;
  final Map<int, List<double>> rootPositionStarts;
  final List<Map<String, Object?>>? programs;
  Map<String, Object?> toData() => {
    'version': 1,
    if (programs != null) 'programs': programs,
    'sourcePath': sourcePath,
    'sourceHash': sourceHash,
    'sequence': sequence,
    'elapsed': elapsed,
    'base': {for (final e in base.entries) e.key: e.value.toData()},
    'current': {for (final e in current.entries) e.key: e.value.toData()},
    'paths': {for (final e in paths.entries) '${e.key}': e.value.toData()},
    'attachment': {
      'revision': attachment.revision,
      'consumed': attachment.consumedRevision,
      'parentId': attachment.parentId,
      'packetHash': attachment.packetHash,
      'pending': attachment.pending,
      'drivenAnchored': attachment.drivenAnchored,
    },
    'sampledElapsed': sampledElapsed,
    'rootStarts': {
      for (final e in rootPositionStarts.entries) '${e.key}': e.value,
    },
  };
  factory StoryStillSnapshot.fromData(Map data) {
    if (data['version'] != 1) {
      throw const FormatException('still_data_version');
    }
    final attachment = data['attachment'] as Map;
    return StoryStillSnapshot(
      data['sourcePath'] as String,
      data['sourceHash'] as String,
      data['sequence'] as String?,
      _n(data['elapsed']),
      {
        for (final e in (data['base'] as Map).entries)
          e.key as String: StoryStillPose.fromData(e.value as Map),
      },
      {
        for (final e in (data['paths'] as Map).entries)
          int.parse(e.key as String): AuthoredWaypointPath.fromData(
            e.value as Map,
          ),
      },
      {
        for (final e in (data['current'] as Map).entries)
          e.key as String: StoryStillPose.fromData(e.value as Map),
      },
      StoryStillAttachmentSnapshot(
        revision: attachment['revision'] as int,
        consumedRevision: attachment['consumed'] as int,
        parentId: attachment['parentId'] as String?,
        packetHash: attachment['packetHash'] as String?,
        pending: attachment['pending'] as bool,
        drivenAnchored: attachment['drivenAnchored'] == null
            ? null
            : _savedVector(attachment['drivenAnchored'], 2),
      ),
      data['sampledElapsed'] == null ? null : _n(data['sampledElapsed']),
      {
        for (final e in (data['rootStarts'] as Map).entries)
          int.parse(e.key as String): _savedVector(e.value, 3),
      },
      data['programs'] == null
          ? null
          : (data['programs'] as List).map(_m).toList(),
    );
  }
}

final class StoryStillAttachmentSnapshot {
  const StoryStillAttachmentSnapshot({
    required this.revision,
    required this.consumedRevision,
    required this.parentId,
    required this.packetHash,
    required this.pending,
    required this.drivenAnchored,
  });
  final int revision, consumedRevision;
  final String? parentId, packetHash;
  final bool pending;
  final List<double>? drivenAnchored;
}

double _n(Object? value) {
  if (value is! num || !value.toDouble().isFinite) {
    throw const FormatException('still_number');
  }
  return value.toDouble();
}

Map<String, Object?> _m(Object? value) {
  if (value is! Map) throw const FormatException('still_record');
  return Map<String, Object?>.from(value);
}

List<double> _v(Object? value, int count) {
  if (value is! List || value.length != count) {
    throw const FormatException('still_vector');
  }
  return value.map(_n).toList(growable: false);
}

List<double> _components(Object? value, List<String> names) {
  final record = _m(value);
  return [for (final name in names) _n(record[name])];
}

bool _flag(Object? value) => value == true || value == 1;
List<double> _qmul(List<double> a, List<double> b) => [
  a[3] * b[0] + a[0] * b[3] + a[1] * b[2] - a[2] * b[1],
  a[3] * b[1] - a[0] * b[2] + a[1] * b[3] + a[2] * b[0],
  a[3] * b[2] + a[0] * b[1] - a[1] * b[0] + a[2] * b[3],
  a[3] * b[3] - a[0] * b[0] - a[1] * b[1] - a[2] * b[2],
];
List<double> _eulerQuaternion(List<double> e) {
  final sx = math.sin(e[0] / 2),
      sy = math.sin(e[1] / 2),
      sz = math.sin(e[2] / 2);
  final cx = math.cos(e[0] / 2),
      cy = math.cos(e[1] / 2),
      cz = math.cos(e[2] / 2);
  return [
    sx * cy * cz + cx * sy * sz,
    cx * sy * cz - sx * cy * sz,
    cx * cy * sz - sx * sy * cz,
    cx * cy * cz + sx * sy * sz,
  ];
}

List<double> _quaternionEuler(List<double> q) {
  final x = q[0], y = q[1], z = q[2], w = q[3];
  final rx = math.asin((2 * (x * w - y * z)).clamp(-1, 1));
  if (math.cos(rx).abs() < 0.000001) {
    return [rx, math.atan2(2 * (x * z + y * w), 1 - 2 * (y * y + z * z)), 0];
  }
  return [
    rx,
    math.atan2(2 * (x * z + y * w), 1 - 2 * (x * x + y * y)),
    math.atan2(2 * (x * y + z * w), 1 - 2 * (x * x + z * z)),
  ];
}

double _ease(int type, double x) => sampleTweenEase(type, x);

/// Native source poses are sampled directly; no web bridge or baked-CG fallback.
/// The host consumes these typed transforms against immutable source geometry.
final class _StillProgram {
  _StillProgram(this.animator);
  final StoryStillAnimator animator;
  bool started = false, finished = false;
}

final class StoryStillAnimator {
  StoryStillAnimator(this.presentation, {bool singleProgram = false})
    : _singleProgram = singleProgram {
    if (presentation['sourcePath'] is! String ||
        presentation['sourceHash'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$')
            .hasMatch(presentation['sourceHash'] as String)) {
      throw const FormatException('still_source_identity');
    }
    if (presentation['schema'] != 'haneoka-still-presentation-v1') {
      throw const FormatException('still_schema');
    }
    _hasTimelineActions = (presentation['sequences'] as List)
        .map(_m)
        .any((s) => (s['timelineActions'] as List? ?? const []).isNotEmpty);
    final layout = _m(presentation['layout']);
    for (final item in layout['nodes'] as List) {
      final node = _m(item), id = node['id'];
      if (id is! String || _nodes.containsKey(id)) {
        throw const FormatException('still_node_identity');
      }
      _nodes[id] = node;
      final xy = _v(node['position'], 2), scale = _v(node['scale'], 2);
      final image = node['image'];
      _initial[id] = StoryStillPose(
        position: [...xy, _n(node['positionZ'] ?? 0)],
        scale: [...scale, _n(node['scaleZ'] ?? 1)],
        size: _v(node['size'], 2),
        rotation: _v(node['rotationQuaternion'], 4),
        opacity: _n(node['opacity']),
        color: image == null ? null : _v(_m(image)['color'], 4),
      );
    }
    _poses = Map.unmodifiable(_initial);
    _base = _poses;
    final roots = _nodes.values.where((n) => n['parent'] == null).toList();
    if (roots.length != 1) throw const FormatException('still_root_identity');
    _rootId = roots.single['id'] as String;
  }
  final Map<String, Object?> presentation;
  final bool _singleProgram;
  final _programs = <String, _StillProgram>{};
  bool _programSampling = false, _programHasUpdated = false;
  late final bool _hasTimelineActions;
  bool get hasTimelineActions => !_singleProgram && _hasTimelineActions;
  bool get selectedProgramPlaying =>
      _sequence != null && !(_programs[sequenceId]?.finished ?? true);
  bool get hasRunningPrograms => _programs.values.any((run) => !run.finished);
  double get elapsedSeconds => _elapsed;
  final Map<String, Map<String, Object?>> _nodes = {};
  final Map<String, StoryStillPose> _initial = {};
  late Map<String, StoryStillPose> _poses, _base;
  List<_Track> _tracks = const [];
  Map<String, Object?>? _sequence;
  double _elapsed = 0;
  double? _sampledElapsed;
  late final String _rootId;
  int _attachmentRevision = 0, _consumedRevision = 0;
  String? _externalParentId, _externalPacketHash;
  bool _zeroPending = false;
  List<double>? _drivenAnchored;
  final math.Random _random = math.Random();
  Map<int, StoryStillWaypointPath> _paths = {};
  Map<int, List<double>> _rootPositionStarts = {};
  Map<String, StoryStillPose> get poses => _poses;
  String? get sequenceId => _sequence?['id'] as String?;

  StoryStillAttachmentSnapshot get attachment => StoryStillAttachmentSnapshot(
    revision: _attachmentRevision,
    consumedRevision: _consumedRevision,
    parentId: _externalParentId,
    packetHash: _externalPacketHash,
    pending: _zeroPending,
    drivenAnchored: _drivenAnchored,
  );

  /// Actual SetStill requests zero immediately in Z; XY waits for real layout.
  void requestAttachment(StoryStillExternalLayoutSource source) {
    _attachmentRevision++;
    _externalParentId = source.targetId;
    _externalPacketHash = source.packetSHA256;
    _zeroPending = true;
    final p = _poses[_rootId]!.position;
    _setRootPosition([p[0], p[1], 0]);
  }

  void _setRootPosition(List<double> position) {
    _poses = Map.unmodifiable({
      ..._poses,
      _rootId: _poses[_rootId]!._withValue(_Property.position, position),
    });
  }

  /// Layout follows actual setters. Consumption writes only XY, retaining Z.
  void consumeAttachment(StoryStillExternalLayout layout) {
    if (!_zeroPending) return;
    if (_externalParentId != layout.target.id ||
        _externalPacketHash != layout.source.packetSHA256) {
      throw const FormatException('still_attachment_parent_identity');
    }
    final node = _nodes[_rootId]!;
    if (node['transformKind'] != 'rect' &&
        node['transformKind'] != 'transform') {
      throw const FormatException('still_attachment_transform_kind');
    }
    if (node['transformKind'] == 'transform') {
      _drivenAnchored = const [0, 0];
    } else {
      final rect = layout.target.rect;
      final amin = _v(node['anchorMin'], 2),
          amax = _v(node['anchorMax'], 2),
          pivot = _v(node['pivot'], 2);
      double f(double value) => (Float32List(1)..[0] = value)[0];
      double axis(int i) {
        final min = f(rect[i] + f(amin[i] * rect[i + 2]));
        final max = f(rect[i] + f(amax[i] * rect[i + 2]));
        return f(-f(min + f(f(max - min) * pivot[i])));
      }

      _drivenAnchored = List.unmodifiable([axis(0), axis(1)]);
    }
    _setRootPosition([..._drivenAnchored!, _poses[_rootId]!.position[2]]);
    _zeroPending = false;
    _consumedRevision = _attachmentRevision;
  }

  List<double> _world(
    String id,
    Map<String, StoryStillPose> poses,
    Set<String> seen,
  ) {
    if (!seen.add(id)) throw const FormatException('still_parent_cycle');
    final node = _nodes[id], pose = poses[id];
    if (node == null || pose == null) {
      throw const FormatException('still_parent');
    }
    final parent = node['parent'];
    final result = parent == null
        ? pose.rotation
        : _qmul(_world(parent as String, poses, seen), pose.rotation);
    seen.remove(id);
    return result;
  }

  void play(String sequenceId) {
    if (hasTimelineActions) {
      final run = _restartProgram(sequenceId);
      final poses = Map<String, StoryStillPose>.from(_poses);
      for (final track in run.animator._tracks) {
        if (track.at != 0) continue;
        final pose = run.animator._poses[track.node]!;
        final value = switch (track.property) {
          _Property.position => pose.position,
          _Property.scale => pose.scale,
          _Property.size => pose.size,
          _Property.worldRotation => pose.rotation,
          _Property.color => pose.color!,
          _Property.opacity => [pose.opacity],
        };
        poses[track.node] = poses[track.node]!._withValue(
          track.property,
          value,
        );
      }
      _poses = Map.unmodifiable(poses);
      _sequence = run.animator._sequence;
      _elapsed = 0;
      return;
    }
    final sequences = presentation['sequences'] as List;
    final matching = sequences
        .map(_m)
        .where((s) => s['id'] == sequenceId)
        .toList();
    if (matching.length != 1) throw const FormatException('still_sequence');
    _sequence = matching.single;
    _base = _poses;
    _elapsed = 0;
    _sampledElapsed = null;
    _paths = {};
    _rootPositionStarts = {};
    _compile();
    sampleAtSeconds(0);
  }

  void stop() {
    _programs.clear();
    _base = _poses;
    _tracks = const [];
    _sequence = null;
    _rootPositionStarts = {};
    _elapsed = 0;
    _sampledElapsed = null;
  }

  void _killProgram(String id, [Set<String>? visited]) {
    final seen = visited ?? <String>{};
    if (!seen.add(id)) return;
    _programs.remove(id);
    final sequence = (presentation['sequences'] as List)
        .map(_m)
        .singleWhere((s) => s['id'] == id);
    for (final child in sequence['killWith'] as List? ?? const []) {
      _killProgram(child as String, seen);
    }
  }

  _StillProgram _restartProgram(String id) {
    final sequence = (presentation['sequences'] as List)
        .map(_m)
        .singleWhere((s) => s['id'] == id);
    for (final raw in sequence['timelineActions'] as List? ?? const []) {
      final action = _m(raw), at = _n(action['at']);
      if (action['operation'] != 'restart' ||
          action['sequence'] is! String ||
          at < 0 ||
          at > _n(sequence['duration']) ||
          !(presentation['sequences'] as List)
              .map(_m)
              .any((s) => s['id'] == action['sequence'])) {
        throw const FormatException('still_callback_binding');
      }
    }
    _killProgram(id);
    final animator = StoryStillAnimator(presentation, singleProgram: true);
    animator._poses = _poses;
    animator._attachmentRevision = _attachmentRevision;
    animator._consumedRevision = _consumedRevision;
    animator._externalParentId = _externalParentId;
    animator._externalPacketHash = _externalPacketHash;
    animator._zeroPending = _zeroPending;
    animator._drivenAnchored = _drivenAnchored;
    animator.play(id);
    animator._programSampling = true;
    return _programs[id] = _StillProgram(animator);
  }

  /// Named Source programs retain independent handles and real-update clocks.
  void advancePrograms(double delta) {
    if (!hasTimelineActions || !delta.isFinite || delta <= 0) return;
    double f(double value) => (Float32List(1)..[0] = value)[0];
    for (final entry in _programs.entries.toList()) {
      final run = entry.value;
      if (_programs[entry.key] != run || run.finished) continue;
      final animator = run.animator, sequence = animator._sequence!;
      final previous = animator._elapsed, duration = _n(sequence['duration']);
      final next = math.min(duration, f(previous + f(delta))),
          first = !run.started;
      animator._poses = _poses;
      animator.sampleAtSeconds(next, actualUpdate: true);
      animator._programHasUpdated = true;
      _poses = animator._poses;
      run.started = true;
      for (final raw in sequence['timelineActions'] as List? ?? const []) {
        if (_programs[entry.key] != run) break;
        final action = _m(raw), at = _n(action['at']);
        if (at <= next && (first || at > previous))
          _restartProgram(action['sequence'] as String);
      }
      if (_programs[entry.key] != run) continue;
      if (next >= duration) {
        if (_flag(sequence['loop']) && duration > 0) {
          final poses = Map<String, StoryStillPose>.from(_poses);
          for (final track in animator._tracks.reversed) {
            var value = track.start;
            if (track.property == _Property.worldRotation) {
              final world = _eulerQuaternion(value),
                  parent = _nodes[track.node]!['parent'];
              if (parent == null) {
                value = world;
              } else {
                final q = _world(parent as String, poses, {});
                value = _qmul([-q[0], -q[1], -q[2], q[3]], world);
              }
            }
            poses[track.node] = poses[track.node]!._withValue(
              track.property,
              value,
            );
          }
          _poses = Map.unmodifiable(poses);
          animator._poses = _poses;
          animator._elapsed = 0;
          animator._sampledElapsed = 0;
          animator._programHasUpdated = false;
          run.started = false;
        } else {
          run.finished = true;
        }
      }
    }
    final primary = _programs[sequenceId];
    if (primary != null) _elapsed = primary.animator._elapsed;
  }

  void _compile({bool restoring = false}) {
    if (_sequence!['timelineActions'] == null
        ? (_sequence!['nativeActions'] as List).isNotEmpty
        : (_sequence!['unhandledNativeActions'] as List).isNotEmpty) {
      throw UnsupportedError('still_native_callbacks');
    }
    final tracks = <_Track>[];
    final records = (_sequence!['nativeTweens'] as List).map(_m).toList()
      ..sort((a, b) => _n(a['at']).compareTo(_n(b['at'])));
    for (final record in records) {
      final raw = _m(record['raw']),
          id = record['node'] as String,
          pose = _base[id];
      if (pose == null) throw const FormatException('still_tween_node');
      if (_flag(raw['isSpeedBased'])) {
        throw UnsupportedError('still_speed_based');
      }
      final type = _n(record['animationType']).toInt(),
          target = _n(raw['targetType']).toInt();
      late _Property property;
      late List<double> start, end;
      StoryStillWaypointPath? path;
      switch (type) {
        case 1:
          if (target != 5 || _flag(raw['optionalBool0'])) {
            throw UnsupportedError('still_move_target_or_snapping');
          }
          property = _Property.position;
          start = pose.position;
          end = _components(raw['endValueV3'], ['x', 'y', 'z']);
        case 3:
          if (target != 11 || ![0, 1].contains(raw['optionalInt0'])) {
            throw UnsupportedError('still_rotate_mode');
          }
          property = _Property.worldRotation;
          start = _quaternionEuler(_world(id, _base, {}));
          end = _components(raw['endValueV3'], [
            'x',
            'y',
            'z',
          ]).map((v) => v * math.pi / 180).toList();
        case 5:
          if (target != 11) throw UnsupportedError('still_scale_target');
          property = _Property.scale;
          start = pose.scale;
          end = _flag(raw['optionalBool0'])
              ? List.filled(3, _n(raw['endValueFloat']))
              : _components(raw['endValueV3'], ['x', 'y', 'z']);
        case 6:
          if (record['targetKind'] != 'image' || pose.color == null) {
            throw UnsupportedError('still_color_target');
          }
          property = _Property.color;
          start = pose.color!;
          end = _components(raw['endValueColor'], ['r', 'g', 'b', 'a']);
        case 7:
          if (record['targetKind'] == 'image' && pose.color != null) {
            property = _Property.color;
            start = pose.color!;
            end = [...pose.color!.take(3), _n(raw['endValueFloat'])];
          } else if (record['targetKind'] == 'canvas-group') {
            property = _Property.opacity;
            start = [pose.opacity];
            end = [_n(raw['endValueFloat'])];
          } else {
            throw UnsupportedError('still_fade_target');
          }
        case 9:
        case 12:
          if (target != 5 || _flag(raw['optionalBool0'])) {
            throw UnsupportedError('still_path_target_or_snapping');
          }
          property = _Property.position;
          start = pose.position;
          end = pose.position;
          final strength = _components(raw['endValueV3'], ['x', 'y', 'z']);
          final slot = tracks.length;
          path = _paths[slot];
          if (path == null && restoring) {
            throw const FormatException('still_snapshot_path');
          }
          if (path == null) {
            final duration = _n(record['duration']),
                vibrato = _n(raw['optionalInt0']).toInt();
            if (duration <= 0 || vibrato < 1) {
              throw UnsupportedError('still_path_duration');
            }
            if (type == 9) {
              path = _punch(
                [strength[0], strength[1], 0],
                duration,
                vibrato,
                _n(raw['optionalFloat0']),
              );
            } else {
              if (raw['optionalShakeRandomnessMode'] != 0 ||
                  strength[0] != strength[1] ||
                  strength[2] != 0) {
                throw UnsupportedError('still_shake_source_mode');
              }
              path = _shake(
                strength[0],
                duration,
                vibrato,
                _n(raw['optionalFloat0']),
                _flag(raw['optionalBool1']),
                _random,
              );
            }
            _paths[slot] = path;
          }
        case 21:
          if (target != 5) throw UnsupportedError('still_size_delta_target');
          property = _Property.size;
          start = pose.size;
          end = _flag(raw['optionalBool0'])
              ? List.filled(2, _n(raw['endValueFloat']))
              : _components(raw['endValueV2'], ['x', 'y']);
        default:
          throw UnsupportedError('still_animation_type:$type');
      }
      final at = _n(record['at']), duration = _n(record['duration']);
      if (_externalPacketHash != null &&
          id == _rootId &&
          property == _Property.position &&
          (_flag(raw['isRelative']) || _flag(raw['isFrom']))) {
        throw UnsupportedError('still_external_root_relative_or_from');
      }
      for (final track in tracks) {
        if (track.node == id && track.property == property) {
          start = _value(track, at);
        }
      }
      if (_flag(raw['isRelative'])) {
        end = [for (var i = 0; i < end.length; i++) start[i] + end[i]];
      }
      if (_flag(raw['isFrom'])) {
        final previous = start;
        start = end;
        end = previous;
      }
      if (property == _Property.worldRotation &&
          raw['optionalInt0'] == 0 &&
          !_flag(raw['isRelative'])) {
        end = [
          for (var i = 0; i < end.length; i++)
            start[i] +
                math.atan2(
                  math.sin(end[i] - start[i]),
                  math.cos(end[i] - start[i]),
                ),
        ];
      }
      final loops = _n(raw['loops']).toInt(),
          mode = _n(raw['loopType']).toInt();
      if (![0, 1].contains(mode) || loops < -1) {
        throw UnsupportedError('still_loop_type');
      }
      final iterations = loops == -1 ? 2147483647 : math.max(1, loops);
      tracks.add(
        _Track(
          id,
          property,
          at,
          duration,
          iterations,
          mode == 1,
          _n(record['ease']).toInt(),
          start,
          end,
          path,
        ),
      );
    }
    _tracks = List.unmodifiable(tracks);
  }

  List<double> _value(
    _Track track,
    double time, {
    List<double>? positionStart,
  }) {
    final start = positionStart ?? track.start;
    var cycle = 0, progress = 1.0;
    if (track.duration > 0) {
      final local = (time - track.at)
          .clamp(0, track.duration * track.iterations)
          .toDouble();
      cycle = (local / track.duration).floor();
      progress = (local - cycle * track.duration) / track.duration;
      if (local > 0 && (progress == 0 || cycle >= track.iterations)) {
        cycle = math.min(cycle, track.iterations) - 1;
        progress = 1;
      }
    } else {
      cycle = track.iterations - 1;
    }
    if (track.yoyo && cycle.isOdd) progress = 1 - progress;
    if (track.path != null) {
      final offset = track.path!.sample(progress);
      return [for (var axis = 0; axis < 3; axis++) start[axis] + offset[axis]];
    }
    final eased = _ease(track.ease, progress);
    return [
      for (var i = 0; i < start.length; i++)
        start[i] + (track.end[i] - start[i]) * eased,
    ];
  }

  Map<String, StoryStillPose> sampleAtSeconds(
    double elapsed, {
    bool actualUpdate = false,
    bool sequenceRestart = false,
  }) {
    if (!elapsed.isFinite || elapsed < 0) {
      throw const FormatException('still_elapsed');
    }
    if (hasTimelineActions || _sequence == null) return _poses;
    final duration = _n(_sequence!['duration']);
    _elapsed = !_programSampling && _flag(_sequence!['loop']) && duration > 0
        ? elapsed % duration
        : math.min(duration, elapsed);
    if (_externalPacketHash != null &&
        !actualUpdate &&
        _sampledElapsed == _elapsed) {
      return _poses;
    }
    final previousElapsed = _sampledElapsed;
    _sampledElapsed = _elapsed;
    if (sequenceRestart && _externalPacketHash != null) {
      var position = _poses[_rootId]!.position;
      // The existing parent clock discarded overshoot and restarted. Preserve
      // root lazy captures reached on completion, then Reference's reverse
      // nested rewind setters. This changes properties, never the parent clock.
      for (var slot = 0; slot < _tracks.length; slot++) {
        final track = _tracks[slot];
        if (track.node != _rootId ||
            track.property != _Property.position ||
            track.at > duration) {
          continue;
        }
        final end = track.at + track.duration * track.iterations;
        if (previousElapsed != null &&
            (track.at > 0 ? previousElapsed >= end : previousElapsed > end)) {
          continue;
        }
        final start = _rootPositionStarts.putIfAbsent(
          slot,
          () => List.unmodifiable(position),
        );
        final next = _value(track, duration, positionStart: start);
        if (track.path != null) next[2] = position[2];
        position = next;
      }
      for (var slot = _tracks.length - 1; slot >= 0; slot--) {
        final start = _rootPositionStarts[slot];
        if (start == null) continue;
        final track = _tracks[slot];
        final next = _value(track, track.at, positionStart: start);
        if (track.path != null) next[2] = position[2];
        position = next;
      }
      _setRootPosition(position);
    }
    final poses = Map<String, StoryStillPose>.from(
      _programSampling ? _poses : _base,
    );
    // Current root properties survive layout without mutating captured starts.
    if (_externalPacketHash != null) {
      poses[_rootId] = poses[_rootId]!._withValue(
        _Property.position,
        _poses[_rootId]!.position,
      );
    }
    for (var slot = 0; slot < _tracks.length; slot++) {
      final track = _tracks[slot];
      if (_elapsed < track.at) continue;
      final trackEnd = track.at + track.duration * track.iterations;
      if (_programSampling &&
          _programHasUpdated &&
          previousElapsed != null &&
          _elapsed >= previousElapsed &&
          previousElapsed >= trackEnd)
        continue;
      List<double>? rootStart;
      if (_externalPacketHash != null &&
          track.node == _rootId &&
          track.property == _Property.position) {
        final end = track.at + track.duration * track.iterations;
        if (previousElapsed != null &&
            _elapsed >= previousElapsed &&
            (track.at > 0 ? previousElapsed >= end : previousElapsed > end)) {
          continue;
        }
        rootStart = _rootPositionStarts.putIfAbsent(
          slot,
          () => List.unmodifiable(poses[_rootId]!.position),
        );
      }
      var values = _value(track, _elapsed, positionStart: rootStart);
      if (rootStart != null && track.path != null) {
        // DOShake/PunchAnchorPos are XY setters and retain the latest local Z.
        values[2] = poses[_rootId]!.position[2];
      }
      if (track.property == _Property.worldRotation) {
        final world = _eulerQuaternion(values),
            parent = _nodes[track.node]!['parent'];
        if (parent == null) {
          values = world;
        } else {
          final q = _world(parent as String, poses, {});
          values = _qmul([-q[0], -q[1], -q[2], q[3]], world);
        }
      }
      poses[track.node] = poses[track.node]!._withValue(track.property, values);
    }
    return _poses = Map.unmodifiable(poses);
  }

  StoryStillSnapshot _snapshotSingle() => StoryStillSnapshot(
    presentation['sourcePath'] as String,
    presentation['sourceHash'] as String,
    _sequence?['id'] as String?,
    _elapsed,
    _base,
    Map.unmodifiable(_paths),
    _poses,
    attachment,
    _sampledElapsed,
    Map.unmodifiable(_rootPositionStarts),
  );
  StoryStillSnapshot snapshot() {
    if (!hasTimelineActions) return _snapshotSingle();
    final primary =
        _programs[sequenceId]?.animator._snapshotSingle() ?? _snapshotSingle();
    return StoryStillSnapshot(
      primary.sourcePath,
      primary.sourceHash,
      primary.sequence,
      primary.elapsed,
      primary.base,
      primary.paths,
      _poses,
      attachment,
      primary.sampledElapsed,
      primary.rootPositionStarts,
      [
        for (final run in _programs.values)
          {
            'state': run.animator._snapshotSingle().toData(),
            'started': run.started,
            'finished': run.finished,
          },
      ],
    );
  }

  Map<String, Object?> snapshotData() => snapshot().toData();
  void restoreData(Map data) => restore(StoryStillSnapshot.fromData(data));
  void restore(StoryStillSnapshot snapshot) {
    _restoreSingle(snapshot);
    _programs.clear();
    if (snapshot.programs != null) {
      if (!hasTimelineActions)
        throw const FormatException('still_snapshot_programs');
      for (final raw in snapshot.programs!) {
        final state = StoryStillSnapshot.fromData(raw['state'] as Map),
            id = state.sequence;
        if (id == null ||
            _programs.containsKey(id) ||
            state.programs != null ||
            raw['started'] is! bool ||
            raw['finished'] is! bool) {
          throw const FormatException('still_snapshot_program');
        }
        final animator = StoryStillAnimator(presentation, singleProgram: true);
        animator._restoreSingle(state);
        animator._programSampling = true;
        animator._programHasUpdated = raw['started'] as bool;
        final run = _StillProgram(animator)
          ..started = raw['started'] as bool
          ..finished = raw['finished'] as bool;
        _programs[id] = run;
      }
      if (snapshot.sequence != null &&
          !_programs.containsKey(snapshot.sequence))
        throw const FormatException('still_snapshot_primary');
    } else if (hasTimelineActions && snapshot.sequence != null)
      throw const FormatException('still_snapshot_programs');
  }

  void _restoreSingle(StoryStillSnapshot snapshot) {
    if (snapshot.sourcePath != presentation['sourcePath'] ||
        snapshot.sourceHash != presentation['sourceHash'] ||
        !snapshot.elapsed.isFinite ||
        snapshot.elapsed < 0 ||
        snapshot.base.length != _nodes.length ||
        !_nodes.keys.every(snapshot.base.containsKey) ||
        snapshot.current.length != _nodes.length ||
        !_nodes.keys.every(snapshot.current.containsKey) ||
        (snapshot.sampledElapsed != null &&
            (!snapshot.sampledElapsed!.isFinite ||
                snapshot.sampledElapsed! < 0)) ||
        snapshot.attachment.revision < snapshot.attachment.consumedRevision ||
        snapshot.attachment.consumedRevision < 0 ||
        (snapshot.attachment.pending
            ? snapshot.attachment.revision <=
                  snapshot.attachment.consumedRevision
            : snapshot.attachment.revision !=
                  snapshot.attachment.consumedRevision) ||
        snapshot.rootPositionStarts.values.any(
          (v) => v.length != 3 || v.any((n) => !n.isFinite),
        )) {
      throw const FormatException('still_snapshot_source');
    }
    _base = snapshot.base;
    _poses = _base;
    _paths = Map.from(snapshot.paths);
    _rootPositionStarts = Map.from(snapshot.rootPositionStarts);
    _elapsed = snapshot.elapsed;
    _sampledElapsed = null;
    _attachmentRevision = snapshot.attachment.revision;
    _consumedRevision = snapshot.attachment.consumedRevision;
    _externalParentId = snapshot.attachment.parentId;
    _externalPacketHash = snapshot.attachment.packetHash;
    _zeroPending = snapshot.attachment.pending;
    _drivenAnchored = snapshot.attachment.drivenAnchored;
    if (snapshot.sequence == null) {
      _sequence = null;
      _tracks = const [];
      _poses = snapshot.current;
      _sampledElapsed = snapshot.sampledElapsed;
      return;
    }
    final values = (presentation['sequences'] as List)
        .map(_m)
        .where((s) => s['id'] == snapshot.sequence)
        .toList();
    if (values.length != 1) {
      throw const FormatException('still_snapshot_sequence');
    }
    _sequence = values.single;
    _compile(restoring: true);
    if (snapshot.rootPositionStarts.keys.any(
      (slot) =>
          slot < 0 ||
          slot >= _tracks.length ||
          _tracks[slot].node != _rootId ||
          _tracks[slot].property != _Property.position,
    )) {
      throw const FormatException('still_snapshot_root_starts');
    }
    sampleAtSeconds(snapshot.elapsed);
    _poses = snapshot.current;
    _sampledElapsed = snapshot.sampledElapsed;
  }

  /// Source node order, enabled state, image/texture references and camera stay
  /// unchanged. This boundary is Dart-native; it is not a JSON bridge per frame.
  Map<String, Object?> layoutAtSeconds(double elapsed, {bool sample = true}) {
    // Normal playback reads current layout after real updates. The standalone
    // mathematical presenter can still request a direct time sample explicitly.
    final poses = sample ? sampleAtSeconds(elapsed) : _poses,
        layout = _m(presentation['layout']);
    return {
      ...layout,
      'nodes': [
        for (final original in layout['nodes'] as List)
          _posedNode(_m(original), poses),
      ],
    };
  }

  Map<String, Object?> _posedNode(
    Map<String, Object?> node,
    Map<String, StoryStillPose> poses,
  ) {
    final pose = poses[node['id']]!;
    final image = node['image'];
    return {
      ...node,
      'position': pose.position.take(2).toList(),
      'positionZ': pose.position[2],
      'scale': pose.scale.take(2).toList(),
      'scaleZ': pose.scale[2],
      'size': pose.size,
      'rotationQuaternion': pose.rotation,
      'opacity': pose.opacity,
      if (image != null && pose.color != null)
        'image': {..._m(image), 'color': pose.color},
    };
  }
}

List<double> _savedVector(Object? value, int length) {
  final result = [for (final v in value as List) _n(v)];
  if (result.length != length) {
    throw const FormatException('still_data_vector');
  }
  return List.unmodifiable(result);
}
