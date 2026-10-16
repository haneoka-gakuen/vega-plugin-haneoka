import 'dart:async';
import 'dart:typed_data';

import 'story_command_decoder.dart';
import 'story_frame_source.dart';
import 'story_frame_snapshot_catalog.dart';
import 'story_scene_state.dart';
import 'story_render_profile_binding.dart';
import 'story_timeline.dart';
part 'story_frame_playback_data.dart';

final _singleStorage = Float32List(1);
double _single(double value) {
  _singleStorage[0] = value;
  return _singleStorage[0];
}

double _parameter(String? text) {
  if (!RegExp(r'^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$')
      .hasMatch((text ?? '').trim())) {
    return 0;
  }
  final value = double.tryParse(text!.trim());
  return value != null && value.isFinite ? _single(value) : 0;
}

final class StoryFramePlaybackCancelled implements Exception {
  const StoryFramePlaybackCancelled(this.reason);
  final String reason;
}

typedef StoryFrameLayoutResolver = Map<String, Object?> Function(
  StoryFrameSource source,
  Map<String, StoryFramePose> poses,
);

final class StoryFrameInstanceFrame {
  StoryFrameInstanceFrame._(
    _Instance instance,
    StoryFrameLayoutResolver? resolver,
  ) : source = instance.source,
      ref = instance.source.ref,
      active = instance.active,
      alpha = instance.alpha,
      stateName = instance.state,
      stateSeconds = instance.seconds,
      capturedAnimatorSpeed = instance.speed,
      particleSeconds = instance.particleSeconds,
      particleRunId = instance.particleRunId,
      poses = Map.unmodifiable(instance.poses),
      layout = Map.unmodifiable(
        resolver == null
            ? instance.source.layout(instance.poses)
            : resolver(instance.source, instance.poses),
      );
  final StoryFrameSource source;
  final String ref;
  final bool active;

  /// Included in poses at canvasGroupNodeId; the host must apply it once.
  final double alpha, stateSeconds, capturedAnimatorSpeed;

  /// Coffee simulation follows active unscaled story time, independently of Animator.speed.
  final double particleSeconds;
  final int particleRunId;
  final String? stateName;
  final Map<String, StoryFramePose> poses;
  final Map<String, Object?> layout;
  double get normalizedTime => stateName == null
      ? 0
      : stateSeconds / source.states[stateName]!.normalizedLength;
}

final class StoryFramePlaybackFrame {
  StoryFramePlaybackFrame({
    required this.sourceIdentity,
    required this.sourceEpoch,
    required this.actualStoryUs,
    required this.actualUpdateIndex,
    required this.current,
    required List<StoryFrameInstanceFrame> visibleInstances,
    required List<String> warnings,
  }) : visibleInstances = List.unmodifiable(visibleInstances),
       warnings = List.unmodifiable(warnings);
  final StorySourceIdentity sourceIdentity;
  final int sourceEpoch, actualStoryUs, actualUpdateIndex;
  final StoryFrameInstanceFrame? current;
  final List<StoryFrameInstanceFrame> visibleInstances;
  final List<String> warnings;
}

final class _Instance {
  _Instance(this.source)
    : poses = Map.of(source.initialPoses),
      state = source.defaultState {
    if (state != null) {
      poses = Map.of(source.sample(source.states[state]!, 0, poses));
    }
    active = false;
  }
  final StoryFrameSource source;
  Map<String, StoryFramePose> poses;
  String? state;
  double seconds = 0, speed = 1, particleSeconds = 0;
  int particleRunId = 0;
  bool active = false;
  double get alpha => poses[source.canvasGroupNodeId]!.opacity;
  set alpha(double value) => poses[source.canvasGroupNodeId] =
      poses[source.canvasGroupNodeId]!.set(StoryFrameProperty.opacity, [value]);
  void activate(bool value) {
    if (source.particleSource != null && value != active) {
      particleSeconds = 0;
      if (value) particleRunId++;
    }
    active = value;
    poses[source.rootNodeId] = poses[source.rootNodeId]!.set(
      StoryFrameProperty.active,
      [value ? 1 : 0],
    );
  }

  void play(String name, {required bool restart}) {
    if (restart || state != name) {
      state = name;
      seconds = 0;
    }
  }

  _Instance copy() {
    final result = _Instance(source);
    result.poses = Map.of(poses);
    result.state = state;
    result.seconds = seconds;
    result.speed = speed;
    result.particleSeconds = particleSeconds;
    result.particleRunId = particleRunId;
    result.active = active;
    return result;
  }
}

