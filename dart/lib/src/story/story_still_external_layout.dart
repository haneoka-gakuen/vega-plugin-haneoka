import 'dart:math' as math;
import 'dart:typed_data';

Map<String, Object?> _map(Object? value) =>
    Map<String, Object?>.from(value as Map);
double _number(Object? value) => value is num && value.isFinite
    ? value.toDouble()
    : throw const FormatException('still_external_number');
String _id(Object? value) => _map(value)['m_PathID'].toString();
double _f(double value) => (Float32List(1)..[0] = value)[0];
List<double> _vector(Object? value, List<String> axes) {
  final data = _map(value);
  return List.unmodifiable([for (final axis in axes) _number(data[axis])]);
}

/// Bound original UI source records. Serialized canvas placeholders are replaced
/// by the Reference ScreenCanvas runtime root only at the canvas boundary.
final class StoryStillExternalLayoutSource {
  StoryStillExternalLayoutSource._({
    required this.sourceIdentity,
    required this.packetSHA256,
    required this.serializedFile,
    required this.canvasRectId,
    required this.scalerId,
    required this.viewComponentId,
    required this.targetId,
    required this.scaler,
    required this.canvas,
    required this.scriptIdentities,
    required this.nodes,
  });

  factory StoryStillExternalLayoutSource.fromPacket(
    Map<String, Object?> packet, {
    required String expectedSourceId,
  }) {
    if (packet['schema'] != 'haneoka-still-external-layout-v1' ||
        packet['sourceId'] != expectedSourceId ||
        packet['sourcePath'] is! String ||
        (packet['sourcePath'] as String).isEmpty ||
        packet['sourceHash'] is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(packet['sourceHash'] as String)) {
      throw const FormatException('still_external_formal_packet');
    }
    void requireLosslessPointers(Object? value) {
      if (value is Map) {
        for (final entry in value.entries) {
          if ((entry.key == 'm_PathID' || entry.key == 'pathId') &&
              (entry.value is! String ||
                  !RegExp(r'^-?[0-9]+$').hasMatch(entry.value as String))) {
            throw const FormatException('still_external_lossless_object_id');
          }
          requireLosslessPointers(entry.value);
        }
      } else if (value is List) {
        for (final child in value) {
          requireLosslessPointers(child);
        }
      }
    }

    requireLosslessPointers(packet['records']);
    final result = StoryStillExternalLayoutSource.fromRecords(
      sourceIdentity: expectedSourceId,
      packetSHA256: packet['recordsSHA256'] as String,
      serializedFile: packet['serializedFile'] as String,
      canvasRectId: packet['canvasRectId'] as String,
      scalerId: packet['scalerId'] as String,
      viewComponentId: packet['viewComponentId'] as String,
      records: (packet['records'] as List).map(_map),
    );
    // Current Still tween root world-rotation accessors bind identity parents.
    for (final node in result.nodes) {
      final q = node.rotation;
      if (q[0] != 0 || q[1] != 0 || q[2] != 0 || q[3].abs() != 1) {
        throw UnsupportedError('still_external_parent_rotation:${node.id}');
      }
    }
    return result;
  }

