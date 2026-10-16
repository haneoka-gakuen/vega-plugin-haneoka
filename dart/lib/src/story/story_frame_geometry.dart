import 'dart:typed_data';
import 'dart:math' as math;

import 'story_frame_source.dart';

final _storage = Float32List(1);
double _f(double value) {
  _storage[0] = value;
  return _storage[0];
}

Map<String, Object?> _map(Object? value) =>
    Map<String, Object?>.from(value as Map);
bool _enabled(Map<String, Object?> raw) =>
    raw['m_Enabled'] == 1 || raw['m_Enabled'] == true;
bool _flag(Object? value) => switch (value) {
  true || 1 => true,
  false || 0 => false,
  _ => throw const FormatException('frame_geometry_flag'),
};
double _number(Object? value) => value is num && value.isFinite
    ? value.toDouble()
    : throw const FormatException('frame_geometry_number');
String? _class(Map<String, Object?> component) {
  final raw = _map(component['data']);
  final script = raw['m_Script'];
  return script is Map && script['reference'] is Map
      ? (script['reference'] as Map)['name'] as String?
      : null;
}

final class StoryFrameCanvasMetrics {
  StoryFrameCanvasMetrics._(
    this.width,
    this.height,
    this.scale,
    this.referencePixelsPerUnit,
    this.planeDistance,
    this.sortingOrder,
  );
  final double width, height, scale, referencePixelsPerUnit, planeDistance;
  final int sortingOrder;
  factory StoryFrameCanvasMetrics.fromRaw(
    Map<String, Object?> actualCanvas,
    Map<String, Object?> actualClampedScaler, {
    required double actualPixelWidth,
    required double actualPixelHeight,
  }) {
    if (!actualPixelWidth.isFinite ||
        !actualPixelHeight.isFinite ||
        actualPixelWidth <= 0 ||
        actualPixelHeight <= 0) {
      throw const FormatException('frame_canvas_pixel_extent');
    }
    final reference = _map(actualClampedScaler['m_ReferenceResolution']);
    final script = _map(_map(actualClampedScaler['m_Script'])['reference']);
    if (!_enabled(actualClampedScaler) ||
        actualClampedScaler['m_UiScaleMode'] != 1 ||
        script['name'] != 'ClampedCanvasScaler' ||
        script['serializedFile'] != 'CAB-26bec939c462ea1051f1dd59d8bb943a' ||
        script['pathId'] != '-8568584349124095861' ||
        !_enabled(actualCanvas) ||
        actualCanvas['m_RenderMode'] != 1 ||
        actualCanvas['m_SortingOrder'] != 303 ||
        _flag(actualCanvas['m_OverrideSorting']) ||
        _flag(actualCanvas['m_PixelPerfect'])) {
      throw UnsupportedError('frame_canvas_source_recipe');
    }
    final refX = _number(reference['x']), refY = _number(reference['y']);
    final mode = _number(actualClampedScaler['m_ScreenMatchMode']).toInt();
    final match = _number(actualClampedScaler['m_MatchWidthOrHeight'])
        .clamp(0.0, 1.0);
    final threshold = _number(actualClampedScaler['_maxAspectThreshold']);
    if (refX <= 0 || refY <= 0 || threshold <= 0) {
      throw const FormatException('frame_canvas_reference');
    }
    final widthScale = actualPixelWidth / refX,
        heightScale = actualPixelHeight / refY;
    var scale = switch (mode) {
      0 =>
        math
            .pow(
              2,
              (1 - match) * (math.log(widthScale) / math.ln2) +
                  match * (math.log(heightScale) / math.ln2),
            )
            .toDouble(),
      1 => math.min(widthScale, heightScale),
      2 => math.max(widthScale, heightScale),
      _ => throw UnsupportedError('frame_canvas_match_mode:$mode'),
    };
    final aspect = actualPixelWidth / actualPixelHeight;
    if (aspect > threshold) scale = threshold / aspect;
    return StoryFrameCanvasMetrics._(
      actualPixelWidth / scale,
      actualPixelHeight / scale,
      scale,
      _number(actualClampedScaler['m_ReferencePixelsPerUnit']),
      _number(actualCanvas['m_PlaneDistance']),
      (actualCanvas['m_SortingOrder'] as num).toInt(),
    );
  }
}

