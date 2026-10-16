import 'dart:typed_data';

import 'story_ui_layout_data.dart';

List<double> _tuple(List<double> values, int size) {
  if (values.length != size || values.any((v) => !v.isFinite)) {
    throw const FormatException('retained_ui_tuple');
  }
  return List.unmodifiable(values);
}

enum StoryRetainedUiAxis { horizontal, vertical }

/// The adapter verifies content identity and layout hash before rebinding
/// retained numeric channels to a new runtime epoch.
final class StoryRetainedUiSourceBinding {
  const StoryRetainedUiSourceBinding({
    required this.sourceIdentity,
    required this.layoutHash,
  });
  final String sourceIdentity, layoutHash;
  Map<String, Object?> toJson() => {
    'sourceIdentity': sourceIdentity,
    'layoutHash': layoutHash,
  };
  bool matches(Map value) =>
      value['sourceIdentity'] == sourceIdentity &&
      value['layoutHash'] == layoutHash;
}

/// The application adapter supplies verified IDs and original source channels.
/// This renderer module has no asset schema, source-version or hash policy.
final class StoryRetainedUiNode {
  StoryRetainedUiNode({
    required this.id,
    required this.parentId,
    required List<double> anchorMin,
    required List<double> anchorMax,
    required List<double> anchoredPosition,
    required List<double> sizeDelta,
    required List<double> pivot,
    required this.localZ,
    required List<double> quaternion,
    required List<double> scale,
    required this.active,
    this.layoutGroup = false,
    this.contentSizeFitter = false,
  }) : anchorMin = _tuple(anchorMin, 2),
       anchorMax = _tuple(anchorMax, 2),
       anchoredPosition = _tuple(anchoredPosition, 2),
       sizeDelta = _tuple(sizeDelta, 2),
       pivot = _tuple(pivot, 2),
       quaternion = _tuple(quaternion, 4),
       scale = _tuple(scale, 3) {
    if (id.isEmpty || !localZ.isFinite) {
      throw const FormatException('retained_ui_node');
    }
  }
  final String id;
  final String? parentId;
  final List<double> anchorMin, anchorMax, anchoredPosition, sizeDelta, pivot;
  final double localZ;
  final List<double> quaternion, scale;
  final bool active, layoutGroup, contentSizeFitter;
}

final class StoryRetainedUiPose {
  StoryRetainedUiPose({
    this.anchoredX,
    this.anchoredY,
    List<double>? localQuaternion,
    List<double>? eulerDegrees,
  }) : eulerDegrees = eulerDegrees == null ? null : _tuple(eulerDegrees, 3),
       localQuaternion = localQuaternion == null
           ? null
           : _tuple(localQuaternion, 4) {
    if ((anchoredX != null && !anchoredX!.isFinite) ||
        (anchoredY != null && !anchoredY!.isFinite)) {
      throw const FormatException('retained_ui_pose');
    }
  }
  final double? anchoredX, anchoredY;
  final List<double>? localQuaternion, eulerDegrees;
}

/// Base local geometry and full TRS, before a later matrix/draw consumer.
/// The rectangle is pivot-relative Unity y-up, not a screen-space AABB.
final class StoryRetainedUiBasePlacement {
  StoryRetainedUiBasePlacement._(
    this.node,
    this.localRect,
    List<double> localPosition,
    List<double> quaternion,
    List<double>? eulerDegrees,
    this.activeInHierarchy,
  ) : localPosition = List.unmodifiable(localPosition),
      quaternion = List.unmodifiable(quaternion),
      eulerDegrees = eulerDegrees == null
          ? null
          : List.unmodifiable(eulerDegrees);
  final StoryRetainedUiNode node;
  final StoryUiRect localRect;
  final List<double> localPosition, quaternion;
  final List<double>? eulerDegrees;
  List<double> get scale => node.scale;
  final bool activeInHierarchy;
}

final class _Channels {
  _Channels(StoryRetainedUiNode node)
    : anchorMin = List.of(node.anchorMin),
      anchorMax = List.of(node.anchorMax),
      position = List.of(node.anchoredPosition),
      size = List.of(node.sizeDelta),
      quaternion = List.of(node.quaternion);
  final List<double> anchorMin, anchorMax, position, size, quaternion;
  List<double>? eulerDegrees;
  _ChannelSnapshot snapshot() => _ChannelSnapshot(this);
  void restore(_ChannelSnapshot value) {
    anchorMin.setAll(0, value.anchorMin);
    anchorMax.setAll(0, value.anchorMax);
    position.setAll(0, value.position);
    size.setAll(0, value.size);
    quaternion.setAll(0, value.quaternion);
    eulerDegrees = value.eulerDegrees;
  }
}