  factory StoryStillExternalLayoutSource.fromRecords({
    required String sourceIdentity,
    required String packetSHA256,
    required String serializedFile,
    required String canvasRectId,
    required String scalerId,
    required String viewComponentId,
    required Iterable<Map<String, Object?>> records,
  }) {
    if (sourceIdentity.isEmpty ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(packetSHA256)) {
      throw const FormatException('still_external_source_identity');
    }
    final byId = <String, Map<String, Object?>>{};
    for (final record in records) {
      if (record['serializedFile'] != serializedFile) {
        throw const FormatException('still_external_serialized_file');
      }
      final id = record['pathId'].toString();
      if (byId.containsKey(id)) {
        throw const FormatException('still_external_duplicate_record');
      }
      byId[id] = record;
    }
    Map<String, Object?> record(String id, String type) {
      final result = byId[id];
      if (result == null || result['type'] != type) {
        throw FormatException('still_external_missing_$type:$id');
      }
      return _map(result['data']);
    }

    final scriptIdentities = <String, Map<String, Object?>>{};
    String? script(Map<String, Object?> data) {
      final pointer = _map(data['m_Script']);
      final value = pointer['reference'];
      if (value is! Map) return null;
      final reference = _map(value);
      final scriptFile = reference['serializedFile'];
      final scriptPathId = reference['pathId'];
      final externalPath = reference['externalPath'];
      if (reference['status'] != 'resolved' ||
          reference['type'] != 'MonoScript' ||
          scriptFile is! String ||
          scriptFile.isEmpty ||
          scriptPathId is! String ||
          scriptPathId != _id(pointer) ||
          externalPath is! String ||
          !externalPath.endsWith('/$scriptFile')) {
        throw const FormatException('still_external_script_identity');
      }
      // The supplied packet contains resolved MonoScript name/file/path identity;
      // it has no original class or namespace fields.
      final className = reference['name'];
      if (className is! String || className.isEmpty) {
        throw const FormatException('still_external_script_class');
      }
      scriptIdentities['$scriptFile:$scriptPathId'] = Map.unmodifiable(
        reference,
      );
      return className;
    }

    final root = record(canvasRectId, 'RectTransform');
    final rootObject = record(_id(root['m_GameObject']), 'GameObject');
    final scaler = record(scalerId, 'MonoBehaviour');
    final view = record(viewComponentId, 'MonoBehaviour');
    if (script(view) != 'AdvStillView' ||
        script(scaler) != 'ClampedCanvasScaler' ||
        _id(scaler['m_GameObject']) != _id(root['m_GameObject']) ||
        _number(scaler['m_Enabled']) != 1 ||
        _number(scaler['m_UiScaleMode']) != 1 ||
        _number(view['m_Enabled']) != 1 ||
        rootObject['m_IsActive'] != true) {
      throw const FormatException('still_external_binding');
    }
    final targetId = _id(view['_target']);
    final chain = <StoryStillExternalNodeSource>[];
    final seen = <String>{};
    String cursor = targetId;
    while (cursor != canvasRectId) {
      if (!seen.add(cursor)) {
        throw const FormatException('still_external_parent_cycle');
      }
      final transform = record(cursor, 'RectTransform');
      final objectId = _id(transform['m_GameObject']);
      final object = record(objectId, 'GameObject');
      final componentIds = <String>[
        for (final c in object['m_Component'] as List)
          _id(_map(c)['component']),
      ];
      if (!componentIds.contains(cursor)) {
        throw const FormatException('still_external_transform_binding');
      }
      var alpha = 1.0;
      var hasCanvasGroup = false;
      for (final componentId in componentIds.where((id) => id != cursor)) {
        final component = byId[componentId];
        if (component == null) {
          throw const FormatException('still_external_missing_component');
        }
        final data = _map(component['data']);
        if (_id(data['m_GameObject']) != objectId) {
          throw const FormatException('still_external_component_object');
        }
        if (component['type'] == 'CanvasGroup') {
          if (_number(data['m_Enabled']) != 0) {
            if (hasCanvasGroup || data['m_IgnoreParentGroups'] != false) {
              throw const FormatException(
                'still_external_canvas_group_unsupported',
              );
            }
            hasCanvasGroup = true;
            alpha = _number(data['m_Alpha']);
          }
        } else if (componentId != viewComponentId ||
            script(data) != 'AdvStillView') {
          throw FormatException(
            'still_external_unsupported_component:$componentId',
          );
        }
      }
      chain.add(
        StoryStillExternalNodeSource._(
          id: cursor,
          parentId: _id(transform['m_Father']),
          active: object['m_IsActive'] == true,
          alpha: alpha,
          hasCanvasGroup: hasCanvasGroup,
          anchorMin: _vector(transform['m_AnchorMin'], ['x', 'y']),
          anchorMax: _vector(transform['m_AnchorMax'], ['x', 'y']),
          anchored: _vector(transform['m_AnchoredPosition'], ['x', 'y']),
          pivot: _vector(transform['m_Pivot'], ['x', 'y']),
          sizeDelta: _vector(transform['m_SizeDelta'], ['x', 'y']),
          rotation: _vector(transform['m_LocalRotation'], ['x', 'y', 'z', 'w']),
          scale: _vector(transform['m_LocalScale'], ['x', 'y', 'z']),
          localZ: _number(_map(transform['m_LocalPosition'])['z']),
        ),
      );
      cursor = chain.last.parentId;
    }
    if (chain.length < 2 ||
        _id(record(chain[1].id, 'RectTransform')['m_GameObject']) !=
            _id(view['m_GameObject'])) {
      throw const FormatException('still_external_view_target_parent');
    }
    Map<String, Object?>? canvas;
    var hasScaler = false;
    for (final c in rootObject['m_Component'] as List) {
      final componentId = _id(_map(c)['component']);
      final component = byId[componentId];
      if (component == null) {
        throw const FormatException('still_external_canvas_component');
      }
      final data = _map(component['data']);
      if (_id(data['m_GameObject']) != _id(root['m_GameObject'])) {
        throw const FormatException('still_external_canvas_component_object');
      }
      if (componentId == canvasRectId) continue;
      if (componentId == scalerId) {
        hasScaler = true;
        continue;
      }
      if (component['type'] == 'Canvas' && canvas == null) {
        canvas = data;
      } else if (component['type'] != 'MonoBehaviour' ||
          script(data) != 'GraphicRaycaster' ||
          _number(data['m_Enabled']) != 0) {
        throw FormatException(
          'still_external_unsupported_canvas_component:$componentId',
        );
      }
    }
    if (!hasScaler || canvas == null || _number(canvas['m_Enabled']) != 1) {
      throw const FormatException('still_external_canvas_binding');
    }
    final camera = _map(canvas['m_Camera']);
    final sortingOrder = _number(canvas['m_SortingOrder']);
    // Geometry admission is bounded to the actual camera-canvas contract.
    // Camera identity is retained; projection requires its separate source.
    if (_number(canvas['m_RenderMode']) != 1 ||
        sortingOrder != sortingOrder.truncateToDouble() ||
        canvas['m_OverrideSorting'] != false ||
        canvas['m_PixelPerfect'] != false ||
        canvas['m_OverridePixelPerfect'] != false ||
        _number(camera['m_FileID']) != 0 ||
        _id(camera) == '0' ||
        _number(canvas['m_PlaneDistance']) <= 0 ||
        _number(scaler['m_ReferencePixelsPerUnit']) <= 0) {
      throw const FormatException('still_external_canvas_contract');
    }
    return StoryStillExternalLayoutSource._(
      sourceIdentity: sourceIdentity,
      packetSHA256: packetSHA256,
      serializedFile: serializedFile,
      canvasRectId: canvasRectId,
      scalerId: scalerId,
      viewComponentId: viewComponentId,
      targetId: targetId,
      scaler: Map.unmodifiable(scaler),
      canvas: Map.unmodifiable(canvas),
      scriptIdentities: Map.unmodifiable(scriptIdentities),
      nodes: List.unmodifiable(chain.reversed),
    );
  }

