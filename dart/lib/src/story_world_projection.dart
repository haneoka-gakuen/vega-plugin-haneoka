import 'dart:typed_data';

import 'package:render_contracts/math.dart';

/// Numeric scene input supplied from the actual source camera/field/stage.
/// Resource names, native command IDs and release transport stay with the host.
final class HaneokaStageLayout {
  HaneokaStageLayout({
    required this.fieldPosition,
    required this.fieldScale,
    required this.focusSets,
    required this.fieldOfView,
    required this.initialCameraPosition,
    required this.initialCameraEuler,
    required this.backgroundPosition,
    required this.backgroundScale,
  });
  final Float32List fieldPosition,
      initialCameraPosition,
      initialCameraEuler,
      backgroundPosition;
  final double fieldScale, fieldOfView, backgroundScale;
  final List<List<Float32List>> focusSets;
}

final class HaneokaWorldProjection {
  HaneokaWorldProjection({
    required this.near,
    required this.far,
    required this.defaultFieldOfView,
    required List<Float32List> sourceSlots,
    required List<Float32List> sourceFocusPoints,
    required Float32List sourceFieldPosition,
  }) : fieldOfView = defaultFieldOfView,
       fieldPosition = Float32List.fromList(sourceFieldPosition),
       slots = [for (final slot in sourceSlots) Float32List.fromList(slot)],
       focusPoints = [
         for (final point in sourceFocusPoints) Float32List.fromList(point),
       ] {
    if (!near.isFinite ||
        !far.isFinite ||
        near <= 0 ||
        far <= near ||
        !defaultFieldOfView.isFinite ||
        defaultFieldOfView <= 0 ||
        defaultFieldOfView >= 180) {
      throw ArgumentError('story_scene_lens');
    }
    _vector(fieldPosition);
    for (final slot in slots) {
      _vector(slot);
    }
    for (final point in focusPoints) {
      _vector(point);
    }
  }
  final double near, far, defaultFieldOfView;
  double fieldOfView, zoomRatio = 1, slotScale = 1, backgroundScale = 1;
  final cameraPosition = Float32List(3), cameraEuler = Float32List(3);
  final cameraOffset = Float32List(3);
  final fieldEuler = Float32List(3), backgroundEuler = Float32List(3);
  final fieldOffset = Float32List(3), backgroundOffset = Float32List(3);
  final Float32List fieldPosition;
  final backgroundPosition = Float32List(3);
  final List<Float32List> slots;
  final List<Float32List> focusPoints;
  late final slotEuler = [for (final _ in slots) Float32List(3)];
  int _width = 0, _height = 0;

  void resize(int physicalWidth, int physicalHeight) {
    if (physicalWidth <= 0 || physicalHeight <= 0) {
      throw ArgumentError('story_scene_extent');
    }
    _width = physicalWidth;
    _height = physicalHeight;
  }

  void selectStage(HaneokaStageLayout stage, {int focusSet = 0}) {
    _vector(stage.fieldPosition);
    _vector(stage.initialCameraPosition);
    _vector(stage.initialCameraEuler);
    _vector(stage.backgroundPosition);
    if (stage.fieldScale <= 0 ||
        !stage.fieldScale.isFinite ||
        stage.backgroundScale <= 0 ||
        !stage.backgroundScale.isFinite ||
        stage.fieldOfView <= 0 ||
        stage.fieldOfView >= 180 ||
        stage.focusSets.isEmpty) {
      throw const FormatException('story_scene_stage');
    }
    final points =
        stage.focusSets[focusSet >= 0 && focusSet < stage.focusSets.length
            ? focusSet
            : 0];
    if (points.length < slots.length * 2 - 1) {
      throw const FormatException('story_scene_focus_points');
    }
    for (var i = 0; i < slots.length; i++) {
      _vector(points[i * 2]);
      slots[i].setAll(0, points[i * 2]);
      slotEuler[i][1] = 0;
    }
    for (var i = 0; i < points.length; i++) {
      _vector(points[i]);
      focusPoints[i].setAll(0, points[i]);
    }
    fieldPosition.setAll(0, stage.fieldPosition);
    slotScale = stage.fieldScale;
    backgroundPosition.setAll(0, stage.backgroundPosition);
    backgroundScale = stage.backgroundScale;
    fieldOfView = stage.fieldOfView;
    cameraEuler[1] = 0;
    if (_lengthSquared(stage.initialCameraPosition) >= 1e-10) {
      cameraPosition.setAll(0, stage.initialCameraPosition);
    }
    if (_lengthSquared(stage.initialCameraEuler) >= 1e-10) {
      cameraEuler.setAll(0, stage.initialCameraEuler);
    }
  }

  /// Changing a stage preset replaces anchors without resetting the camera.
  void selectFocusSet(HaneokaStageLayout stage, int index) {
    final points = stage
        .focusSets[index >= 0 && index < stage.focusSets.length ? index : 0];
    if (points.length != focusPoints.length)
      throw const FormatException('story_focus_preset_size');
    for (var i = 0; i < points.length; i++) {
      _vector(points[i]);
      focusPoints[i].setAll(0, points[i]);
    }
    for (var i = 0; i < slots.length; i++) slots[i].setAll(0, points[i * 2]);
  }

  void clearStage() {
    fieldPosition.fillRange(0, 3, 0);
    for (final slot in slots) {
      slot.fillRange(0, 3, 0);
    }
    for (final point in focusPoints) {
      point.fillRange(0, 3, 0);
    }
    slotScale = 1;
    for (final euler in slotEuler) {
      euler.fillRange(0, 3, 0);
    }
    fieldOfView = defaultFieldOfView;
    zoomRatio = 1;
    cameraPosition.fillRange(0, 3, 0);
    cameraEuler.fillRange(0, 3, 0);
  }