final class _Node {
  _Node(this.source, this.pose)
    : anchorsMin = List.of(source.anchorMin),
      anchorsMax = List.of(source.anchorMax),
      size = List.of(pose.size),
      position = List.of(pose.position);
  final StoryFrameNodeData source;
  final StoryFramePose pose;
  final List<double> anchorsMin, anchorsMax, size, position;
  bool active = false, anchorPositionDriven = false;
  double width = 0, height = 0;
  Map<String, Object?>? component(String name) {
    final found = source.components.where((c) => _class(c) == name).toList();
    if (found.length > 1) {
      throw UnsupportedError('frame_geometry_duplicate:$name');
    }
    if (found.isEmpty) return null;
    final raw = _map(found.single['data']);
    return _enabled(raw) ? raw : null;
  }

  void dimensions(double parentWidth, double parentHeight) {
    width = _f(_f(parentWidth * _f(anchorsMax[0] - anchorsMin[0])) + size[0]);
    height = _f(_f(parentHeight * _f(anchorsMax[1] - anchorsMin[1])) + size[1]);
  }

  Map<String, Object?> output() => {
    ...source.layout(pose),
    'anchorMin': List.unmodifiable(anchorsMin),
    'anchorMax': List.unmodifiable(anchorsMax),
    'size': List.unmodifiable(size),
    'position': position.take(2).toList(),
    if (anchorPositionDriven) 'localPositionOverride': null,
    'positionZ': position[2],
    'resolvedRectSize': [width, height],
  };
}

/// Original driven RectTransform subset used by the admitted Yume resources.
/// Canvas dimensions are actual logical units computed from that canvas's own
/// scaler and actual pixel viewport. No reference viewport is substituted.
final class StoryFrameGeometry {
  static Map<String, Object?> layoutAt(
    StoryFrameSource source,
    Map<String, StoryFramePose> poses, {
    required double actualCanvasWidth,
    required double actualCanvasHeight,
  }) {
    if (!actualCanvasWidth.isFinite ||
        !actualCanvasHeight.isFinite ||
        actualCanvasWidth <= 0 ||
        actualCanvasHeight <= 0) {
      throw const FormatException('frame_geometry_canvas_extent');
    }
    final nodes = {
      for (final node in source.nodes) node.id: _Node(node, poses[node.id]!),
    };
    final children = <String, List<_Node>>{};
    for (final node in nodes.values) {
      if (node.source.parent != null) {
        (children[node.source.parent!] ??= []).add(node);
      }
      for (final component in node.source.components) {
        final raw = _map(component['data']);
        if (!_enabled(raw)) continue;
        final cls = _class(component);
        if (cls == 'UIParticle' &&
            source.particleSource?.groups.any(
                  (group) =>
                      group.component.id == component['pathId'].toString(),
                ) ==
                true) {
          continue;
        }
        if (cls != null &&
            !const {
              'AdvFrame',
              'Image',
              'AspectRatioFitter',
              'HorizontalLayoutGroup',
              'StretchPosition',
            }.contains(cls)) {
          throw UnsupportedError('frame_geometry_component:$cls');
        }
      }
    }
    void visit(
      _Node node,
      double parentWidth,
      double parentHeight,
      bool parentActive,
    ) {
      node.active = parentActive && node.pose.active;
      node.dimensions(parentWidth, parentHeight);
      if (node.active) {
        final ratio = node.component('AspectRatioFitter');
        if (ratio != null) {
          final mode = (_number(ratio['m_AspectMode'])).toInt();
          final aspect = _number(ratio['m_AspectRatio']);
          if (mode != 0 && aspect <= 0) {
            throw const FormatException('frame_geometry_aspect_ratio');
          }
          if (mode == 1) {
            node.size[1] = _f(
              _f(node.width / aspect) -
                  _f(
                    parentHeight * _f(node.anchorsMax[1] - node.anchorsMin[1]),
                  ),
            );
          } else if (mode == 2) {
            node.size[0] = _f(
              _f(node.height * aspect) -
                  _f(parentWidth * _f(node.anchorsMax[0] - node.anchorsMin[0])),
            );
          } else if (mode == 3 || mode == 4) {
            node.anchorsMin
              ..[0] = 0
              ..[1] = 0;
            node.anchorsMax
              ..[0] = 1
              ..[1] = 1;
            node.position[0] = node.position[1] = 0;
            node.anchorPositionDriven = true;
            node.size[0] = node.size[1] = 0;
            if ((_f(parentHeight * aspect) < parentWidth) != (mode == 3)) {
              node.size[1] = _f(_f(parentWidth / aspect) - parentHeight);
            } else {
              node.size[0] = _f(_f(parentHeight * aspect) - parentWidth);
            }
          } else if (mode != 0) {
            throw UnsupportedError('frame_geometry_aspect_mode:$mode');
          }
          node.dimensions(parentWidth, parentHeight);
        }
        final stretch = node.component('StretchPosition');
        if (stretch != null) {
          if (node.pose.localPositionOverride != null) {
            throw UnsupportedError('frame_geometry_local_position_and_stretch');
          }
          final percent = node.pose.stretchPositionPercent!;
          final pivot = node.source.pivot[0];
          final oldLeft = _f(node.position[0] - _f(node.size[0] * pivot));
          final oldRight = _f(
            node.position[0] + _f(node.size[0] * _f(1 - pivot)),
          );
          final requestedRight = _f(-_f(percent / 100) * parentWidth);
          node.size[0] = _f(node.size[0] + _f(requestedRight - oldRight));
          node.position[0] = _f(oldLeft + _f(node.size[0] * pivot));
          node.dimensions(parentWidth, parentHeight);
        }
        final group = node.component('HorizontalLayoutGroup');
        if (group != null) {
          _placeHorizontal(node, children[node.source.id] ?? const [], group);
        }
      }
      for (final child in children[node.source.id] ?? const <_Node>[]) {
        visit(child, node.width, node.height, node.active);
      }
    }

    final root = nodes[source.rootNodeId]!;
    visit(root, actualCanvasWidth, actualCanvasHeight, true);
    return {
      'nodes': [for (final node in source.nodes) nodes[node.id]!.output()],
      'canvasWidth': actualCanvasWidth,
      'canvasHeight': actualCanvasHeight,
      'geometryContract': 'original-driven-rect-v1',
    };
  }