enum _Phase { delay, showDelay, state, fade }

final class _Operation {
  _Operation({
    required this.id,
    required this.commandIndex,
    required this.executionId,
    required this.ref,
    required this.namedState,
    required this.fade,
    required this.delay,
    required this.wait,
    required this.updateIndex,
  });
  final int id, commandIndex;
  int? executionId;
  final String ref, namedState;
  final double fade;
  double delay, elapsed = 0, from = 0, target = 0;
  final bool wait;
  int updateIndex;
  bool hiding = false, tweenStarted = false;
  _Phase phase = _Phase.delay;
  final completer = Completer<StoryDispatchCompletion>();
  StoryDispatchOperation get dispatch => StoryDispatchOperation(
    completion: completer.future,
    waitForCompletion: wait,
  );
  _Operation copy() {
    final result = _Operation(
      id: id,
      commandIndex: commandIndex,
      executionId: executionId,
      ref: ref,
      namedState: namedState,
      fade: fade,
      delay: delay,
      wait: wait,
      updateIndex: updateIndex,
    );
    result.elapsed = elapsed;
    result.from = from;
    result.target = target;
    result.hiding = hiding;
    result.tweenStarted = tweenStarted;
    result.phase = phase;
    return result;
  }
}

final class StoryFramePlaybackSnapshot {
  StoryFramePlaybackSnapshot._(
    this.identity,
    this.epoch,
    this.storyUs,
    this.updateIndex,
    this.currentRef,
    this.order,
    this._instances,
    this._operations,
    this.nextOperation,
    this.paused,
    this.warnings, {
    this.definitionFingerprints,
  });
  final StorySourceIdentity identity;
  final int epoch, storyUs, updateIndex, nextOperation;
  final String? currentRef;
  final List<String> order, warnings;
  final Map<String, _Instance> _instances;
  final List<_Operation> _operations;
  final bool paused;
  final Map<String, String>? definitionFingerprints;
  Map<int, int> get pendingCommandIndices =>
      Map.unmodifiable({for (final op in _operations) op.id: op.commandIndex});
}

/// Receives unscaled active storyUs and monotonically increasing real Update
/// indices. Animator.speed is captured after each command's delay and remains
/// owned by that frame. Fades capture duration/speed once at dispatch.
final class StoryFramePlayback {
  StoryFramePlayback({
    required this.sourceIdentity,
    required this.sourceEpoch,
    required Map<String, StoryFrameSource> actualFrames,
    required this.actualFadeEase,
    required int actualStoryUs,
    required int actualUpdateIndex,
    required double currentSpeed,
    this.actualLayoutResolver,
    this.actualSnapshotCatalog,
    this.renderProfile,
  }) : _lastUs = actualStoryUs,
       _updateIndex = actualUpdateIndex {
    _inputs(actualStoryUs, currentSpeed, actualUpdateIndex);
    if (sourceEpoch < 0) throw const FormatException('frame_source_epoch');
    if (actualFadeEase != 1 && actualFadeEase != 6) {
      throw UnsupportedError('frame_fade_ease:$actualFadeEase');
    }
    for (final entry in actualFrames.entries) {
      if (entry.key != entry.value.ref) {
        throw const FormatException('frame_ref_identity');
      }
      _instances[entry.key] = _Instance(entry.value);
      _order.add(entry.key);
      _definitionOrder.add(entry.key);
    }
    final catalog = actualSnapshotCatalog;
    if (renderProfile != null &&
        renderProfile!.chapterIdentity != sourceIdentity) {
      throw const FormatException('frame_render_profile_chapter');
    }
    if (catalog != null &&
        (catalog.sourceId !=
                (renderProfile?.packetSource.sourceId ??
                    sourceIdentity.sourceId) ||
            catalog.definitionFingerprints.length != _instances.length ||
            !_instances.keys.every(
              catalog.definitionFingerprints.containsKey,
            ))) {
      throw const FormatException('frame_snapshot_catalog_definitions');
    }
  }
  final StorySourceIdentity sourceIdentity;
  final StoryRenderProfileBinding? renderProfile;
  final int sourceEpoch, actualFadeEase;
  final StoryFrameLayoutResolver? actualLayoutResolver;
  final StoryFrameSnapshotCatalog? actualSnapshotCatalog;
  final _instances = <String, _Instance>{};
  final _operations = <int, _Operation>{};
  final _order = <String>[], _warnings = <String>[];
  final _definitionOrder = <String>[];
  int _lastUs, _updateIndex, _nextOperation = 0;
  String? _currentRef;
  bool _closed = false, _paused = false;
  bool get hasPendingTimeline => _operations.isNotEmpty;

