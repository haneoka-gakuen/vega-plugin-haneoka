import 'dart:math' as math;
import 'dart:typed_data';

import 'package:vega_plugin_cubism/parameter_loop.dart';

import 'cubism_parameter_state.dart';
import 'cubism_unity_clip.dart';
import 'cubism_unity_physics.dart';
import 'cubism_unity_prefab.dart';
import 'native_cubism_core.dart';
import 'harmonic_motion.dart';

/// One evaluated original Cubism prefab. Its caller owns the accepted scene
/// clock, source epoch, texture resources and placement in the render graph.
final class NativeCubismModelHost {
  NativeCubismModelHost({
    required NativeCubismCore core,
    required Uint8List mocBytes,
    required List<Map> prefabRecords,
    required this.randomUnit,
    this.breathMotionEnabled = true,
    double initialSeconds = 0,
    int initialFrame = -1,
  }) : prefab = NativeCubismUnityPrefab(prefabRecords) {
    if (!initialSeconds.isFinite || initialSeconds < 0 || initialFrame < -1) {
      throw ArgumentError('cubism_initial_clock');
    }
    _ownedSeconds = initialSeconds;
    _time = cubismF32(initialSeconds);
    _frame = initialFrame;
    model = core.createModel(mocBytes);
    try {
      parameters = NativeCubismParameterState(model);
      _parameterLoop = CubismParameterLoop(
        restoreParameters: parameters.restore,
        saveParameters: parameters.save,
        overwrite: parameters.overwrite,
      );
      final character = prefab.component('Live2DCharacter');
      defaultMotion = character['DefaultMotionName'] as String;
      defaultExpression = character['DefaultExpressionName'] as String;
      for (var i = 0; i < prefab.fadeMotions.length; i++) {
        final id = prefab.fadeInstanceIds[i];
        if (_fadeData.containsKey(id)) {
          throw const FormatException('cubism_fade_instance_duplicate');
        }
        _fadeData[id] = _FadeData(prefab.fadeMotions[i], parameters);
      }
      for (final clip in prefab.clips.values) {
        if (!_fadeData.containsKey(clip.instanceId)) {
          throw FormatException('cubism_fade_instance_missing:${clip.name}');
        }
      }
      _expressions = [
        for (final source in prefab.expressions)
          _ExpressionData(source, parameters),
      ];
      final authoredNames = (character['_expressionList'] as List)
          .cast<String>();
      if (authoredNames.length > _expressions.length) {
        throw const FormatException('cubism_expression_order');
      }
      for (var i = 0; i < authoredNames.length; i++) {
        if (authoredNames[i] != _expressions[i].name) {
          throw const FormatException('cubism_expression_order');
        }
      }
      _eyeTags = _tagged('CubismEyeBlinkParameter')
          .map((row) => parameters.require(row.$1))
          .toList();
      _blinkNeutralTargets = List.unmodifiable({
        ..._eyeTags,
        if (parameters.indices['ParamEyeLOpen'] case final int index) index,
        if (parameters.indices['ParamEyeROpen'] case final int index) index,
      });
      _mouthTags = _tagged('CubismMouthParameter')
          .where((row) => row.$1 == 'ParamMouthOpenY')
          .map((row) => parameters.require(row.$1))
          .toList();
      final eye = prefab.component('CubismEyeBlinkController'),
          mouth = prefab.component('CubismMouthController');
      if (eye['BlendMode'] != 2 || mouth['BlendMode'] != 0) {
        throw UnsupportedError('cubism_controller_blend');
      }
      fields['eyeOpening'] = _number(eye['EyeOpening']);
      fields['mouthOpening'] = _number(mouth['MouthOpening']);
      fields['renderOpacity'] = _number(
        prefab.component('CubismRenderController')['Opacity'],
      );
      final harmonicController = prefab.component(
        'CubismHarmonicMotionController',
      );
      _harmonicBlendMode = harmonicController['BlendMode'] as int;
      if (_harmonicBlendMode < 0 || _harmonicBlendMode > 2) {
        throw UnsupportedError('cubism_harmonic_blend');
      }
      _harmonicEnabled =
          breathMotionEnabled &&
          (harmonicController['m_Enabled'] == 1 ||
              harmonicController['m_Enabled'] == true);
      _harmonics = [
        for (final row in _tagged('CubismHarmonicMotionParameter'))
          _Harmonic(row.$2, parameters.require(row.$1)),
      ];
      _harmonicRates = (harmonicController['ChannelTimescales'] as List)
          .map(_number)
          .toList();
      final blink = prefab.component('CubismAutoEyeBlinkInput');
      _autoEyeBlink = blink['m_Enabled'] == 1 || blink['m_Enabled'] == true;
      _blinkBeforeStop = _autoEyeBlink;
      _blinkMean = _number(blink['Mean']);
      _blinkDeviation = _number(blink['MaximumDeviation']);
      _blinkRate = _number(blink['Timescale']);
      _scheduleBlink();
      final physics = prefab.rootComponents['CubismPhysicsController'];
      _physics = physics == null
          ? null
          : NativeCubismUnityPhysics(physics['_rig'] as Map, parameters);
      _physics?.stabilize();
      parameters.writeCore();
      _pendingDrawables = model.evaluate();
      _drawables = [for (final row in _pendingDrawables) _DrawablePair(row)];
      final masks = _pendingDrawables.expand((row) => row.masks).toSet();
      for (final row in _drawables) {
        row.maskSource = masks.contains(row.source.sourceIndex);
      }
      if (defaultMotion.isNotEmpty) {
        playMotion(defaultMotion, fade: -1, repeat: true);
      }
      if (defaultExpression.isNotEmpty) {
        playExpression(defaultExpression, fade: -1);
      }
    } catch (_) {
      model.dispose();
      rethrow;
    }
  }
  final NativeCubismUnityPrefab prefab;
  final double Function() randomUnit;
  final bool breathMotionEnabled;
  late final NativeCubismModel model;
  late final NativeCubismParameterState parameters;
  late final String defaultMotion, defaultExpression;
  final fields = <String, double>{};
  final _sampledParameters = <String, double>{};
  final _fadeData = <int, _FadeData>{};
  final _playing = <_Playing>[];
  late final CubismParameterLoop _parameterLoop;
  final _parameterLoopClips = <String, CubismParameterLoopClip>{};
  late final List<_ExpressionData> _expressions;
  final _expressionPlaying = <_ExpressionPlaying>[];
  final _expressionValues = <int, _ExpressionValue>{};
  late final List<int> _eyeTags, _mouthTags, _blinkNeutralTargets;
  late final List<_Harmonic> _harmonics;
  late final int _harmonicBlendMode;
  late final bool _harmonicEnabled;
  late final List<double> _harmonicRates;
  late final double _blinkMean, _blinkDeviation, _blinkRate;
  double _blinkCountdown = 0, _blinkTime = 0, _blinkStart = 0;
  int _blinkPhase = 0;
  bool _autoEyeBlink = true, _eyeBlinkStopped = false, _blinkBeforeStop = true;
  double _blinkStopStart = 1, _blinkStopElapsed = 0, _blinkStopDuration = 0;
  NativeCubismUnityPhysics? _physics;
  late List<NativeCubismDrawable> _pendingDrawables;
  late final List<_DrawablePair> _drawables;
  double _time = 0, _ownedSeconds = 0, _sourcePausedSeconds = 0;
  int _frame = -1;
  bool _disposed = false,
      visible = false,
      _repeatMotion = true,
      _paused = false,
      _sourcePaused = false;
  (String, double, bool)? _pendingMotion;
  (String, double)? _pendingExpression;
  // Empty name is the retained Stop request; null means no retained request.
  (String, double)? _pendingParameterLoop;
  double motionSpeed = 1;
  double? _lookX, _lookY, _angleX, _bodyAngleX;
  double? _headAngleBase, _bodyAngleBase;