  static void _placeHorizontal(
    _Node group,
    List<_Node> allChildren,
    Map<String, Object?> raw,
  ) {
    if (const [
      'm_ChildControlWidth',
      'm_ChildControlHeight',
      'm_ChildScaleWidth',
      'm_ChildScaleHeight',
      'm_ReverseArrangement',
    ].any((field) => _flag(raw[field]))) {
      throw UnsupportedError('frame_geometry_controlled_group');
    }
    final children = allChildren.where((child) => child.pose.active).toList();
    final padding = _map(raw['m_Padding']);
    final left = _number(padding['m_Left']),
        right = _number(padding['m_Right']);
    final top = _number(padding['m_Top']),
        bottom = _number(padding['m_Bottom']);
    final spacing = _number(raw['m_Spacing']);
    final alignment = _number(raw['m_ChildAlignment']).toInt();
    if (alignment < 0 || alignment > 8) {
      throw const FormatException('frame_geometry_group_alignment');
    }
    final ax = _f((alignment % 3) / 2), ay = _f((alignment ~/ 3) / 2);
    final expandX = _flag(raw['m_ChildForceExpandWidth']),
        expandY = _flag(raw['m_ChildForceExpandHeight']);
    var preferred = _f(left + right);
    for (final child in children) {
      preferred = _f(preferred + _f(child.size[0] + spacing));
    }
    if (children.isNotEmpty) preferred = _f(preferred - spacing);
    final surplus = _f(group.width - preferred);
    final extra = expandX && children.isNotEmpty && surplus > 0
        ? _f(surplus / children.length)
        : 0.0;
    var cursor = surplus > 0 && !expandX ? _f(left + _f(surplus * ax)) : left;
    for (final child in children) {
      if (child.pose.localPositionOverride != null ||
          child.component('AspectRatioFitter') != null ||
          child.component('HorizontalLayoutGroup') != null) {
        throw UnsupportedError('frame_geometry_group_child_drive');
      }
      final allocated = _f(child.size[0] + extra);
      child.anchorsMin
        ..[0] = 0
        ..[1] = 1;
      child.anchorsMax
        ..[0] = 0
        ..[1] = 1;
      child.position[0] = _f(
        _f(cursor + _f(ax * _f(allocated - child.size[0]))) +
            _f(child.size[0] * child.source.pivot[0]),
      );
      cursor = _f(cursor + _f(allocated + spacing));
      final innerHeight = _f(group.height - _f(top + bottom));
      final maxHeight = expandY ? group.height : child.size[1];
      final required = innerHeight < child.size[1]
          ? child.size[1]
          : innerHeight > maxHeight
          ? maxHeight
          : innerHeight;
      final start = _f(
        top + _f(_f(group.height - _f(required + _f(top + bottom))) * ay),
      );
      final position = _f(start + _f(ay * _f(required - child.size[1])));
      child.position[1] = _f(
        -position - _f(child.size[1] * _f(1 - child.source.pivot[1])),
      );
    }
  }
}