  /// The driver execution identifies one visit to a command, including loops.
  /// A v1 blocking operation can be rebound only when that visit is unique.
  Future<StoryDispatchCompletion>? pendingCompletionForExecution(
    int executionId, {
    int? legacyCommandIndex,
  }) {
    final exact = _operations.values
        .where((op) => op.executionId == executionId)
        .toList();
    if (exact.length > 1) {
      throw const FormatException('frame_execution_duplicate');
    }
    if (exact.isNotEmpty) return exact.single.completer.future;
    if (legacyCommandIndex == null) return null;
    final legacy = _operations.values
        .where(
          (op) =>
              op.executionId == null &&
              op.commandIndex == legacyCommandIndex &&
              op.wait,
        )
        .toList();
    if (legacy.length > 1) {
      throw const FormatException('frame_legacy_execution_ambiguous');
    }
    if (legacy.isEmpty) return null;
    legacy.single.executionId = executionId;
    return legacy.single.completer.future;
  }

  void _inputs(int us, double speed, int index) {
    if (us < 0 || index < 0 || !speed.isFinite || speed <= 0) {
      throw const FormatException('frame_clock_input');
    }
  }

  void _open() {
    if (_closed) throw const StoryFramePlaybackCancelled('closed');
  }

  StoryFramePlaybackFrame get frame => StoryFramePlaybackFrame(
    sourceIdentity: sourceIdentity,
    sourceEpoch: sourceEpoch,
    actualStoryUs: _lastUs,
    actualUpdateIndex: _updateIndex,
    current: _currentRef == null
        ? null
        : StoryFrameInstanceFrame._(
            _instances[_currentRef]!,
            actualLayoutResolver,
          ),
    visibleInstances: [
      for (final ref in _order)
        if (_instances[ref]!.active)
          StoryFrameInstanceFrame._(_instances[ref]!, actualLayoutResolver),
    ],
    warnings: _warnings,
  );
  void _finish(_Operation op) {
    if (op.hiding) {
      final instance = _instances[op.ref]!;
      instance.alpha = 0;
      instance.activate(false);
    }
    _operations.remove(op.id);
    if (!op.completer.isCompleted) {
      op.completer.complete(const StoryDispatchCompletion());
    }
  }

  void _killFade(String ref) {
    for (final op in _operations.values.toList()) {
      if (op.ref == ref && op.phase == _Phase.fade) _finish(op);
    }
  }

  void _state(_Operation op, String name, bool restart) {
    final instance = _instances[op.ref]!;
    instance.play(name, restart: restart);
    op.phase = _Phase.state;
    op.updateIndex = _updateIndex;
    if (!instance.source.animatorEnabled) _finish(op);
  }

  void _start(_Operation op, double currentSpeed) {
    final instance = _instances[op.ref]!;
    instance.speed = currentSpeed;
    if (op.namedState.isNotEmpty) {
      if (!instance.source.states.containsKey(op.namedState)) {
        _warnings.add('frame_state_missing:${op.ref}:${op.namedState}');
        _finish(op);
        return;
      }
      if (!instance.active) {
        instance.alpha = 1;
        _killFade(op.ref);
        instance.activate(true);
      }
      _state(op, op.namedState, true);
      return;
    }
    op.hiding = instance.active;
    instance.alpha = op.hiding ? 1 : 0;
    _killFade(op.ref);
    if (!op.hiding) instance.activate(true);
    final name = op.hiding ? 'Hide' : 'Show';
    if (instance.source.states.containsKey(name)) {
      if (!op.hiding && op.fade > 0) {
        op.phase = _Phase.showDelay;
        op.delay = _roundMilliseconds(op.fade);
        op.elapsed = 0;
        return;
      }
      if (!op.hiding) instance.alpha = 1;
      _state(op, name, false);
      return;
    }
    if (!op.hiding && instance.state != null) {
      instance.play(instance.state!, restart: true);
    }
    if (op.fade <= 0) {
      if (!op.hiding) instance.alpha = 1;
      _finish(op);
      return;
    }
    op.phase = _Phase.fade;
    op.elapsed = 0;
    op.target = op.hiding ? 0 : 1;
    op.updateIndex = _updateIndex;
  }

  double _roundMilliseconds(double value) {
    final scaled = value * 1000,
        floor = scaled.floor(),
        fraction = scaled - scaled.floor();
    return (fraction == .5
            ? (floor.isEven ? floor : floor + 1)
            : scaled.round()) /
        1000;
  }