  (double, double) get eyePosition {
    final x = parameters.indices['ParamEyeBallX'];
    final y = parameters.indices['ParamEyeBallY'];
    return (
      x == null ? 0 : parameters.values[x],
      y == null ? 0 : parameters.values[y],
    );
  }

  void setEyeLook(double? x, double? y) {
    _lookX = x;
    _lookY = y;
  }

  /// SmoothChangeToLook's zero-duration path updates deformation immediately.
  void forceEyeLook(double x, double y) {
    _assertLive();
    setEyeLook(x, y);
    final eyeX = parameters.indices['ParamEyeBallX'];
    final eyeY = parameters.indices['ParamEyeBallY'];
    if (eyeX != null) parameters.overwrite(eyeX, x);
    if (eyeY != null) parameters.overwrite(eyeY, y);
    _forceDeformation();
  }

  void _forceDeformation() {
    parameters.writeCore();
    _pendingDrawables = model.evaluate();
    for (var i = 0; i < _drawables.length; i++) {
      _drawables[i].accept(_pendingDrawables[i]);
    }
  }

  void setAngleOffsets(double? head, double? body) {
    _angleX = head;
    _bodyAngleX = body;
  }

  void forceAngleOffsets(double head, double body) {
    _assertLive();
    final headIndex = parameters.indices['ParamAngleX'];
    final bodyIndex =
        parameters.indices['ParamBodyAngleXAdd'] ??
        parameters.indices['ParamBodyAngleX'];
    if (_headAngleBase != null && headIndex != null) {
      parameters.values[headIndex] = _headAngleBase!;
    }
    if (_bodyAngleBase != null && bodyIndex != null) {
      parameters.values[bodyIndex] = _bodyAngleBase!;
    }
    setAngleOffsets(head, body);
    _applyAngleOffsets();
    _forceDeformation();
  }

  void _applyAngleOffsets() {
    _headAngleBase = _bodyAngleBase = null;
    final angle = parameters.indices['ParamAngleX'];
    if (_angleX != null && angle != null) {
      _headAngleBase = parameters.values[angle];
      parameters.add(angle, _angleX!);
    }
    final bodyAdd = parameters.indices['ParamBodyAngleXAdd'];
    final body = parameters.indices['ParamBodyAngleX'];
    if (_bodyAngleX != null) {
      if (bodyAdd != null) {
        _bodyAngleBase = parameters.values[bodyAdd];
        parameters.overwrite(bodyAdd, _bodyAngleX!);
      } else if (body != null) {
        _bodyAngleBase = parameters.values[body];
        parameters.add(body, _bodyAngleX!);
      }
    }
  }

  _Playing? _animator;
  int _expressionIndex = -1, _lastExpressionIndex = -1;
  double _expressionFade = -1;

  Map<String, Object?> get capability => Map.unmodifiable({
    ...model.capability,
    'originalUnityClipCount': prefab.clips.length,
    'originalPhysics': _physics != null,
    'motionSyncVoice': _voiceParameters.isNotEmpty,
    'clockOwner': 'caller-accepted-scene-step',
  });
  double get gameTime => _time;
  int get acceptedFrame => _frame;
  List<(int, double, double)> _voiceParameters = const [];
  double _voiceWeight = 1;

  Map<String, double> parameterValues(Iterable<String> ids) => {
    for (final id in ids)
      if (parameters.indices[id] case final int index)
        id: parameters.values[index],
  };

  /// Voice analysis supplies authored parameter values and its neutral map.
  /// The model captures the current motion/expression base at evaluation time.
  void setVoiceParameters(
    Map<String, double>? analyzed, {
    Map<String, double> neutral = const {},
    double weight = 1,
  }) {
    _assertLive();
    if (!weight.isFinite || weight < 0) {
      throw ArgumentError('cubism_voice_weight');
    }
    _voiceParameters = analyzed == null
        ? const []
        : List.unmodifiable([
            for (final entry in analyzed.entries)
              if (parameters.indices[entry.key] case final int index)
                (index, _number(entry.value), _number(neutral[entry.key] ?? 0)),
          ]);
    _voiceWeight = cubismF32(weight);
  }

  Map<String, Object?> snapshotData() {
    _assertLive();
    return {
      'version': 1,
      'parameters': model.parameters.keys.toList(),
      'parts': model.parts.keys.toList(),
      'values': parameters.values.toList(),
      'saved': parameters.saved.toList(),
      'partValues': parameters.parts.toList(),
      'savedParts': parameters.savedParts.toList(),
      'fields': Map<String, double>.of(fields),
      'sampled': Map<String, double>.of(_sampledParameters),
      'playing': [
        for (final row in _playing)
          {
            'clip': row.clip.name,
            'start': row.fadeStart,
            'speed': row.speed,
            'fadeIn': row.fadeIn,
            'ends': row.ends,
            'clipTime': row.clipTime,
          },
      ],
      'animator': _animator == null ? -1 : _playing.indexOf(_animator!),
      'expressions': [
        for (final row in _expressionPlaying)
          {
            'name': row.source.name,
            'elapsed': row.elapsed,
            'end': row.end,
            'weight': row.weight,
          },
      ],
      'expressionValues': {
        for (final entry in _expressionValues.entries)
          '${entry.key}': [
            entry.value.add,
            entry.value.multiply,
            entry.value.override,
          ],
      },
      'harmonics': [for (final row in _harmonics) row.elapsed],
      'harmonicsRange': [for (final row in _harmonics) row.effectiveRange],
      'physics': _physics?.snapshotData(),
      'pending': [
        for (final row in _pendingDrawables)
          {
            'sourceIndex': row.sourceIndex,
            'renderOrder': row.renderOrder,
            'opacity': row.opacity,
            'flags': row.dynamicFlags,
            'visible': row.visible,
            'positions': row.positions.toList(),
            'multiply': row.multiplyColor.toList(),
            'screen': row.screenColor.toList(),
          },
      ],
      'drawables': [for (final row in _drawables) row.snapshotData()],
      'clock': [_time, _ownedSeconds, _frame, _sourcePausedSeconds],
      'controls': [visible, _repeatMotion, _paused, motionSpeed, _sourcePaused],
      'pendingMotion': _pendingMotion == null
          ? null
          : [_pendingMotion!.$1, _pendingMotion!.$2, _pendingMotion!.$3],
      'pendingExpression': _pendingExpression == null
          ? null
          : [_pendingExpression!.$1, _pendingExpression!.$2],
      'parameterLoop': _parameterLoop.snapshot()?.toData(),
      'pendingParameterLoop': _pendingParameterLoop == null
          ? null
          : [_pendingParameterLoop!.$1, _pendingParameterLoop!.$2],
      'voiceParameters': [
        for (final row in _voiceParameters) [row.$1, row.$2, row.$3],
      ],
      'voiceWeight': _voiceWeight,
      'gaze': [
        _lookX,
        _lookY,
        _angleX,
        _bodyAngleX,
        _headAngleBase,
        _bodyAngleBase,
      ],
      'blink': [_blinkCountdown, _blinkTime, _blinkStart, _blinkPhase],
      'blinkControl': [
        _autoEyeBlink,
        _eyeBlinkStopped,
        _blinkBeforeStop,
        _blinkStopStart,
        _blinkStopElapsed,
        _blinkStopDuration,
      ],
      'expressionControl': [
        _expressionIndex,
        _lastExpressionIndex,
        _expressionFade,
      ],
    };
  }