final class _ChannelSnapshot {
  _ChannelSnapshot(_Channels channels)
    : anchorMin = List.unmodifiable(channels.anchorMin),
      anchorMax = List.unmodifiable(channels.anchorMax),
      position = List.unmodifiable(channels.position),
      size = List.unmodifiable(channels.size),
      quaternion = List.unmodifiable(channels.quaternion),
      eulerDegrees = channels.eulerDegrees == null
          ? null
          : List.unmodifiable(channels.eulerDegrees!);
  final List<double> anchorMin, anchorMax, position, size, quaternion;
  final List<double>? eulerDegrees;
}

final class StoryRetainedUiLayoutSnapshot {
  StoryRetainedUiLayoutSnapshot._(
    this.sourceScope,
    this.canvas,
    this.actualUs,
    this.actualIndex,
    Map<String, _ChannelSnapshot> channels,
    Map<String, bool> activation,
  ) : _channels = Map.unmodifiable(channels),
      activation = Map.unmodifiable(activation);
  final Object sourceScope;
  final StoryUiRect? canvas;
  final int? actualUs, actualIndex;
  final Map<String, _ChannelSnapshot> _channels;
  final Map<String, bool> activation;
  Map<String, Object?> toData({
    required StoryRetainedUiSourceBinding binding,
  }) => {
    'version': 1,
    'binding': binding.toJson(),
    'canvas': canvas == null
        ? null
        : [canvas!.x, canvas!.y, canvas!.width, canvas!.height],
    'actualUs': actualUs,
    'actualIndex': actualIndex,
    'activation': Map<String, bool>.of(activation),
    'channels': {
      for (final entry in _channels.entries)
        entry.key: {
          'anchorMin': List<double>.of(entry.value.anchorMin),
          'anchorMax': List<double>.of(entry.value.anchorMax),
          'position': List<double>.of(entry.value.position),
          'size': List<double>.of(entry.value.size),
          'quaternion': List<double>.of(entry.value.quaternion),
          'euler': entry.value.eulerDegrees == null
              ? null
              : List<double>.of(entry.value.eulerDegrees!),
        },
    },
  };
}

/// Retains authored/driven rectangle channels across inactive UI frames.
/// The caller owns active four-pass measurement/control selection. Writers
/// below perform only the source RectTransform setters; no group is invented.
final class StoryRetainedUiLayoutState {
  StoryRetainedUiLayoutState({
    required this.sourceScope,
    required Iterable<StoryRetainedUiNode> nodes,
  }) {
    for (final node in nodes) {
      if (_nodes.containsKey(node.id)) {
        throw const FormatException('retained_ui_duplicate_node');
      }
      _nodes[node.id] = node;
      _channels[node.id] = _Channels(node);
    }
    if (_nodes.isEmpty ||
        _nodes.values.any(
          (n) => n.parentId != null && !_nodes.containsKey(n.parentId),
        )) {
      throw const FormatException('retained_ui_parent');
    }
    for (final node in _nodes.values) {
      final seen = <String>{};
      String? id = node.id;
      while (id != null) {
        if (!seen.add(id)) {
          throw const FormatException('retained_ui_parent_cycle');
        }
        id = _nodes[id]!.parentId;
      }
    }
  }

  /// Host value identity includes its source/epoch/window/spec revision, e.g.
  /// a value-equality record. Equality is Object.==, not instance identity;
  /// a same-source cold reconstruction can restore its retained channels.
  final Object sourceScope;
  final _nodes = <String, StoryRetainedUiNode>{};
  final _channels = <String, _Channels>{};
  final _activation = <String, bool>{};
  final _round = Float32List(1);
  StoryUiRect? _canvas;
  int? _us, _index;
  bool _dirty = true;
  Map<String, StoryRetainedUiBasePlacement> _placements = const {};

  double _f(double value) {
    _round[0] = value;
    if (!_round[0].isFinite) throw const FormatException('retained_ui_float32');
    return _round[0];
  }

  double sizeDeltaOf(String nodeId, StoryRetainedUiAxis axis) =>
      _channels[nodeId]?.size[axis.index] ??
      (throw const FormatException('retained_ui_size_node'));