  StoryDispatchOperation dispatch(
    StoryDecodedCommand command,
    int actualStoryUs,
    double currentSpeed,
    int actualUpdateIndex, {
    required List<String> localizedTargetTexts,
    int? executionId,
  }) {
    _open();
    if (command.opcode != 44) throw const FormatException('frame_opcode');
    update(
      actualStoryUs,
      speed: currentSpeed,
      paused: _paused,
      epoch: sourceEpoch,
      actualUpdateIndex: actualUpdateIndex,
    );
    if (command.ignoreData) {
      return StoryDispatchOperation(
        completion: Future.value(const StoryDispatchCompletion()),
        waitForCompletion: false,
      );
    }
    final ref = command.resourceRefs['frameRef'];
    final instance = _instances[ref];
    if (instance == null) throw UnsupportedError('frame_source_ref:$ref');
    if (instance.source.unsupported.isNotEmpty ||
        (instance.source.requiresViewportGeometry &&
            actualLayoutResolver == null)) {
      throw UnsupportedError(
        'frame_source_unsupported:${instance.source.unsupported.join(',')}',
      );
    }
    if (localizedTargetTexts.isNotEmpty) {
      _warnings.add('frame_without_text_receiver:$ref');
    }
    _currentRef = ref;
    _order.remove(ref);
    _order.add(ref!);
    instance.poses[instance.source.rootNodeId] = instance
        .poses[instance.source.rootNodeId]!
        .set(StoryFrameProperty.position, [0, 0, 0]);
    final parameter = _parameter(command.parameter(0));
    final fade = _single(
      (parameter > 0 ? parameter : command.durationUs / 1000000) / currentSpeed,
    );
    final op = _Operation(
      id: _nextOperation++,
      commandIndex: command.index,
      executionId: executionId,
      ref: ref,
      namedState: command.parameter(1) ?? '',
      fade: fade,
      delay: _single(command.delayUs / 1000000 / currentSpeed),
      wait: !command.noWait,
      updateIndex: _updateIndex,
    );
    _operations[op.id] = op;
    if (op.delay <= 0) _start(op, currentSpeed);
    return op.dispatch;
  }

  StoryFramePlaybackFrame update(
    int actualStoryUs, {
    required double speed,
    required bool paused,
    required int epoch,
    required int actualUpdateIndex,
  }) {
    advance(
      actualStoryUs,
      speed: speed,
      paused: paused,
      epoch: epoch,
      actualUpdateIndex: actualUpdateIndex,
    );
    return frame;
  }

  /// Advances the authored state without constructing a presentation frame.
  void advance(
    int actualStoryUs, {
    required double speed,
    required bool paused,
    required int epoch,
    required int actualUpdateIndex,
  }) {
    _open();
    _inputs(actualStoryUs, speed, actualUpdateIndex);
    if (epoch != sourceEpoch) {
      close('epoch');
      throw const StoryFramePlaybackCancelled('epoch');
    }
    if (actualStoryUs < _lastUs || actualUpdateIndex < _updateIndex) {
      throw const FormatException('frame_clock_reversed');
    }
    if (actualUpdateIndex == _updateIndex) {
      if (actualStoryUs != _lastUs) {
        throw const FormatException('frame_clock_without_update');
      }
      _paused = paused;
      return;
    }
    final dt = (actualStoryUs - _lastUs) / 1000000;
    _lastUs = actualStoryUs;
    _updateIndex = actualUpdateIndex;
    _paused = paused;
    if (paused) return;
    for (final instance in _instances.values) {
      if (!instance.active ||
          !instance.source.animatorEnabled ||
          instance.state == null) {
        continue;
      }
      var state = instance.source.states[instance.state]!;
      instance.seconds += dt * instance.speed * state.speed;
      final transition = state.transitions
          .where((t) => instance.seconds / state.normalizedLength >= t.exitTime)
          .firstOrNull;
      if (transition != null) {
        final next = instance.source.states[transition.destination]!;
        final overshoot =
            instance.seconds - state.normalizedLength * transition.exitTime;
        instance.state = next.name;
        instance.seconds =
            transition.offset * next.normalizedLength + overshoot;
        state = next;
      }
      instance.poses = Map.of(
        instance.source.sample(state, instance.seconds, instance.poses),
      );
      instance.activate(true);
    }
    for (final op in _operations.values.toList()) {
      if (!_operations.containsKey(op.id)) continue;
      final instance = _instances[op.ref]!;
      switch (op.phase) {
        case _Phase.delay:
        case _Phase.showDelay:
          op.elapsed += dt;
          if (op.elapsed < op.delay) continue;
          if (op.phase == _Phase.delay) {
            _start(op, speed);
          } else {
            instance.alpha = 1;
            _state(op, 'Show', false);
          }
        case _Phase.state:
          if (_updateIndex > op.updateIndex &&
              instance.state != null &&
              instance.seconds /
                      instance
                          .source
                          .states[instance.state]!
                          .normalizedLength >=
                  1) {
            _finish(op);
          }
        case _Phase.fade:
          if (!op.tweenStarted) {
            op.from = instance.alpha;
            op.tweenStarted = true;
          }
          op.elapsed += dt;
          final t = (op.elapsed / op.fade).clamp(0.0, 1.0);
          final eased = actualFadeEase == 1 ? t : 1 - (1 - t) * (1 - t);
          instance.alpha = op.from + (op.target - op.from) * eased;
          if (t >= 1) _finish(op);
      }
    }
    // Coffee's mesh refresh skips simulation below inherited alpha .01.
    // Its delta is unscaled story time, not the Animator's captured speed.
    for (final instance in _instances.values) {
      if (instance.active &&
          instance.source.particleSource != null &&
          instance.alpha >= .01) {
        instance.particleSeconds = _single(
          instance.particleSeconds + _single(dt),
        );
      }
    }
  }