  void restoreData(Map data) {
    _assertLive();
    final ids = data['parameters'] as List, partIds = data['parts'] as List;
    if (data['version'] != 1 ||
        ids.length != model.parameters.length ||
        partIds.length != model.parts.length ||
        !List.generate(
          ids.length,
          (i) => ids[i] == model.parameters.keys.elementAt(i),
        ).every((v) => v) ||
        !List.generate(
          partIds.length,
          (i) => partIds[i] == model.parts.keys.elementAt(i),
        ).every((v) => v)) {
      throw const FormatException('cubism_model_data_source');
    }
    double number(Object? value) => (value as num).toDouble();
    Float32List array(Object? value, int length) {
      final raw = value as List;
      if (raw.length != length)
        throw const FormatException('cubism_model_data_array');
      return Float32List.fromList(raw.map(number).toList());
    }

    parameters.values.setAll(
      0,
      array(data['values'], parameters.values.length),
    );
    parameters.saved.setAll(0, array(data['saved'], parameters.saved.length));
    parameters.parts.setAll(
      0,
      array(data['partValues'], parameters.parts.length),
    );
    parameters.savedParts.setAll(
      0,
      array(data['savedParts'], parameters.savedParts.length),
    );
    fields
      ..clear()
      ..addAll({
        for (final entry in (data['fields'] as Map).entries)
          entry.key as String: number(entry.value),
      });
    _sampledParameters
      ..clear()
      ..addAll({
        for (final entry in (data['sampled'] as Map).entries)
          entry.key as String: number(entry.value),
      });
    _playing.clear();
    for (final raw in data['playing'] as List) {
      final row = raw as Map, clip = prefab.clips[row['clip']];
      if (clip == null) throw const FormatException('cubism_model_data_motion');
      _playing.add(
        _Playing(
            clip,
            _fadeData[clip.instanceId]!,
            number(row['start']),
            number(row['speed']),
            number(row['fadeIn']),
          )
          ..ends = number(row['ends'])
          ..clipTime = number(row['clipTime']),
      );
    }
    final animator = data['animator'] as int;
    _animator = animator < 0 ? null : _playing[animator];
    _expressionPlaying.clear();
    for (final raw in data['expressions'] as List) {
      final row = raw as Map;
      final source = _expressions.singleWhere(
        (value) => value.name == row['name'],
      );
      _expressionPlaying.add(
        _ExpressionPlaying(source)
          ..elapsed = number(row['elapsed'])
          ..end = number(row['end'])
          ..weight = number(row['weight']),
      );
    }
    _expressionValues
      ..clear()
      ..addAll({
        for (final entry in (data['expressionValues'] as Map).entries)
          int.parse(
            entry.key as String,
          ): _ExpressionValue(number((entry.value as List)[2]))
            ..add = number((entry.value as List)[0])
            ..multiply = number((entry.value as List)[1]),
      });
    final harmonics = data['harmonics'] as List;
    if (harmonics.length != _harmonics.length)
      throw const FormatException('cubism_model_data_harmonics');
    for (var i = 0; i < harmonics.length; i++)
      _harmonics[i].elapsed = number(harmonics[i]);
    final ranges = data['harmonicsRange'] as List?;
    if (ranges != null && ranges.length != _harmonics.length) {
      throw const FormatException('cubism_model_data_harmonic_ranges');
    }
    for (var i = 0; i < _harmonics.length; i++) {
      _harmonics[i].effectiveRange = ranges == null
          ? _harmonics[i].range
          : number(ranges[i]);
    }
    if (data['physics'] != null) _physics!.restoreData(data['physics'] as Map);
    final clock = data['clock'] as List, controls = data['controls'] as List;
    _time = number(clock[0]);
    _ownedSeconds = number(clock[1]);
    _frame = clock[2] as int;
    _sourcePausedSeconds = clock.length > 3 ? number(clock[3]) : 0;
    visible = controls[0] as bool;
    _repeatMotion = controls[1] as bool;
    _paused = controls[2] as bool;
    motionSpeed = number(controls[3]);
    _sourcePaused = controls.length > 4 ? controls[4] as bool : false;
    final motion = data['pendingMotion'] as List?,
        expression = data['pendingExpression'] as List?;
    _pendingMotion = motion == null
        ? null
        : (motion[0] as String, number(motion[1]), motion[2] as bool);
    _pendingExpression = expression == null
        ? null
        : (expression[0] as String, number(expression[1]));
    final loop = data['parameterLoop'] as Map?,
        pendingLoop = data['pendingParameterLoop'] as List?;
    final loopState = loop == null
        ? null
        : CubismParameterLoopSnapshot.fromData(loop);
    _parameterLoop.restore(
      loopState,
      loopState == null ? null : _resolveParameterLoopClip(loopState.name),
    );
    _pendingParameterLoop = pendingLoop == null
        ? null
        : (pendingLoop[0] as String, number(pendingLoop[1]));
    _voiceParameters = [
      for (final raw in (data['voiceParameters'] as List? ?? const []))
        ((raw as List)[0] as int, number(raw[1]), number(raw[2])),
    ];
    _voiceWeight = data['voiceWeight'] == null
        ? 1
        : number(data['voiceWeight']);
    final gaze = data['gaze'] as List;
    double? nullable(int index) =>
        gaze[index] == null ? null : number(gaze[index]);
    _lookX = nullable(0);
    _lookY = nullable(1);
    _angleX = nullable(2);
    _bodyAngleX = nullable(3);
    _headAngleBase = nullable(4);
    _bodyAngleBase = nullable(5);
    final blink = data['blink'] as List,
        expressionControl = data['expressionControl'] as List;
    _blinkCountdown = number(blink[0]);
    _blinkTime = number(blink[1]);
    _blinkStart = number(blink[2]);
    _blinkPhase = blink[3] as int;
    final blinkControl = data['blinkControl'] as List?;
    _autoEyeBlink = blinkControl?[0] as bool? ?? true;
    _eyeBlinkStopped = blinkControl?[1] as bool? ?? false;
    _blinkBeforeStop = blinkControl?[2] as bool? ?? _autoEyeBlink;
    _blinkStopStart = blinkControl == null ? 1 : number(blinkControl[3]);
    _blinkStopElapsed = blinkControl == null ? 0 : number(blinkControl[4]);
    _blinkStopDuration = blinkControl == null ? 0 : number(blinkControl[5]);
    _expressionIndex = expressionControl[0] as int;
    _lastExpressionIndex = expressionControl[1] as int;
    _expressionFade = number(expressionControl[2]);
    parameters.writeCore();
    final evaluated = model.evaluate();
    final pending = data['pending'] as List,
        drawables = data['drawables'] as List;
    if (pending.length != evaluated.length ||
        drawables.length != _drawables.length) {
      throw const FormatException('cubism_model_data_drawables');
    }
    _pendingDrawables = [
      for (var i = 0; i < pending.length; i++)
        _restoreDrawable(evaluated[i], pending[i] as Map),
    ];
    for (var i = 0; i < drawables.length; i++)
      _drawables[i].restoreData(drawables[i] as Map);
  }