  final String sourceIdentity, packetSHA256, serializedFile;
  final String canvasRectId, scalerId, viewComponentId, targetId;
  final Map<String, Object?> scaler, canvas;
  final Map<String, Map<String, Object?>> scriptIdentities;
  final List<StoryStillExternalNodeSource> nodes;
}

final class StoryStillExternalNodeSource {
  StoryStillExternalNodeSource._({
    required this.id,
    required this.parentId,
    required this.active,
    required this.alpha,
    required this.hasCanvasGroup,
    required this.anchorMin,
    required this.anchorMax,
    required this.anchored,
    required this.pivot,
    required this.sizeDelta,
    required this.rotation,
    required this.scale,
    required this.localZ,
  });
  final String id, parentId;
  final bool active, hasCanvasGroup;
  final double alpha, localZ;
  final List<double> anchorMin,
      anchorMax,
      anchored,
      pivot,
      sizeDelta,
      rotation,
      scale;
}

/// Local rectangular geometry and full row-major 3x4 canvas transform.
final class StoryStillExternalNodeLayout {
  StoryStillExternalNodeLayout({
    required this.id,
    required this.parentId,
    required List<double> rect,
    required List<double> pivot,
    required List<double> matrix3,
    required List<double> affine,
    required this.active,
    required this.alpha,
    required this.planar,
    required this.containedScale,
  }) : rect = List.unmodifiable(rect),
       pivot = List.unmodifiable(pivot),
       matrix3 = List.unmodifiable(matrix3),
       affine = List.unmodifiable(affine);
  final String id, parentId;
  final List<double> rect, pivot, matrix3, affine;
  final bool active, planar;
  final double alpha, containedScale;
}