  /// CancelDelay settles only command delays; animation waits and fades remain.
  void cancelDelay() {
    for (final op in _operations.values.toList()) {
      if (op.phase == _Phase.delay) _finish(op);
    }
  }

  StoryFramePlaybackSnapshot snapshot() => StoryFramePlaybackSnapshot._(
    sourceIdentity,
    sourceEpoch,
    _lastUs,
    _updateIndex,
    _currentRef,
    List.unmodifiable(_order),
    Map.unmodifiable({
      for (final entry in _instances.entries) entry.key: entry.value.copy(),
    }),
    List.unmodifiable(_operations.values.map((op) => op.copy())),
    _nextOperation,
    _paused,
    List.unmodifiable(_warnings),
    definitionFingerprints: actualSnapshotCatalog?.definitionFingerprints,
  );
  Map<int, StoryDispatchOperation> restore(
    StoryFramePlaybackSnapshot snapshot, {
    int? actualStoryUs,
    int? actualUpdateIndex,
    bool? paused,
  }) {
    _open();
    if (snapshot.identity != sourceIdentity || snapshot.epoch != sourceEpoch) {
      throw const FormatException('frame_snapshot_source');
    }
    _inputs(
      actualStoryUs ?? snapshot.storyUs,
      1,
      actualUpdateIndex ?? snapshot.updateIndex,
    );
    final fingerprints = actualSnapshotCatalog?.definitionFingerprints;
    if (snapshot._instances.length != _instances.length ||
        !_instances.keys.every(snapshot._instances.containsKey) ||
        (fingerprints != null &&
            (snapshot.definitionFingerprints?.length != fingerprints.length ||
                !fingerprints.entries.every(
                  (entry) =>
                      snapshot.definitionFingerprints?[entry.key] ==
                      entry.value,
                )))) {
      throw const FormatException('frame_snapshot_catalog_definitions');
    }
    final restoredInstances = {
      for (final entry in snapshot._instances.entries)
        entry.key: entry.value.copy(),
    };
    final restoredOperations = {
      for (final saved in snapshot._operations) saved.id: saved.copy(),
    };
    final restoredWarnings = List<String>.of(snapshot.warnings);
    _cancel('restore');
    _instances
      ..clear()
      ..addAll(restoredInstances);
    _order
      ..clear()
      ..addAll(snapshot.order);
    _warnings
      ..clear()
      ..addAll(restoredWarnings);
    _lastUs = actualStoryUs ?? snapshot.storyUs;
    _updateIndex = actualUpdateIndex ?? snapshot.updateIndex;
    _currentRef = snapshot.currentRef;
    _nextOperation = snapshot.nextOperation;
    _paused = paused ?? snapshot.paused;
    final result = <int, StoryDispatchOperation>{};
    for (final op in restoredOperations.values) {
      _operations[op.id] = op;
      result[op.id] = op.dispatch;
    }
    return Map.unmodifiable(result);
  }

  void _cancel(String reason) {
    for (final op in _operations.values) {
      if (!op.completer.isCompleted) {
        op.completer.completeError(StoryFramePlaybackCancelled(reason));
      }
    }
    _operations.clear();
  }

  void close([String reason = 'closed']) {
    if (_closed) return;
    _cancel(reason);
    _closed = true;
  }
}