  void setYaw({
    double? camera,
    double? characterField,
    double? backgroundField,
  }) {
    for (final value in [camera, characterField, backgroundField]) {
      if (value != null && !value.isFinite) {
        throw ArgumentError('story_scene_yaw');
      }
    }
    if (camera != null) cameraEuler[1] = camera;
    if (characterField != null) fieldEuler[1] = characterField;
    if (backgroundField != null) backgroundEuler[1] = backgroundField;
  }

  Float32List clipFromModel({
    required int slotIndex,
    required Float32List basePosition,
    required double baseScale,
  }) {
    return _nativeDepth(
      _multiply(_glCamera(), _modelWorld(slotIndex, basePosition, baseScale)),
    );
  }

  Float32List modelWorld({
    required int slotIndex,
    required Float32List basePosition,
    required double baseScale,
  }) => _modelWorld(slotIndex, basePosition, baseScale);

  Float32List focusPointWorld(int positionType) {
    if (positionType < 1 || positionType > focusPoints.length) {
      return Float32List(3);
    }
    final point = focusPoints[positionType - 1];
    final m = _trs(fieldPosition, fieldEuler, 1, offset: fieldOffset);
    return Float32List.fromList([
      for (var row = 0; row < 3; row++)
        m[row] * point[0] +
            m[4 + row] * point[1] +
            m[8 + row] * point[2] +
            m[12 + row],
    ]);
  }

  Float32List modelPointWorld({
    required int slotIndex,
    required Float32List basePosition,
    required double baseScale,
    required Float32List point,
  }) {
    _vector(point);
    final m = _modelWorld(slotIndex, basePosition, baseScale);
    return Float32List.fromList([
      for (var row = 0; row < 3; row++)
        m[row] * point[0] +
            m[4 + row] * point[1] +
            m[8 + row] * point[2] +
            m[12 + row],
    ]);
  }

  Float32List _modelWorld(
    int slotIndex,
    Float32List basePosition,
    double baseScale,
  ) {
    if (slotIndex < 0 ||
        slotIndex >= slots.length ||
        !baseScale.isFinite ||
        baseScale <= 0) {
      throw ArgumentError('story_model_slot');
    }
    _vector(basePosition);
    final field = _trs(fieldPosition, fieldEuler, 1, offset: fieldOffset);
    final slot = _trs(slots[slotIndex], slotEuler[slotIndex], slotScale);
    final model = _trs(basePosition, Float32List(3), baseScale);
    return _multiply(_multiply(field, slot), model);
  }

  Float32List clipFromBackground({
    required Float32List localPosition,
    required Float32List localEuler,
    required double localScale,
  }) {
    _vector(localPosition);
    _vector(localEuler);
    return _nativeDepth(
      _multiply(
        _glCamera(),
        _multiply(
          _trs(
            backgroundPosition,
            backgroundEuler,
            1,
            offset: backgroundOffset,
          ),
          _trs(localPosition, localEuler, localScale * backgroundScale),
        ),
      ),
    );
  }

  Float32List _glCamera() {
    if (_width <= 0 || _height <= 0 || zoomRatio <= 0 || !zoomRatio.isFinite) {
      throw StateError('story_scene_camera_not_configured');
    }
    final angle = fieldOfView / zoomRatio;
    if (!angle.isFinite || angle <= 0 || angle >= 180) {
      throw ArgumentError('story_scene_fov');
    }
    final projection = perspectiveMatrix4(
      fovYDegrees: angle,
      aspectRatio: _width / _height,
      near: near,
      far: far,
    );
    final inverse = inverseRigidMatrix4(
      _trs(cameraPosition, cameraEuler, 1, offset: cameraOffset),
    );
    // Unity world-to-camera handedness before the Reference GL projection.
    for (var column = 0; column < 4; column++) {
      inverse[column * 4 + 2] *= -1;
    }
    return _multiply(projection, inverse);
  }

  Map<String, Object?> get observation => {
    'physicalExtent': [_width, _height],
    'fieldOfView': fieldOfView,
    'zoomRatio': zoomRatio,
    'cameraPosition': cameraPosition.toList(),
    'cameraOffset': cameraOffset.toList(),
    'cameraEuler': cameraEuler.toList(),
    'fieldPosition': fieldPosition.toList(),
    'fieldOffset': fieldOffset.toList(),
    'backgroundOffset': backgroundOffset.toList(),
    'fieldEuler': fieldEuler.toList(),
    'slotScale': slotScale,
    'slots': slots.map((v) => v.toList()).toList(),
    'focusPoints': focusPoints.map((v) => v.toList()).toList(),
    'slotEuler': slotEuler.map((v) => v.toList()).toList(),
    'depthConvention': 'Reference GL clip remapped to Native GPU zero-to-one',
  };
}

void _vector(Float32List value) {
  if (value.length != 3 || value.any((v) => !v.isFinite)) {
    throw ArgumentError('story_scene_vector');
  }
}

double _lengthSquared(Float32List value) =>
    value.fold(0.0, (sum, v) => sum + v * v);
Float32List _nativeDepth(Float32List gl) => remapClipDepthZeroToOne(gl);

Float32List _multiply(Float32List a, Float32List b) => multiplyMatrix4(a, b);

Float32List _trs(
  Float32List position,
  Float32List euler,
  double scale, {
  Float32List? offset,
}) => trsMatrix4(
  translation: Float32List.fromList([
    for (var axis = 0; axis < 3; axis++) position[axis] + (offset?[axis] ?? 0),
  ]),
  quaternion: eulerZxyDegreesToQuaternion(euler),
  scale: Float32List.fromList([scale, scale, scale]),
);