  StoryUiRect get canvasRect =>
      _canvas ?? (throw StateError('retained_ui_layout_not_started'));

  /// Geometry may redraw under the same captured pair (pause/resize/events).
  /// It consumes the pair without deriving a delta or advancing any animation.
  void beginLayout({
    required Object sourceScope,
    required int actualUs,
    required int actualUpdateIndex,
    required StoryUiRect canvas,
    Map<String, bool> activeOverrides = const {},
    Map<String, StoryRetainedUiPose> poses = const {},
  }) {
    if (sourceScope != this.sourceScope ||
        actualUs < 0 ||
        actualUpdateIndex < 0 ||
        (_us != null && actualUs < _us!) ||
        (_index != null && actualUpdateIndex < _index!) ||
        (_index == actualUpdateIndex && _us != actualUs) ||
        [
          canvas.x,
          canvas.y,
          canvas.width,
          canvas.height,
        ].any((v) => !v.isFinite) ||
        canvas.width <= 0 ||
        canvas.height <= 0 ||
        !activeOverrides.keys.every(_nodes.containsKey) ||
        !poses.keys.every(_nodes.containsKey)) {
      throw const FormatException('retained_ui_layout_input');
    }
    _canvas = StoryUiRect(
      _f(canvas.x),
      _f(canvas.y),
      _f(canvas.width),
      _f(canvas.height),
    );
    _us = actualUs;
    _index = actualUpdateIndex;
    _activation
      ..clear()
      ..addAll(activeOverrides);
    for (final entry in poses.entries) {
      final channels = _channels[entry.key]!, pose = entry.value;
      if (pose.anchoredX != null) channels.position[0] = _f(pose.anchoredX!);
      if (pose.anchoredY != null) channels.position[1] = _f(pose.anchoredY!);
      if (pose.localQuaternion != null) {
        channels.quaternion.setAll(0, pose.localQuaternion!);
        channels.eulerDegrees = pose.eulerDegrees;
      }
    }
    _dirty = true;
  }

  Map<String, StoryRetainedUiBasePlacement> get basePlacements {
    if (!_dirty) return _placements;
    final canvas = _canvas;
    if (canvas == null) throw StateError('retained_ui_layout_not_started');
    final placed = <String, StoryRetainedUiBasePlacement>{};
    StoryRetainedUiBasePlacement place(String id) {
      if (placed[id] case final existing?) return existing;
      final node = _nodes[id]!, channels = _channels[id]!;
      final parent = node.parentId == null ? null : place(node.parentId!);
      final rect = parent?.localRect ?? canvas;
      final minX = _f(rect.x + _f(channels.anchorMin[0] * rect.width));
      final maxX = _f(rect.x + _f(channels.anchorMax[0] * rect.width));
      final minY = _f(rect.y + _f(channels.anchorMin[1] * rect.height));
      final maxY = _f(rect.y + _f(channels.anchorMax[1] * rect.height));
      final w = _f(_f(maxX - minX) + channels.size[0]);
      final h = _f(_f(maxY - minY) + channels.size[1]);
      final x = _f(
        _f(minX + _f(_f(maxX - minX) * node.pivot[0])) + channels.position[0],
      );
      final y = _f(
        _f(minY + _f(_f(maxY - minY) * node.pivot[1])) + channels.position[1],
      );
      return placed[id] = StoryRetainedUiBasePlacement._(
        node,
        StoryUiRect(_f(-node.pivot[0] * w), _f(-node.pivot[1] * h), w, h),
        [x, y, node.localZ],
        channels.quaternion,
        channels.eulerDegrees,
        (parent?.activeInHierarchy ?? true) && (_activation[id] ?? node.active),
      );
    }

    for (final id in _nodes.keys) {
      place(id);
    }
    _placements = Map.unmodifiable(placed);
    _dirty = false;
    return _placements;
  }

  bool _active(String id) {
    String? cursor = id;
    while (cursor != null) {
      final node = _nodes[cursor]!;
      if (!(_activation[cursor] ?? node.active)) return false;
      cursor = node.parentId;
    }
    return true;
  }