  NativeCubismModelSnapshot snapshot() {
    _assertLive();
    final parameterValues = Float32List.fromList(parameters.values);
    final savedValues = Float32List.fromList(parameters.saved);
    final parts = Float32List.fromList(parameters.parts);
    final savedParts = Float32List.fromList(parameters.savedParts);
    final savedFields = Map<String, double>.of(fields);
    final sampled = Map<String, double>.of(_sampledParameters);
    final playing = [for (final row in _playing) row.copy()];
    final animatorIndex = _animator == null ? -1 : _playing.indexOf(_animator!);
    final expressions = [for (final row in _expressionPlaying) row.copy()];
    final expressionValues = {
      for (final row in _expressionValues.entries) row.key: row.value.copy(),
    };
    final harmonics = [for (final row in _harmonics) row.elapsed];
    final harmonicRanges = [for (final row in _harmonics) row.effectiveRange];
    final physics = _physics?.snapshot();
    final pending = [for (final row in _pendingDrawables) _copyDrawable(row)];
    final drawables = [for (final row in _drawables) row.snapshot()];
    final clock = (_time, _ownedSeconds, _frame, _sourcePausedSeconds);
    final controls = (
      visible,
      _repeatMotion,
      _paused,
      motionSpeed,
      _sourcePaused,
    );
    final queued = (_pendingMotion, _pendingExpression, _pendingParameterLoop);
    final parameterLoop = _parameterLoop.snapshot();
    final voiceParameters = List<(int, double, double)>.of(_voiceParameters);
    final voiceWeight = _voiceWeight;
    final gaze = (
      _lookX,
      _lookY,
      _angleX,
      _bodyAngleX,
      _headAngleBase,
      _bodyAngleBase,
    );
    final blink = (_blinkCountdown, _blinkTime, _blinkStart, _blinkPhase);
    final blinkControl = (
      _autoEyeBlink,
      _eyeBlinkStopped,
      _blinkBeforeStop,
      _blinkStopStart,
      _blinkStopElapsed,
      _blinkStopDuration,
    );
    final expressionControl = (
      _expressionIndex,
      _lastExpressionIndex,
      _expressionFade,
    );
    return NativeCubismModelSnapshot._(prefab, () {
      parameters.values.setAll(0, parameterValues);
      parameters.saved.setAll(0, savedValues);
      parameters.parts.setAll(0, parts);
      parameters.savedParts.setAll(0, savedParts);
      fields
        ..clear()
        ..addAll(savedFields);
      _sampledParameters
        ..clear()
        ..addAll(sampled);
      _playing
        ..clear()
        ..addAll(playing.map((row) => row.copy()));
      _animator = animatorIndex < 0 ? null : _playing[animatorIndex];
      _expressionPlaying
        ..clear()
        ..addAll(expressions.map((row) => row.copy()));
      _expressionValues
        ..clear()
        ..addAll({
          for (final row in expressionValues.entries) row.key: row.value.copy(),
        });
      for (var i = 0; i < _harmonics.length; i++) {
        _harmonics[i].elapsed = harmonics[i];
        _harmonics[i].effectiveRange = harmonicRanges[i];
      }
      if (physics != null) _physics!.restore(physics);
      _time = clock.$1;
      _ownedSeconds = clock.$2;
      _frame = clock.$3;
      _sourcePausedSeconds = clock.$4;
      visible = controls.$1;
      _repeatMotion = controls.$2;
      _paused = controls.$3;
      motionSpeed = controls.$4;
      _sourcePaused = controls.$5;
      _pendingMotion = queued.$1;
      _pendingExpression = queued.$2;
      _pendingParameterLoop = queued.$3;
      _parameterLoop.restore(
        parameterLoop,
        parameterLoop == null
            ? null
            : _resolveParameterLoopClip(parameterLoop.name),
      );
      _voiceParameters = List.unmodifiable(voiceParameters);
      _voiceWeight = voiceWeight;
      _lookX = gaze.$1;
      _lookY = gaze.$2;
      _angleX = gaze.$3;
      _bodyAngleX = gaze.$4;
      _headAngleBase = gaze.$5;
      _bodyAngleBase = gaze.$6;
      _blinkCountdown = blink.$1;
      _blinkTime = blink.$2;
      _blinkStart = blink.$3;
      _blinkPhase = blink.$4;
      _autoEyeBlink = blinkControl.$1;
      _eyeBlinkStopped = blinkControl.$2;
      _blinkBeforeStop = blinkControl.$3;
      _blinkStopStart = blinkControl.$4;
      _blinkStopElapsed = blinkControl.$5;
      _blinkStopDuration = blinkControl.$6;
      _expressionIndex = expressionControl.$1;
      _lastExpressionIndex = expressionControl.$2;
      _expressionFade = expressionControl.$3;
      parameters.writeCore();
      model.evaluate();
      _pendingDrawables = [for (final row in pending) _copyDrawable(row)];
      for (var i = 0; i < _drawables.length; i++) {
        drawables[i](_drawables[i]);
      }
    });
  }

  void restore(NativeCubismModelSnapshot snapshot) {
    _assertLive();
    if (!identical(snapshot._prefab, prefab)) {
      throw const FormatException('cubism_model_snapshot_source');
    }
    snapshot._restore();
  }

  /// Called after restoring the initial source snapshot of a cached model.
  void resetInitialClock({required double seconds, required int frame}) {
    _assertLive();
    if (!seconds.isFinite || seconds < 0 || frame < -1) {
      throw ArgumentError('cubism_initial_clock');
    }
    _ownedSeconds = seconds;
    _time = cubismF32(seconds);
    _frame = frame;
    _paused = false;
    _sourcePaused = false;
    _sourcePausedSeconds = 0;
    for (final row in _playing) {
      row.fadeStart = _time;
      row.clipTime = 0;
      row.ends = row.data.duration > 0
          ? cubismF32(cubismF32(row.data.duration / row.speed) + _time)
          : -1;
    }
    _scheduleBlink();
  }

  double get opacity => fields['renderOpacity']!.clamp(0.0, 1.0);
  int get maskTextureSize =>
      (prefab.component('CubismMaskController')['_maskTextureSize'] as num)
          .toInt();
  List<NativeCubismDrawable> get displayed =>
      List.unmodifiable([for (final row in _drawables) row.frame()]);

  void show(bool value) {
    _assertLive();
    // Both Show and Hide clear Source pause and its retained requests. Hide
    // additionally releases the model's blink override; AdvSession retains it.
    _sourcePaused = false;
    _pendingMotion = null;
    _pendingExpression = null;
    _pendingParameterLoop = null;
    if (!value) {
      _parameterLoop.stopImmediately();
      setEyeBlinkStopped(false);
    }
    if (visible == value) return;
    visible = value;
    if (value) {
      if (_animator == null) {
        if (defaultMotion.isNotEmpty) {
          playMotion(defaultMotion, fade: -1, repeat: true);
        }
        if (defaultExpression.isNotEmpty) {
          playExpression(defaultExpression, fade: -1);
        }
      }
    } else {
      _playing.clear();
      _animator = null;
      _resetExpressionParameters();
      parameters.writeCore();
      _pendingDrawables = model.evaluate();
      for (var i = 0; i < _drawables.length; i++) {
        _drawables[i].accept(_pendingDrawables[i]);
      }
    }
  }

  void playMotion(String name, {double fade = -1, bool repeat = false}) {
    _assertLive();
    final clip = prefab.clips[name];
    if (clip == null) return;
    if (_paused || _sourcePaused) {
      _pendingMotion = (name, fade, repeat);
      return;
    }
    final data = _fadeData[clip.instanceId]!;
    if (!fade.isFinite || motionSpeed <= 0 || !motionSpeed.isFinite) {
      throw ArgumentError('cubism_motion_controls');
    }
    if (_playing.isNotEmpty) {
      final previous = _playing.last;
      final end = cubismF32(_time + previous.data.fadeOut);
      if (math.max(previous.ends, 0) > end) previous.ends = end;
    }
    final next = _Playing(
      clip,
      data,
      _time,
      motionSpeed,
      fade >= 0 ? fade : data.fadeIn,
    );
    if (_playing.isNotEmpty && next.fadeIn > 0) {
      final previous = _playing.last;
      final keptUntil = cubismF32(_time + math.max(previous.data.fadeOut, 0));
      if (previous.ends < keptUntil) previous.ends = keptUntil;
    }
    _playing.add(next);
    _animator = next;
    _repeatMotion = repeat || name == defaultMotion;
  }

  void playExpression(String name, {double fade = -1}) {
    _assertLive();
    final index = _expressions.indexWhere((source) => source.name == name);
    if (index < 0) return;
    if (_paused || _sourcePaused) {
      _pendingExpression = (name, fade);
      return;
    }
    _resetExpressionParameters();
    _expressionIndex = index;
    _expressionFade = fade;
  }