final class StoryStillExternalLayout {
  StoryStillExternalLayout._({
    required this.source,
    required this.physicalWidth,
    required this.physicalHeight,
    required this.logicalWidth,
    required this.logicalHeight,
    required this.canvasScale,
    required this.runtimeRoot,
    required this.nodes,
  });
  final StoryStillExternalLayoutSource source;
  final double physicalWidth,
      physicalHeight,
      logicalWidth,
      logicalHeight,
      canvasScale;
  final StoryStillExternalNodeLayout runtimeRoot;
  final List<StoryStillExternalNodeLayout> nodes;
  StoryStillExternalNodeLayout get target => nodes.last;
  StoryStillExternalNodeLayout get targetParent =>
      nodes.length > 1 ? nodes[nodes.length - 2] : runtimeRoot;

  /// Reference STILL_BASE_SIZE is a consumer contract, independent of viewport.
  static const stillBaseWidth = 1920.0, stillBaseHeight = 1080.0;

  factory StoryStillExternalLayout.resolve({
    required StoryStillExternalLayoutSource source,
    required double physicalWidth,
    required double physicalHeight,
  }) {
    if (!physicalWidth.isFinite ||
        !physicalHeight.isFinite ||
        physicalWidth <= 0 ||
        physicalHeight <= 0) {
      throw const FormatException('still_external_viewport');
    }
    final scaler = source.scaler;
    final reference = _vector(scaler['m_ReferenceResolution'], ['x', 'y']);
    final threshold = _number(scaler['_maxAspectThreshold']);
    if (reference.any((v) => v <= 0) || threshold <= 0) {
      throw const FormatException('still_external_scaler_extent');
    }
    final match = _number(scaler['m_MatchWidthOrHeight']).clamp(0.0, 1.0);
    final rx = physicalWidth / reference[0], ry = physicalHeight / reference[1];
    var scale = switch (_number(scaler['m_ScreenMatchMode'])) {
      0 =>
        math
            .pow(
              2,
              (1 - match) * (math.log(rx) / math.ln2) +
                  match * (math.log(ry) / math.ln2),
            )
            .toDouble(),
      1 => math.min(rx, ry),
      2 => math.max(rx, ry),
      _ => 1.0,
    };
    final aspect = physicalWidth / physicalHeight;
    if (aspect > threshold) scale = threshold / aspect;
    final w = physicalWidth / scale, h = physicalHeight / scale;
    final root = StoryStillExternalNodeLayout(
      id: source.canvasRectId,
      parentId: '',
      rect: [_f(-w / 2), _f(-h / 2), _f(w), _f(h)],
      pivot: [.5, .5],
      matrix3: [1, 0, 0, w / 2, 0, 1, 0, h / 2, 0, 0, 1, 0],
      affine: [1, 0, 0, 1, w / 2, h / 2],
      active: true,
      alpha: 1,
      planar: true,
      containedScale: 1,
    );
    var parent = root;
    final layouts = <StoryStillExternalNodeLayout>[];
    for (final node in source.nodes) {
      if (node.parentId != parent.id) {
        throw const FormatException('still_external_chain');
      }
      final pr = parent.rect;
      final minX = _f(pr[0] + _f(node.anchorMin[0] * pr[2]));
      final maxX = _f(pr[0] + _f(node.anchorMax[0] * pr[2]));
      final minY = _f(pr[1] + _f(node.anchorMin[1] * pr[3]));
      final maxY = _f(pr[1] + _f(node.anchorMax[1] * pr[3]));
      final nw = _f(_f(maxX - minX) + node.sizeDelta[0]);
      final nh = _f(_f(maxY - minY) + node.sizeDelta[1]);
      final px = _f(
        _f(minX + _f(_f(maxX - minX) * node.pivot[0])) + node.anchored[0],
      );
      final py = _f(
        _f(minY + _f(_f(maxY - minY) * node.pivot[1])) + node.anchored[1],
      );
      var contained = 1.0;
      final s = node.scale.toList();
      if (node.id == source.targetId && pr[2] > 0 && pr[3] > 0) {
        contained = _f(
          math.min(_f(pr[2] / stillBaseWidth), _f(pr[3] / stillBaseHeight)),
        );
        s.setAll(0, [contained, contained, 1]);
      }
      final q = node.rotation, x = q[0], y = q[1], z = q[2], qw = q[3];
      final x2 = _f(x * 2), y2 = _f(y * 2), z2 = _f(z * 2);
      final xx = _f(x * x2), yy = _f(y * y2), zz = _f(z * z2);
      final xy = _f(x * y2), wz = _f(qw * z2);
      final localAffine = [
        _f(_f(1 - _f(yy + zz)) * s[0]),
        _f(_f(xy + wz) * s[0]),
        _f(_f(xy - wz) * s[1]),
        _f(_f(1 - _f(xx + zz)) * s[1]),
        px,
        py,
      ];
      final local3 = [
        (1 - 2 * (y * y + z * z)) * s[0],
        2 * (x * y - qw * z) * s[1],
        2 * (x * z + qw * y) * s[2],
        px,
        2 * (x * y + qw * z) * s[0],
        (1 - 2 * (x * x + z * z)) * s[1],
        2 * (y * z - qw * x) * s[2],
        py,
        2 * (x * z - qw * y) * s[0],
        2 * (y * z + qw * x) * s[1],
        (1 - 2 * (x * x + y * y)) * s[2],
        node.localZ,
      ];
      final layout = StoryStillExternalNodeLayout(
        id: node.id,
        parentId: node.parentId,
        rect: [_f(-node.pivot[0] * nw), _f(-node.pivot[1] * nh), nw, nh],
        pivot: node.pivot,
        matrix3: _multiply3(parent.matrix3, local3),
        affine: _multiplyAffine(parent.affine, localAffine),
        active: parent.active && node.active,
        alpha: node.hasCanvasGroup
            ? _f(parent.alpha * node.alpha)
            : parent.alpha,
        planar:
            parent.planar &&
            node.localZ == 0 &&
            x.abs() <= 1e-7 &&
            y.abs() <= 1e-7,
        containedScale: contained,
      );
      layouts.add(layout);
      parent = layout;
    }
    return StoryStillExternalLayout._(
      source: source,
      physicalWidth: physicalWidth,
      physicalHeight: physicalHeight,
      logicalWidth: w,
      logicalHeight: h,
      canvasScale: scale,
      runtimeRoot: root,
      nodes: List.unmodifiable(layouts),
    );
  }
}

List<double> _multiply3(List<double> a, List<double> b) {
  final result = List<double>.filled(12, 0);
  for (var r = 0; r < 3; r++) {
    for (var c = 0; c < 3; c++) {
      result[r * 4 + c] =
          a[r * 4] * b[c] + a[r * 4 + 1] * b[4 + c] + a[r * 4 + 2] * b[8 + c];
    }
    result[r * 4 + 3] =
        a[r * 4] * b[3] +
        a[r * 4 + 1] * b[7] +
        a[r * 4 + 2] * b[11] +
        a[r * 4 + 3];
  }
  return result;
}

List<double> _multiplyAffine(List<double> a, List<double> b) => [
  a[0] * b[0] + a[2] * b[1],
  a[1] * b[0] + a[3] * b[1],
  a[0] * b[2] + a[2] * b[3],
  a[1] * b[2] + a[3] * b[3],
  a[0] * b[4] + a[2] * b[5] + a[4],
  a[1] * b[4] + a[3] * b[5] + a[5],
];