  /// Source SetChildAlongAxisWithScale(scale1): both anchors become (0,1).
  /// The caller supplies already calculated source start/required-size values.
  void driveChildAlongAxis({
    required String groupId,
    required String childId,
    required StoryRetainedUiAxis axis,
    required double position,
    double? controlledSize,
  }) {
    final group = _nodes[groupId], child = _nodes[childId];
    if (_canvas == null) throw StateError('retained_ui_layout_not_started');
    if (group == null ||
        child == null ||
        !group.layoutGroup ||
        child.parentId != groupId ||
        !_active(groupId) ||
        !_active(childId) ||
        !position.isFinite ||
        (controlledSize != null && !controlledSize.isFinite)) {
      throw const FormatException('retained_ui_group_drive');
    }
    final channels = _channels[childId]!, a = axis.index;
    channels.anchorMin.setAll(0, const [0, 1]);
    channels.anchorMax.setAll(0, const [0, 1]);
    if (controlledSize != null) channels.size[a] = _f(controlledSize);
    final size = channels.size[a];
    channels.position[a] = a == 0
        ? _f(position + _f(size * child.pivot[0]))
        : _f(-position - _f(size * _f(1 - child.pivot[1])));
    _dirty = true;
  }

  /// Source SetSizeWithCurrentAnchors, used by an actual active self fitter.
  void fitSelfAxis({
    required String nodeId,
    required StoryRetainedUiAxis axis,
    required double fittedSize,
  }) {
    final node = _nodes[nodeId], placements = basePlacements;
    if (node == null ||
        !node.contentSizeFitter ||
        !placements[nodeId]!.activeInHierarchy ||
        !fittedSize.isFinite) {
      throw const FormatException('retained_ui_self_fit');
    }
    final channels = _channels[nodeId]!, a = axis.index;
    final parentRect = node.parentId == null
        ? _canvas!
        : placements[node.parentId]!.localRect;
    final extent = a == 0 ? parentRect.width : parentRect.height;
    channels.size[a] = _f(
      fittedSize -
          _f(_f(channels.anchorMax[a] - channels.anchorMin[a]) * extent),
    );
    _dirty = true;
  }

  StoryRetainedUiLayoutSnapshot snapshot() => StoryRetainedUiLayoutSnapshot._(
    sourceScope,
    _canvas,
    _us,
    _index,
    {for (final entry in _channels.entries) entry.key: entry.value.snapshot()},
    _activation,
  );

  Map<String, Object?> snapshotData({
    required StoryRetainedUiSourceBinding binding,
  }) => snapshot().toData(binding: binding);

  void restoreData(
    Map data, {
    required StoryRetainedUiSourceBinding expectedBinding,
    int? actualUs,
    int? actualUpdateIndex,
  }) {
    final channels = data['channels'] as Map;
    if (data['version'] != 1 ||
        !expectedBinding.matches(data['binding'] as Map) ||
        channels.length != _channels.length ||
        !_channels.keys.every(channels.containsKey)) {
      throw const FormatException('retained_ui_data_binding');
    }
    List<double> array(Object? value, int size) =>
        _tuple([for (final v in value as List) (v as num).toDouble()], size);
    for (final entry in _channels.entries) {
      final saved = channels[entry.key] as Map, value = entry.value;
      value.anchorMin.setAll(0, array(saved['anchorMin'], 2));
      value.anchorMax.setAll(0, array(saved['anchorMax'], 2));
      value.position.setAll(0, array(saved['position'], 2));
      value.size.setAll(0, array(saved['size'], 2));
      value.quaternion.setAll(0, array(saved['quaternion'], 4));
      value.eulerDegrees = saved['euler'] == null
          ? null
          : array(saved['euler'], 3);
    }
    final canvas = data['canvas'] as List?;
    _canvas = canvas == null
        ? null
        : StoryUiRect(
            (canvas[0] as num).toDouble(),
            (canvas[1] as num).toDouble(),
            (canvas[2] as num).toDouble(),
            (canvas[3] as num).toDouble(),
          );
    _us = actualUs ?? data['actualUs'] as int?;
    _index = actualUpdateIndex ?? data['actualIndex'] as int?;
    _activation
      ..clear()
      ..addAll(Map<String, bool>.from(data['activation'] as Map));
    _dirty = true;
  }

  void restore(StoryRetainedUiLayoutSnapshot value) {
    if (value.sourceScope != sourceScope ||
        value._channels.length != _channels.length ||
        !_channels.keys.every(value._channels.containsKey)) {
      throw const FormatException('retained_ui_snapshot_scope');
    }
    for (final entry in _channels.entries) {
      entry.value.restore(value._channels[entry.key]!);
    }
    _canvas = value.canvas;
    _us = value.actualUs;
    _index = value.actualIndex;
    _activation
      ..clear()
      ..addAll(value.activation);
    _dirty = true;
  }
}