  CubismParameterLoopClip? _resolveParameterLoopClip(String name) {
    final cached = _parameterLoopClips[name];
    if (cached != null) return cached;
    _FadeData? data;
    for (var i = 0; i < prefab.fadeMotions.length; i++) {
      final assetName = prefab.fadeMotions[i]['m_Name'] as String;
      if (assetName.replaceAll('.fade', '') == name) {
        data = _fadeData[prefab.fadeInstanceIds[i]]!;
        break;
      }
    }
    if (data == null) return null;
    final binding = CubismParameterLoopClip(
      name: name,
      duration: data.duration,
      parameterCurveCount: data.parameterCurveCount,
      curves: [
        for (final curve in data.curves)
          CubismParameterLoopCurve(
            index: curve.index,
            defaultValue: parameters.defaults[curve.index],
            sample: curve.curve.sample,
          ),
      ],
    );
    if (!binding.isValid) return null;
    return _parameterLoopClips[name] = binding;
  }

  bool playParameterLoop(String name, {double fade = 0}) {
    _assertLive();
    if (!visible) return false;
    if (_paused || _sourcePaused) {
      _pendingParameterLoop = (name, fade);
      return false;
    }
    final clip = _resolveParameterLoopClip(name);
    return clip != null && _parameterLoop.play(clip, fadeSeconds: fade);
  }

  void stopParameterLoop({double fade = 0}) {
    _assertLive();
    if (_paused || _sourcePaused) {
      _pendingParameterLoop = ('', fade);
      return;
    }
    _parameterLoop.stop(fadeSeconds: fade);
  }

  /// Live2DCharacter.Pause freezes the complete role update independently of
  /// transport pause. Motion and expression requests retain their latest slots.
  void setSourcePaused(bool value) {
    _assertLive();
    _sourcePaused = value;
    if (!value) {
      _resetExpressionParameters();
      _flushPendingPresentation();
    }
  }

  void _flushPendingPresentation() {
    if (_paused || _sourcePaused) return;
    final motion = _pendingMotion,
        expression = _pendingExpression,
        loop = _pendingParameterLoop;
    _pendingMotion = null;
    _pendingExpression = null;
    _pendingParameterLoop = null;
    if (motion != null) {
      playMotion(motion.$1, fade: motion.$2, repeat: motion.$3);
    }
    if (expression != null) {
      playExpression(expression.$1, fade: expression.$2);
    }
    if (loop != null) {
      if (loop.$1.isEmpty) {
        stopParameterLoop(fade: loop.$2);
      } else {
        playParameterLoop(loop.$1, fade: loop.$2);
      }
    }
  }

  Map<String, Object?> get sourceControlObservation => {
    'paused': _sourcePaused,
    'transportPaused': _paused,
    'roleSeconds': _time,
    'ownedSeconds': _ownedSeconds,
    'motion': _animator?.clip.name,
    'motionTime': _animator?.clipTime,
    'pendingMotion': _pendingMotion?.$1,
    'pendingExpression': _pendingExpression?.$1,
    'parameterLoop': _parameterLoop.snapshot()?.toData(),
    'pendingParameterLoop': _pendingParameterLoop == null
        ? null
        : [_pendingParameterLoop!.$1, _pendingParameterLoop!.$2],
    'loopParameters': {
      for (final curve
          in _parameterLoop.activeClip?.curves ??
              const <CubismParameterLoopCurve>[])
        model.parameters.keys.elementAt(curve.index):
            parameters.values[curve.index],
    },
    'eyeBlinkStopped': _eyeBlinkStopped,
    'eyeOpening': fields['eyeOpening'],
    'blinkStopElapsed': _blinkStopElapsed,
    'blinkStopDuration': _blinkStopDuration,
    'blinkParameters': {
      for (final entry in parameters.indices.entries)
        if (_blinkNeutralTargets.contains(entry.value))
          entry.key: parameters.values[entry.value],
    },
  };

  /// Formal SetEyeBlinkStopped retains the first stop transition. Repeated
  /// immediate stops finish it; resume restores the prior auto-input setting.
  void setEyeBlinkStopped(bool stopped, {double transitionSeconds = 0}) {
    _assertLive();
    if (!transitionSeconds.isFinite) {
      throw ArgumentError('cubism_blink_transition');
    }
    if (!stopped) {
      if (!_eyeBlinkStopped) return;
      _eyeBlinkStopped = false;
      _autoEyeBlink = _blinkBeforeStop;
      _blinkStopElapsed = _blinkStopDuration = 0;
      return;
    }
    if (_eyeBlinkStopped) {
      if (transitionSeconds <= 0) {
        _blinkStopElapsed = _blinkStopDuration = 0;
      }
    } else {
      _blinkBeforeStop = _autoEyeBlink;
      _autoEyeBlink = false;
      _eyeBlinkStopped = true;
      _blinkStopStart = fields['eyeOpening']!;
      _blinkStopElapsed = 0;
      _blinkStopDuration = cubismF32(transitionSeconds);
    }
  }

  double get _blinkStopWeight => _blinkStopDuration <= 0
      ? 1
      : cubismF32(_blinkStopElapsed / _blinkStopDuration).clamp(0.0, 1.0);

  void _advanceBlinkStop(double delta) {
    if (!_eyeBlinkStopped) return;
    if (_blinkStopElapsed < _blinkStopDuration) {
      _blinkStopElapsed = cubismF32(
        _blinkStopElapsed + cubismF32(delta * motionSpeed),
      );
    }
  }

  void _applyBlinkStop() {
    if (!_eyeBlinkStopped) return;
    fields['eyeOpening'] = cubismF32(
      _blinkStopStart +
          cubismF32(_blinkStopWeight * cubismF32(1 - _blinkStopStart)),
    );
  }

  void _resetExpressionParameters() {
    for (final expression in _expressions) {
      for (final destination in expression.destinations.values) {
        parameters.values[destination.index] =
            parameters.defaults[destination.index];
      }
    }
    parameters.save();
  }

  void setMouthOpening(double value) {
    _assertLive();
    if (!value.isFinite) throw ArgumentError('cubism_mouth_opening');
    fields['mouthOpening'] = cubismF32(value.clamp(0.0, 1.0));
  }

  /// A held read, resize or duplicate timestamp never executes simulation.
  void acceptedStep({
    required int frame,
    required double seconds,
    required double delta,
    required bool paused,
  }) {
    _assertLive();
    if (frame < 0 ||
        !seconds.isFinite ||
        !delta.isFinite ||
        delta < 0 ||
        seconds < _ownedSeconds) {
      throw ArgumentError('cubism_owned_step');
    }
    if (paused) {
      _paused = true;
      return;
    }
    if (_paused) {
      _paused = false;
      _flushPendingPresentation();
    }
    if (frame == _frame) return;
    if (frame < _frame) throw StateError('cubism_clock_needs_restore');
    _frame = frame;
    if (_sourcePaused) {
      _sourcePausedSeconds += seconds - _ownedSeconds;
      _ownedSeconds = seconds;
      return;
    }
    _ownedSeconds = seconds;
    _time = cubismF32(seconds - _sourcePausedSeconds);
    if (!visible) return;
    final dt = cubismF32(delta);
    _parameterLoop.advance(cubismF32(dt * motionSpeed));
    _advanceBlinkStop(dt);
    // Update: read the previous evaluated deformation, then restore order-150 values.
    for (var i = 0; i < _drawables.length; i++) {
      _drawables[i].accept(_pendingDrawables[i]);
    }
    parameters.restore();
    final active = _animator;
    if (active != null && _time > active.ends && _repeatMotion) {
      // The character controller restarts default Idle and requested loops.
      // A finite authored gesture keeps its final pose until the next command.
      playMotion(active.clip.name, fade: 0, repeat: true);
    }
    // Director animation writes the newest clip before LateUpdate controllers.
    final animator = _animator;
    if (animator != null) {
      animator.clipTime = math.min(
        animator.clipTime + dt * animator.speed,
        math.max(0, cubismF32(animator.clip.duration - cubismF32(.0001))),
      );
      _sampledParameters.clear();
      animator.clip.sampleInto(animator.clipTime, _sampledParameters, fields);
      for (final entry in _sampledParameters.entries) {
        parameters.values[parameters.require(entry.key)] = entry.value;
      }
    }
    _applyFade();
    _neutralizeDefaultBlink();
    parameters.save();
    _applyExpressions(dt);
    _parameterLoop.apply();
    _applyBlinkStop();
    for (final index in _eyeTags) {
      parameters.multiply(index, fields['eyeOpening']!);
    }
    if (_voiceParameters.isEmpty) {
      for (final index in _mouthTags) {
        parameters.overwrite(index, fields['mouthOpening']!);
      }
    } else {
      for (final (index, analyzed, neutral) in _voiceParameters) {
        final delta = cubismF32(cubismF32(analyzed - neutral) * _voiceWeight);
        parameters.overwrite(
          index,
          cubismF32(parameters.values[index] + delta),
        );
      }
    }
    _applyHarmonics(dt);
    _physics?.advance(dt);
    _advanceBlink(dt);
    _applyAngleOffsets();
    final eyeX = parameters.indices['ParamEyeBallX'];
    final eyeY = parameters.indices['ParamEyeBallY'];
    if (_lookX != null && eyeX != null) parameters.overwrite(eyeX, _lookX!);
    if (_lookY != null && eyeY != null) parameters.overwrite(eyeY, _lookY!);
    // PreLateEnd writes the completed managed values once to real Native Core.
    parameters.writeCore();
    _pendingDrawables = model.evaluate();
  }

  /// A fully weighted default motion may take ownership from an older gesture.
  /// Until every neutralized parameter has completed its fades, that gesture's
  /// eye curves retain their authored contribution.
  bool _defaultOverridesBlinkTargets(_Playing row) {
    if (row.clip.name != defaultMotion) return false;
    final elapsed = cubismF32(cubismF32(_time - row.fadeStart) * row.speed);
    for (final index in _blinkNeutralTargets) {
      final curve = row.data.curves
          .where((curve) => curve.index == index)
          .firstOrNull;
      if (curve == null) return false;
      if (curve.fadeIn < 0) {
        if (math.max(elapsed, 0) < row.fadeIn) return false;
      } else if (curve.fadeIn >= 1.4e-45 && elapsed < curve.fadeIn) {
        return false;
      }
      if (curve.fadeOut < 0) {
        if (row.data.fadeOut > 0 &&
            row.ends >= 0 &&
            cubismF32(row.ends - _time) < row.data.fadeOut) {
          return false;
        }
      } else if (curve.fadeOut >= 1.4e-45) {
        final remaining = cubismF32(row.ends - elapsed);
        if (remaining >= 0 && remaining < curve.fadeOut) return false;
      }
    }
    return true;
  }

  void _neutralizeDefaultBlink() {
    final latest = _animator;
    if (!_eyeBlinkStopped ||
        latest == null ||
        latest.clip.name != defaultMotion) {
      return;
    }
    if (_playing.any((row) => row.clip.name != defaultMotion) &&
        !_defaultOverridesBlinkTargets(latest)) {
      return;
    }
    final weight = _blinkStopWeight;
    for (final index in _blinkNeutralTargets) {
      final current = parameters.values[index];
      parameters.overwrite(
        index,
        cubismF32(
          current +
              cubismF32(
                weight * cubismF32(parameters.defaults[index] - current),
              ),
        ),
      );
    }
  }

  void _applyFade() {
    if (_playing.length < 2) return;
    final newest = _playing.last;
    final elapsed = cubismF32(
      cubismF32(_time - newest.fadeStart) * newest.speed,
    );
    final blending = newest.data.fadeIns.any(
      (time) => elapsed <= newest.fadeIn || (time >= 0 && elapsed <= time),
    );
    if (!blending) {
      _playing.removeWhere((row) => row != newest && row.ends < _time);
      return;
    }
    parameters.restore();
    for (final row in _playing) {
      final elapsed = cubismF32(cubismF32(_time - row.fadeStart) * row.speed);
      final fin = row.fadeIn > 0
          ? cubismFadeEase(cubismF32(elapsed / row.fadeIn))
          : 1.0;
      final fout = row.data.fadeOut > 0 && row.ends >= 0
          ? cubismFadeEase(
              cubismF32(cubismF32(row.ends - _time) / row.data.fadeOut),
            )
          : 1.0;
      for (final curve in row.data.curves) {
        final i = curve.index;
        final vin = curve.fadeIn >= 0
            ? (curve.fadeIn >= 1.4e-45
                  ? cubismFadeEase(cubismF32(elapsed / curve.fadeIn))
                  : 1.0)
            : fin;
        final remaining = cubismF32(row.ends - elapsed);
        final vout = curve.fadeOut >= 0
            ? (remaining >= 0 && curve.fadeOut >= 1.4e-45
                  ? cubismFadeEase(cubismF32(remaining / curve.fadeOut))
                  : 1.0)
            : fout;
        final weight = cubismF32(vin * vout);
        final value = curve.curve
            .sample(elapsed)
            .clamp(parameters.minimum[i], parameters.maximum[i]);
        parameters.overwrite(
          i,
          cubismF32(
            cubismF32(cubismF32(value - parameters.values[i]) * weight) +
                parameters.values[i],
          ),
        );
      }
    }
  }

  void _applyExpressions(double delta) {
    if (_expressionIndex != _lastExpressionIndex) {
      _lastExpressionIndex = _expressionIndex;
      if (_expressionPlaying.isNotEmpty) {
        final previous = _expressionPlaying.last;
        final end = cubismF32(previous.elapsed + previous.source.fadeOut);
        if (previous.end == 0 || end < previous.end) previous.end = end;
      }
      if (_expressionIndex >= 0) {
        _expressionPlaying.add(
          _ExpressionPlaying(_expressions[_expressionIndex]),
        );
      }
    }
    var totalWeight = 0.0;
    for (var ordinal = 0; ordinal < _expressionPlaying.length; ordinal++) {
      final playing = _expressionPlaying[ordinal];
      final source = playing.source;
      for (final destination in source.destinations.values) {
        _expressionValues.putIfAbsent(
          destination.index,
          () => _ExpressionValue(parameters.values[destination.index]),
        );
      }
      playing.elapsed = cubismF32(playing.elapsed + delta);
      final fadeIn = _expressionFade >= 0 ? _expressionFade : source.fadeIn;
      final incoming = fadeIn.abs() >= 1.4e-45
          ? cubismFadeEase(cubismF32(playing.elapsed / fadeIn))
          : 1.0;
      final outgoing = playing.end.abs() >= 1.4e-45 && playing.end >= 0
          ? cubismFadeEase(
              cubismF32(
                cubismF32(playing.end - playing.elapsed) / source.fadeOut,
              ),
            )
          : 1.0;
      playing.weight = cubismF32(incoming * outgoing);
      final inverse = cubismF32(1 - playing.weight);
      for (final entry in _expressionValues.entries) {
        final old = entry.value, baseline = parameters.values[entry.key];
        final destination = source.destinations[entry.key];
        final added = destination?.blend == 1 ? destination!.value : 0.0;
        final multiplied = destination?.blend == 2 ? destination!.value : 1.0;
        final replaced =
            destination != null &&
                destination.blend != 1 &&
                destination.blend != 2
            ? destination.value
            : baseline;
        if (ordinal == 0) {
          old.add = added;
          old.multiply = multiplied;
          old.override = replaced;
        } else {
          old.add = cubismF32(
            cubismF32(added * playing.weight) + cubismF32(old.add * inverse),
          );
          old.multiply = cubismF32(
            cubismF32(multiplied * playing.weight) +
                cubismF32(old.multiply * inverse),
          );
          old.override = cubismF32(
            cubismF32(replaced * playing.weight) +
                cubismF32(baseline * inverse),
          );
        }
      }
      totalWeight = cubismF32(
        totalWeight +
            (fadeIn != 0
                ? cubismFadeEase(cubismF32(playing.elapsed / fadeIn))
                : 1),
      );
    }
    if (_expressionPlaying.length > 1 && _expressionPlaying.last.weight >= 1) {
      _expressionPlaying.removeRange(0, _expressionPlaying.length - 1);
    }
    for (final entry in _expressionValues.entries) {
      final value = entry.value;
      parameters.overwrite(
        entry.key,
        cubismF32(cubismF32(value.add + value.override) * value.multiply),
        math.min(totalWeight, 1),
      );
    }
  }

  void _applyHarmonics(double delta) {
    if (!_harmonicEnabled) return;
    for (final source in _harmonics) {
      if (source.channel < 0 ||
          source.channel >= _harmonicRates.length ||
          source.duration <= 0) {
        throw const FormatException('cubism_harmonic_channel');
      }
      source.elapsed = advanceUnityHarmonicTime(
        source.elapsed,
        delta,
        _harmonicRates[source.channel],
        source.duration,
      );
      final sampled = evaluateUnityHarmonic(
        minimum: parameters.minimum[source.index],
        maximum: parameters.maximum[source.index],
        normalizedOrigin: source.origin,
        normalizedRange: source.effectiveRange,
        direction: source.direction,
        elapsed: source.elapsed,
        duration: source.duration,
      );
      source.effectiveRange = sampled.normalizedRange;
      switch (_harmonicBlendMode) {
        case 0:
          parameters.overwrite(source.index, sampled.value);
        case 1:
          parameters.add(source.index, sampled.value);
        case 2:
          parameters.multiply(source.index, sampled.value);
      }
    }
  }

  void _scheduleBlink() {
    final random = randomUnit();
    if (!random.isFinite || random < 0 || random >= 1) {
      throw ArgumentError('cubism_random_unit');
    }
    _blinkCountdown = cubismF32(
      _blinkMean +
          cubismF32(-_blinkDeviation + cubismF32(random * 2 * _blinkDeviation)),
    );
  }

  void _advanceBlink(double delta) {
    if (!_autoEyeBlink ||
        _eyeBlinkStopped ||
        _animator?.clip.name != defaultMotion) {
      return;
    }
    _blinkTime = cubismF32(_blinkTime + cubismF32(delta * _blinkRate));
    switch (_blinkPhase) {
      case 0:
        _blinkCountdown = cubismF32(_blinkCountdown - delta);
        if (_blinkCountdown < 0) {
          _blinkPhase = 1;
          _blinkStart = _blinkTime;
        }
        fields['eyeOpening'] = 1;
      case 1:
        final progress = cubismF32(_blinkTime - _blinkStart);
        if (progress >= 1) {
          _blinkPhase = 2;
          _blinkStart = _blinkTime;
        }
        fields['eyeOpening'] = cubismF32(1 - progress);
      case 2:
        if (cubismF32(cubismF32(_blinkTime - _blinkStart) / .5) >= 1) {
          _blinkPhase = 3;
          _blinkStart = _blinkTime;
        }
        fields['eyeOpening'] = 0;
      case 3:
        final progress = cubismF32(cubismF32(_blinkTime - _blinkStart) / 1.5);
        if (progress >= 1) {
          _blinkPhase = 0;
          _scheduleBlink();
          fields['eyeOpening'] = 1;
        } else {
          fields['eyeOpening'] = progress;
        }
    }
  }

  List<(String, Map)> _tagged(String type) => [
    for (final row in prefab.tagged(type)) row,
  ];
  void _assertLive() {
    if (_disposed) throw StateError('cubism_host_disposed');
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    model.dispose();
  }
}

final class NativeCubismModelSnapshot {
  NativeCubismModelSnapshot._(this._prefab, this._restore);
  final NativeCubismUnityPrefab _prefab;
  final void Function() _restore;
}

final class _FadeCurve {
  _FadeCurve(this.index, this.curve, this.fadeIn, this.fadeOut);
  final int index;
  final NativeCubismFadeCurve curve;
  final double fadeIn, fadeOut;
}

final class _FadeData {
  _FadeData(Map source, NativeCubismParameterState state)
    : fadeIn = _number(source['FadeInTime']),
      fadeOut = _number(source['FadeOutTime']),
      duration = _number(source['MotionLength']),
      fadeIns = (source['ParameterFadeInTimes'] as List).map(_number).toList() {
    final ids = (source['ParameterIds'] as List).cast<String>();
    parameterCurveCount = ids.length;
    final raw = (source['ParameterCurves'] as List).cast<Map>();
    final fadeOuts = (source['ParameterFadeOutTimes'] as List)
        .map(_number)
        .toList();
    if (ids.length != raw.length ||
        ids.length != fadeIns.length ||
        ids.length != fadeOuts.length) {
      throw const FormatException('cubism_fade_channels');
    }
    curves = [
      for (var i = 0; i < ids.length; i++)
        if (state.indices.containsKey(ids[i]))
          _FadeCurve(
            state.indices[ids[i]]!,
            NativeCubismFadeCurve(raw[i]),
            fadeIns[i],
            fadeOuts[i],
          ),
    ];
  }
  final double fadeIn, fadeOut, duration;
  final List<double> fadeIns;
  late final int parameterCurveCount;
  late final List<_FadeCurve> curves;
}

final class _Playing {
  _Playing(this.clip, this.data, this.fadeStart, this.speed, this.fadeIn)
    : ends = data.duration > 0
          ? cubismF32(cubismF32(data.duration / speed) + fadeStart)
          : -1;
  final NativeCubismUnityClip clip;
  final _FadeData data;
  final double speed, fadeIn;
  double fadeStart, ends, clipTime = 0;
  _Playing copy() => _Playing(clip, data, fadeStart, speed, fadeIn)
    ..ends = ends
    ..clipTime = clipTime;
}

final class _ExpressionDestination {
  _ExpressionDestination(this.index, this.value, this.blend);
  final int index, blend;
  final double value;
}

final class _ExpressionData {
  _ExpressionData(Map source, NativeCubismParameterState state)
    : name = (source['m_Name'] as String).replaceFirst(RegExp(r'\.exp3$'), ''),
      fadeIn = math.max(
        0,
        _number(source['FadeInTime']) < 0 ? 1 : _number(source['FadeInTime']),
      ),
      fadeOut = math.max(
        0,
        _number(source['FadeOutTime']) < 0 ? 1 : _number(source['FadeOutTime']),
      ) {
    destinations = {
      for (final row in (source['Parameters'] as List).cast<Map>())
        if (state.indices.containsKey(row['Id']))
          state.indices[row['Id']]!: _ExpressionDestination(
            state.indices[row['Id']]!,
            _number(row['Value']),
            row['Blend'] as int,
          ),
    };
  }
  final String name;
  final double fadeIn, fadeOut;
  late final Map<int, _ExpressionDestination> destinations;
}

final class _ExpressionPlaying {
  _ExpressionPlaying(this.source);
  final _ExpressionData source;
  double elapsed = 0, end = 0, weight = 0;
  _ExpressionPlaying copy() => _ExpressionPlaying(source)
    ..elapsed = elapsed
    ..end = end
    ..weight = weight;
}

final class _ExpressionValue {
  _ExpressionValue(this.override);
  double add = 0, multiply = 1, override;
  _ExpressionValue copy() => _ExpressionValue(override)
    ..add = add
    ..multiply = multiply;
}

final class _Harmonic {
  _Harmonic(Map source, this.index)
    : channel = source['Channel'] as int,
      direction = source['Direction'] as int,
      origin = _number(source['NormalizedOrigin']),
      range = _number(source['NormalizedRange']),
      duration = _number(source['Duration']) {
    if (direction < 0 || direction > 2) {
      throw UnsupportedError('cubism_harmonic_direction');
    }
    effectiveRange = range;
  }
  final int index, channel, direction;
  final double origin, range, duration;
  late double effectiveRange;
  double elapsed = 0;
}

final class _DrawablePair {
  _DrawablePair(this.source)
    : buffers = [source.positions, Float32List.fromList(source.positions)],
      alpha = [source.opacity, source.opacity],
      enabled = source.visible,
      opacity = source.opacity,
      rank = source.renderOrder,
      appliedRank = source.renderOrder,
      screen = source.screenColor;
  final NativeCubismDrawable source;
  final List<Float32List> buffers;
  final List<double> alpha;
  int front = 0, rank, appliedRank;
  bool enabled, maskSource = false;
  double opacity;
  Float32List screen;
  Float32List? _capturedScreen;
  bool? _queuedVisibility, _lastVisibility;
  bool _queuedRank = false, _lastRank = false;
  Map<String, Object?> snapshotData() => {
    'buffers': [for (final row in buffers) row.toList()],
    'alpha': List<double>.of(alpha),
    'front': front,
    'rank': rank,
    'appliedRank': appliedRank,
    'enabled': enabled,
    'opacity': opacity,
    'screen': screen.toList(),
    'capturedScreen': _capturedScreen?.toList(),
    'queuedVisibility': _queuedVisibility,
    'lastVisibility': _lastVisibility,
    'queuedRank': _queuedRank,
    'lastRank': _lastRank,
  };
  void restoreData(Map data) {
    Float32List array(Object? value) => Float32List.fromList([
      for (final entry in value as List) (entry as num).toDouble(),
    ]);
    final raw = data['buffers'] as List;
    if (raw.length != 2 ||
        (raw[0] as List).length != source.positions.length ||
        (raw[1] as List).length != source.positions.length) {
      throw const FormatException('cubism_drawable_data_buffers');
    }
    for (var i = 0; i < 2; i++) {
      buffers[i] = array(raw[i]);
      alpha[i] = ((data['alpha'] as List)[i] as num).toDouble();
    }
    front = data['front'] as int;
    rank = data['rank'] as int;
    appliedRank = data['appliedRank'] as int;
    enabled = data['enabled'] as bool;
    opacity = (data['opacity'] as num).toDouble();
    screen = array(data['screen']);
    _capturedScreen = data['capturedScreen'] == null
        ? null
        : array(data['capturedScreen']);
    _queuedVisibility = data['queuedVisibility'] as bool?;
    _lastVisibility = data['lastVisibility'] as bool?;
    _queuedRank = data['queuedRank'] as bool;
    _lastRank = data['lastRank'] as bool;
  }

  void Function(_DrawablePair) snapshot() {
    final positions = [
      for (final value in buffers) Float32List.fromList(value),
    ];
    final alphas = List<double>.of(alpha);
    final saved = (front, rank, appliedRank, enabled, opacity);
    final color = Float32List.fromList(screen);
    final captured = _capturedScreen == null
        ? null
        : Float32List.fromList(_capturedScreen!);
    final queued = (_queuedVisibility, _lastVisibility, _queuedRank, _lastRank);
    return (row) {
      for (var i = 0; i < 2; i++) {
        row.buffers[i] = Float32List.fromList(positions[i]);
        row.alpha[i] = alphas[i];
      }
      row.front = saved.$1;
      row.rank = saved.$2;
      row.appliedRank = saved.$3;
      row.enabled = saved.$4;
      row.opacity = saved.$5;
      row.screen = Float32List.fromList(color);
      row._capturedScreen = captured == null
          ? null
          : Float32List.fromList(captured);
      row._queuedVisibility = queued.$1;
      row._lastVisibility = queued.$2;
      row._queuedRank = queued.$3;
      row._lastRank = queued.$4;
    };
  }

  void accept(NativeCubismDrawable evaluated) {
    if (_lastVisibility != null) enabled = _lastVisibility!;
    if (_lastRank) {
      appliedRank = rank;
      _lastRank = false;
    }
    final flags = evaluated.dynamicFlags;
    if ((flags & 0x7e) == 0) return;
    var changed = false;
    if ((flags & 2) != 0) {
      _queuedVisibility = evaluated.visible;
      changed = true;
    }
    if ((flags & 16) != 0) {
      if (rank != evaluated.renderOrder) {
        rank = evaluated.renderOrder;
        _queuedRank = true;
      }
      changed = true;
    }
    if ((flags & 4) != 0) {
      opacity = evaluated.opacity;
      changed = true;
    }
    if ((flags & 32) != 0) {
      if (enabled || _queuedVisibility == true || maskSource) {
        buffers[front] = evaluated.positions;
      }
      _swap();
    } else if (changed) {
      _swap();
    }
    if ((flags & 96) == 96) _capturedScreen = evaluated.screenColor;
    if ((flags & 64) != 0 && _capturedScreen != null) screen = _capturedScreen!;
  }

  void _swap() {
    if (!enabled && _queuedVisibility != true && !maskSource) {
      _lastVisibility = _queuedVisibility;
      _lastRank = _queuedRank;
      return;
    }
    final written = front;
    front = 1 - front;
    alpha[written] = opacity;
    _lastVisibility = _queuedVisibility;
    _lastRank = _queuedRank;
    _queuedVisibility = null;
    _queuedRank = false;
  }

  NativeCubismDrawable frame() => NativeCubismDrawable(
    id: source.id,
    sourceIndex: source.sourceIndex,
    textureIndex: source.textureIndex,
    renderOrder: appliedRank,
    opacity: alpha[front],
    flags: source.flags,
    visible: enabled,
    positions: buffers[front],
    uvs: source.uvs,
    indices: source.indices,
    masks: source.masks,
    multiplyColor: source.multiplyColor,
    screenColor: screen,
  );
}

NativeCubismDrawable _copyDrawable(NativeCubismDrawable row) =>
    NativeCubismDrawable(
      id: row.id,
      sourceIndex: row.sourceIndex,
      textureIndex: row.textureIndex,
      renderOrder: row.renderOrder,
      opacity: row.opacity,
      flags: row.flags,
      dynamicFlags: row.dynamicFlags,
      visible: row.visible,
      positions: Float32List.fromList(row.positions),
      uvs: row.uvs,
      indices: row.indices,
      masks: row.masks,
      multiplyColor: Float32List.fromList(row.multiplyColor),
      screenColor: Float32List.fromList(row.screenColor),
    );

NativeCubismDrawable _restoreDrawable(NativeCubismDrawable source, Map data) {
  Float32List array(Object? value, int length) {
    final raw = value as List;
    if (raw.length != length)
      throw const FormatException('cubism_pending_drawable_data');
    return Float32List.fromList([
      for (final value in raw) (value as num).toDouble(),
    ]);
  }

  if (data['sourceIndex'] != source.sourceIndex)
    throw const FormatException('cubism_drawable_data_source');
  return NativeCubismDrawable(
    id: source.id,
    sourceIndex: source.sourceIndex,
    textureIndex: source.textureIndex,
    flags: source.flags,
    renderOrder: data['renderOrder'] as int,
    opacity: (data['opacity'] as num).toDouble(),
    dynamicFlags: data['flags'] as int,
    visible: data['visible'] as bool,
    positions: array(data['positions'], source.positions.length),
    uvs: source.uvs,
    indices: source.indices,
    masks: source.masks,
    multiplyColor: array(data['multiply'], 4),
    screenColor: array(data['screen'], 4),
  );
}

double _number(Object? value) {
  if (value is! num || !value.isFinite) {
    throw const FormatException('cubism_source_number');
  }
  return value.toDouble();
}
