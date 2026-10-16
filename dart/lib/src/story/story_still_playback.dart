import 'dart:async';
import 'dart:typed_data';

import 'story_command_decoder.dart';
import 'story_scene_state.dart';
import 'story_still_animator.dart';
import 'story_still_external_layout.dart';
import 'story_timeline.dart';
part 'story_still_playback_data.dart';

final _float = Float32List(1);
double _single(double value) {
  _float[0] = value;
  return _float[0];
}

double _parameter(String? value) {
  final text = (value ?? '').trim();
  if (!RegExp(r'^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$').hasMatch(text)) {
    return 0;
  }
  final parsed = double.tryParse(text);
  if (parsed == null || !parsed.isFinite) return 0;
  final result = _single(parsed);
  return result.isFinite ? result : 0;
}

int _index(String? value) {
  final text = (value ?? '').trim();
  if (!RegExp(r'^[+-]?\d+$').hasMatch(text)) return 0;
  final result = int.tryParse(text);
  return result != null && result >= -2147483648 && result <= 2147483647
      ? result
      : 0;
}

final class StoryStillPlaybackCancelled implements Exception {
  const StoryStillPlaybackCancelled(this.reason);
  final String reason;
  @override
  String toString() => 'StoryStillPlaybackCancelled($reason)';
}

final class StoryStillInstanceFrame {
  const StoryStillInstanceFrame({
    required this.ref,
    required this.active,
    required this.alpha,
    required this.sequenceSeconds,
    required this.sequencePlaying,
    required this.sequenceId,
    required this.poses,
    required this.layout,
  });
  final String ref;
  final String? sequenceId;
  final bool active, sequencePlaying;

  /// AdvStill's CanvasGroup alpha; the host applies this once at the still root.
  final double alpha, sequenceSeconds;
  final Map<String, StoryStillPose> poses;
  final Map<String, Object?> layout;
}

final class StoryStillPlaybackFrame {
  StoryStillPlaybackFrame({
    required this.sourceIdentity,
    required this.sourceEpoch,
    required this.actualStoryUs,
    required this.current,
    required this.overlayAlpha,
    required this.backgroundAlpha,
    required this.postEffectSuppressed,
    required this.paused,
    required List<StoryStillInstanceFrame> visibleInstances,
    required List<String> warnings,
  }) : visibleInstances = List.unmodifiable(visibleInstances),
       warnings = List.unmodifiable(warnings);
  final StorySourceIdentity sourceIdentity;
  final int sourceEpoch, actualStoryUs;
  final StoryStillInstanceFrame? current;
  final double overlayAlpha, backgroundAlpha;
  final bool postEffectSuppressed, paused;

  /// Original sibling order, including other stills that remain active.
  final List<StoryStillInstanceFrame> visibleInstances;
  final List<String> warnings;
  String? get currentRef => current?.ref;
  double get alpha => current?.alpha ?? 0;
}

final class _Instance {
  _Instance(this.ref, this.animator);
  final String ref;
  final StoryStillAnimator animator;
  bool active = false, playing = false;
  double alpha = 0, seconds = 0;
  String? pendingSequence;
}

enum _Target { still, overlay, background }

final class _Fade {
  _Fade({
    required this.key,
    required this.target,
    required this.operationId,
    required this.ref,
    required this.from,
    required this.to,
    required this.duration,
    required this.hiding,
    this.elapsed = 0,
    this.started = false,
  });
  final String key;
  final _Target target;
  final String? ref;
  final int operationId;
  double from;
  final double to, duration;
  final bool hiding;
  double elapsed;
  bool started;
}

final class _Operation {
  _Operation(
    this.id,
    this.commandIndex,
    this.executionId,
    this.waitForCompletion,
    Set<String> pending,
  ) : pending = Set.of(pending) {
    unawaited(
      completion.future.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {},
      ),
    );
  }
  final int id, commandIndex;
  int? executionId;
  final bool waitForCompletion;
  final Set<String> pending;
  final completion = Completer<StoryDispatchCompletion>();
  StoryDispatchOperation get dispatched => StoryDispatchOperation(
    completion: completion.future,
    waitForCompletion: waitForCompletion,
  );
}

final class StoryStillInstanceSnapshot {
  const StoryStillInstanceSnapshot(
    this.ref,
    this.active,
    this.alpha,
    this.sequenceSeconds,
    this.sequencePlaying,
    this.animator,
    this.pendingSequence,
  );
  final String ref;
  final bool active, sequencePlaying;
  final double alpha, sequenceSeconds;
  final StoryStillSnapshot animator;
  final String? pendingSequence;
}

final class _FadeSnapshot {
  _FadeSnapshot(_Fade fade)
    : key = fade.key,
      target = fade.target,
      operationId = fade.operationId,
      ref = fade.ref,
      from = fade.from,
      to = fade.to,
      duration = fade.duration,
      hiding = fade.hiding,
      elapsed = fade.elapsed,
      started = fade.started;
  final String key;
  final _Target target;
  final String? ref;
  final int operationId;
  final double from, to, duration, elapsed;
  final bool hiding;
  final bool started;
  _Fade restore() => _Fade(
    key: key,
    target: target,
    operationId: operationId,
    ref: ref,
    from: from,
    to: to,
    duration: duration,
    hiding: hiding,
    elapsed: elapsed,
    started: started,
  );
}

final class _OperationSnapshot {
  _OperationSnapshot(_Operation operation)
    : id = operation.id,
      commandIndex = operation.commandIndex,
      executionId = operation.executionId,
      waitForCompletion = operation.waitForCompletion,
      pending = Set.unmodifiable(operation.pending);
  final int id, commandIndex;
  final int? executionId;
  final bool waitForCompletion;
  final Set<String> pending;
}

final class StoryStillPlaybackSnapshot {
  StoryStillPlaybackSnapshot._(StoryStillPlayback owner)
    : sourceIdentity = owner.sourceIdentity,
      sourceEpoch = owner.sourceEpoch,
      actualStoryUs = owner._lastStoryUs,
      speed = owner._speed,
      paused = owner._paused,
      currentRef = owner._currentRef,
      overlayAlpha = owner._overlayAlpha,
      backgroundAlpha = owner._backgroundAlpha,
      postEffectSuppressed = owner._suppressed,
      fadeEase = owner.actualFadeEase,
      nextOperation = owner._nextOperation,
      order = List.unmodifiable(owner._order),
      warnings = List.unmodifiable(owner._warnings),
      instances = Map.unmodifiable({
        for (final e in owner._instances.entries)
          e.key: StoryStillInstanceSnapshot(
            e.key,
            e.value.active,
            e.value.alpha,
            e.value.seconds,
            e.value.playing,
            e.value.animator.snapshot(),
            e.value.pendingSequence,
          ),
      }),
      _fades = List.unmodifiable(owner._fades.values.map(_FadeSnapshot.new)),
      _operations = List.unmodifiable(
        owner._operations.values.map(_OperationSnapshot.new),
      );
  final StorySourceIdentity sourceIdentity;
  final int sourceEpoch, actualStoryUs, fadeEase, nextOperation;
  final double speed, overlayAlpha, backgroundAlpha;
  final bool paused, postEffectSuppressed;
  final String? currentRef;
  final List<String> order, warnings;
  final Map<String, StoryStillInstanceSnapshot> instances;
  final List<_FadeSnapshot> _fades;
  final List<_OperationSnapshot> _operations;
  Map<int, int> get pendingCommandIndices => Map.unmodifiable({
    for (final operation in _operations) operation.id: operation.commandIndex,
  });
}

/// Still30 is driven by NativeStoryPlayback's unscaled active Stopwatch time.
/// Pause is already excluded from that clock; do not scale or subtract it again.
/// A speed change is a boundary update: settle the preceding interval using
/// the stored speed, then install the new speed. Fades capture P1/speed once;
/// animation sequences alone track subsequent speed changes.
final class StoryStillPlayback {
  StoryStillPlayback({
    required this.sourceIdentity,
    required this.sourceEpoch,
    required Map<String, Map<String, Object?>> actualStills,
    required this.actualFadeEase,
    required double actualInitialOverlayAlpha,
    required int actualStoryUs,
    required double currentSpeed,
    this.externalLayoutSource,
  }) {
    if (sourceEpoch < 0 ||
        actualStoryUs < 0 ||
        !currentSpeed.isFinite ||
        currentSpeed <= 0 ||
        !actualInitialOverlayAlpha.isFinite ||
        actualInitialOverlayAlpha < 0 ||
        actualInitialOverlayAlpha > 1) {
      throw const FormatException('story_still_playback_input');
    }
    if (actualFadeEase != 1 && actualFadeEase != 6) {
      throw UnsupportedError('story_still_fade_ease:$actualFadeEase');
    }
    for (final entry in actualStills.entries) {
      if (entry.key.isEmpty) throw const FormatException('story_still_ref');
      _instances[entry.key] = _Instance(
        entry.key,
        StoryStillAnimator(entry.value),
      );
      _order.add(entry.key);
    }
    _lastStoryUs = actualStoryUs;
    _speed = currentSpeed;
    _overlayAlpha = actualInitialOverlayAlpha;
  }
  final StorySourceIdentity sourceIdentity;
  final StoryStillExternalLayoutSource? externalLayoutSource;
  final int sourceEpoch, actualFadeEase;
  final _instances = <String, _Instance>{}, _fades = <String, _Fade>{};
  final _operations = <int, _Operation>{};
  final _order = <String>[], _warnings = <String>[];
  late int _lastStoryUs;
  late double _speed, _overlayAlpha;
  double _backgroundAlpha = 0;
  int _nextOperation = 0;
  bool _paused = false, _suppressed = false, _closed = false;
  bool get hasPendingTimeline =>
      _operations.isNotEmpty ||
      _instances.values.any(
        (instance) => instance.active && instance.animator.hasRunningPrograms,
      );

  /// A driver execution identifies one visit; command indices can recur.
  /// Legacy detached fades keep running without inventing an active execution.
  Future<StoryDispatchCompletion>? pendingCompletionForExecution(
    int executionId, {
    int? legacyCommandIndex,
  }) {
    final exact = _operations.values
        .where((op) => op.executionId == executionId)
        .toList();
    if (exact.length > 1) {
      throw const FormatException('still_execution_duplicate');
    }
    if (exact.isNotEmpty) return exact.single.completion.future;
    if (legacyCommandIndex == null) return null;
    final legacy = _operations.values
        .where(
          (op) =>
              op.executionId == null &&
              op.commandIndex == legacyCommandIndex &&
              op.waitForCompletion,
        )
        .toList();
    if (legacy.length > 1) {
      throw const FormatException('still_legacy_execution_ambiguous');
    }
    if (legacy.isEmpty) return null;
    legacy.single.executionId = executionId;
    return legacy.single.completion.future;
  }

  String? _currentRef;

  void _requireOpen() {
    if (_closed) throw const StoryStillPlaybackCancelled('closed');
  }

  StoryStillInstanceFrame _instanceFrame(_Instance instance) =>
      StoryStillInstanceFrame(
        ref: instance.ref,
        active: instance.active,
        alpha: instance.alpha,
        sequenceSeconds: instance.seconds,
        sequencePlaying: instance.playing,
        sequenceId: instance.pendingSequence ?? instance.animator.sequenceId,
        poses: instance.animator.poses,
        layout: Map.unmodifiable(
          instance.animator.layoutAtSeconds(
            instance.seconds,
            sample: externalLayoutSource == null,
          ),
        ),
      );
  StoryStillPlaybackFrame get frame => StoryStillPlaybackFrame(
    sourceIdentity: sourceIdentity,
    sourceEpoch: sourceEpoch,
    actualStoryUs: _lastStoryUs,
    current: _currentRef == null
        ? null
        : _instanceFrame(_instances[_currentRef]!),
    overlayAlpha: _overlayAlpha,
    backgroundAlpha: _backgroundAlpha,
    postEffectSuppressed: _suppressed,
    paused: _paused,
    visibleInstances: [
      for (final ref in _order)
        if (_instances[ref]!.active) _instanceFrame(_instances[ref]!),
    ],
    warnings: _warnings,
  );

  StoryStillPlaybackFrame update(
    int actualStoryUs, {
    required double speed,
    required bool paused,
    required int epoch,
  }) {
    _requireOpen();
    if (epoch != sourceEpoch) {
      close('source_epoch');
      throw const StoryStillPlaybackCancelled('source_epoch');
    }
    if (actualStoryUs < _lastStoryUs || !speed.isFinite || speed <= 0) {
      throw const FormatException('story_still_clock');
    }
    final delta = _single((actualStoryUs - _lastStoryUs) / 1000000);
    for (final instance in _instances.values) {
      if (instance.animator.hasTimelineActions) {
        if (delta <= 0) continue;
        final pending = instance.pendingSequence;
        if (pending != null) {
          instance.animator.play(pending);
          instance.pendingSequence = null;
        }
        instance.animator.advancePrograms(_single(delta * _speed));
        instance.seconds = instance.animator.elapsedSeconds;
        instance.playing = instance.animator.selectedProgramPlaying;
        continue;
      }
      if (instance.playing) {
        if (delta <= 0) continue;
        final pending = instance.pendingSequence;
        if (pending != null) {
          instance.animator.play(pending);
          instance.pendingSequence = null;
        }
        instance.seconds = _single(instance.seconds + _single(delta * _speed));
        final selected = instance.animator.sequenceId;
        final sequence = (instance.animator.presentation['sequences'] as List)
            .cast<Map>()
            .singleWhere((s) => s['id'] == selected);
        final duration = (sequence['duration'] as num).toDouble();
        var restarted = false;
        if (delta > 0 && instance.seconds >= duration) {
          if (sequence['loop'] == true) {
            // DOTweenSequence's completion callback restarts and rewinds;
            // it discards overshoot instead of carrying a modulo remainder.
            instance.seconds = 0;
            restarted = true;
          } else {
            instance.seconds = duration;
            instance.playing = false;
          }
        }
        instance.animator.sampleAtSeconds(
          instance.seconds,
          actualUpdate: true,
          sequenceRestart: restarted,
        );
      }
    }
    final completed = <_Fade>[];
    for (final fade in _fades.values.toList()) {
      if (_fades[fade.key] != fade) continue;
      if (delta <= 0) continue;
      if (!fade.started) {
        fade.from = switch (fade.target) {
          _Target.still => _instances[fade.ref]!.alpha,
          _Target.overlay => _overlayAlpha,
          _Target.background => _backgroundAlpha,
        };
        fade.started = true;
      }
      fade.elapsed = _single(fade.elapsed + delta);
      final progress = fade.duration <= 0
          ? 1.0
          : (fade.elapsed / fade.duration).clamp(0.0, 1.0);
      final eased = actualFadeEase == 1
          ? progress
          : 1 - (1 - progress) * (1 - progress);
      _apply(fade, _single(fade.from + (fade.to - fade.from) * eased));
      if (progress >= 1) completed.add(fade);
    }
    // The source runner despawns completed tweens after its update loop;
    // their await continuations run after all current-frame tween writes.
    for (final fade in completed) {
      _finish(fade);
    }
    _lastStoryUs = actualStoryUs;
    _speed = speed;
    _paused = paused;
    return frame;
  }

  void _apply(_Fade fade, double value) {
    switch (fade.target) {
      case _Target.still:
        _instances[fade.ref]!.alpha = value;
      case _Target.overlay:
        _overlayAlpha = value;
      case _Target.background:
        _backgroundAlpha = value;
    }
  }

  void _finish(_Fade fade) {
    if (_fades[fade.key] != fade) return;
    if (fade.target == _Target.still) _apply(fade, fade.to);
    _fades.remove(fade.key);
    if (fade.target == _Target.still && fade.hiding) {
      final instance = _instances[fade.ref]!;
      instance.animator.stop();
      instance.playing = false;
      instance.pendingSequence = null;
      instance.active = false;
    }
    if (fade.target == _Target.overlay) {
      if (fade.hiding) {
        _backgroundAlpha = 0;
        _suppressed = false;
      }
      if (fade.to <= 0) _overlayAlpha = 0;
    }
    final operation = _operations[fade.operationId];
    if (operation == null) return;
    operation.pending.remove(fade.key);
    if (operation.pending.isEmpty) {
      _operations.remove(operation.id);
      operation.completion.complete(const StoryDispatchCompletion());
    }
  }

  void _cancelOperation(int id, String reason) {
    _fades.removeWhere((_, fade) => fade.operationId == id);
    final operation = _operations.remove(id);
    if (operation != null && !operation.completion.isCompleted) {
      operation.completion.completeError(StoryStillPlaybackCancelled(reason));
    }
  }

  void _start(_Fade fade) {
    _fades[fade.key] = fade;
    if (fade.target == _Target.still && fade.duration <= 0) _finish(fade);
  }

  /// Reads the four actual Still parameters and stillRef only. Source Duration
  /// and Delay are deliberately absent from this command's fade policy.
  StoryDispatchOperation dispatch(
    StoryDecodedCommand command,
    int actualStoryUs,
    double currentSpeed, {
    int? executionId,
  }) {
    _requireOpen();
    if (command.opcode != 30) throw const FormatException('story_still_opcode');
    update(
      actualStoryUs,
      speed: currentSpeed,
      paused: _paused,
      epoch: sourceEpoch,
    );
    if (command.ignoreData) {
      return StoryDispatchOperation(
        completion: Future.value(const StoryDispatchCompletion()),
        waitForCompletion: false,
      );
    }
    final ref = command.resourceRefs['stillRef'], instance = _instances[ref];
    if (instance == null) throw UnsupportedError('story_still_source_ref:$ref');
    final duration = _single(
      (_parameter(command.parameter(0)).clamp(0.0, double.infinity)) /
          currentSpeed,
    );
    final hiding = instance.active,
        alphaParameter = _parameter(command.parameter(1));
    final alpha = hiding
        ? 0.0
        : alphaParameter <= 0
        ? 1.0
        : alphaParameter.clamp(0.0, 1.0);
    final overlay = hiding
        ? 0.0
        : _parameter(command.parameter(3)).clamp(0.0, 1.0);
    final id = _nextOperation++;
    final alphaKey = 'still:$ref:$id', overlayKey = 'overlay:$id';
    _currentRef = ref;
    _order.remove(ref);
    _order.add(ref!);
    _suppressed = true;
    final external = externalLayoutSource;
    if (external != null) instance.animator.requestAttachment(external);
    // A normal CanvasGroup kill resolves SetAlpha's old await. Its final
    // assignment still writes the target; a killed hide stops and deactivates
    // the still. Overlay/background tweens continue in creation order.
    for (final previous
        in _fades.values
            .where((fade) => fade.target == _Target.still && fade.ref == ref)
            .toList()) {
      _finish(previous);
    }
    if (!hiding) {
      instance.active = true;
      instance.animator.stop();
      instance.playing = false;
      instance.pendingSequence = null;
      instance.seconds = 0;
      final sequences = instance.animator.presentation['sequences'] as List;
      final selected = _index(command.parameter(2));
      if (sequences.isNotEmpty &&
          (selected < 0 || selected >= sequences.length)) {
        _warnings.add('still_sequence_index:$ref:$selected');
      } else if (sequences.isNotEmpty) {
        final sequence = Map<String, Object?>.from(sequences[selected] as Map);
        // A newly created source sequence starts on the next real Update.
        instance.pendingSequence = sequence['id'] as String;
        instance.playing = true;
      }
    }
    final operation = _Operation(
      id,
      command.index,
      executionId,
      !command.noWait,
      {alphaKey, overlayKey},
    );
    _operations[id] = operation;
    _start(
      _Fade(
        key: alphaKey,
        target: _Target.still,
        operationId: id,
        ref: ref,
        from: instance.alpha,
        to: alpha,
        duration: duration,
        hiding: hiding,
      ),
    );
    if (hiding || overlay == 0) {
      _start(
        _Fade(
          key: 'background:$id',
          target: _Target.background,
          operationId: id,
          ref: null,
          from: _backgroundAlpha,
          to: hiding ? 0 : 1,
          duration: duration,
          hiding: hiding,
        ),
      );
    }
    _start(
      _Fade(
        key: overlayKey,
        target: _Target.overlay,
        operationId: id,
        ref: null,
        from: _overlayAlpha,
        to: overlay,
        duration: duration,
        hiding: hiding,
      ),
    );
    return operation.dispatched;
  }

  StoryStillPlaybackSnapshot snapshot() {
    _requireOpen();
    return StoryStillPlaybackSnapshot._(this);
  }

  /// Minimal debug observation; callers gate this independently of rendering.
  StoryStillAttachmentSnapshot attachmentFor(String ref) {
    _requireOpen();
    final instance = _instances[ref];
    if (instance == null) {
      throw const FormatException('story_still_attachment_ref');
    }
    return instance.animator.attachment;
  }

  /// Called only at an actual positive-viewport Still layout after updates.
  void consumeAttachments(StoryStillExternalLayout layout) {
    _requireOpen();
    if (externalLayoutSource == null ||
        layout.source.sourceIdentity != sourceIdentity.sourceId ||
        layout.source.packetSHA256 != externalLayoutSource!.packetSHA256) {
      throw const FormatException('story_still_external_layout_source');
    }
    for (final instance in _instances.values) {
      instance.animator.consumeAttachment(layout);
    }
  }

  /// Restoration cancels old futures and returns fresh barriers keyed by their
  /// original operation ids. Absolute native time rebases at the supplied tick;
  /// elapsed fade/sequence clocks and captured fade durations remain unchanged.
  Map<int, StoryDispatchOperation> restore(
    StoryStillPlaybackSnapshot snapshot,
    int actualStoryUs, {
    required double speed,
    required bool paused,
    required int epoch,
  }) {
    _requireOpen();
    if (snapshot.sourceIdentity != sourceIdentity ||
        snapshot.sourceEpoch != sourceEpoch ||
        epoch != sourceEpoch ||
        snapshot.fadeEase != actualFadeEase ||
        actualStoryUs < 0 ||
        !speed.isFinite ||
        speed <= 0 ||
        snapshot.instances.length != _instances.length ||
        !_instances.keys.every(snapshot.instances.containsKey)) {
      throw const FormatException('story_still_snapshot_source');
    }
    for (final entry in snapshot.instances.entries) {
      final attachment = entry.value.animator.attachment;
      if (attachment.revision > 0 &&
          (attachment.packetHash != externalLayoutSource?.packetSHA256 ||
              attachment.parentId != externalLayoutSource?.targetId)) {
        throw const FormatException('story_still_snapshot_external_binding');
      }
    }
    for (final id in _operations.keys.toList()) {
      _cancelOperation(id, 'restored');
    }
    for (final entry in snapshot.instances.entries) {
      final instance = _instances[entry.key]!, saved = entry.value;
      instance.animator.restore(saved.animator);
      instance.active = saved.active;
      instance.alpha = saved.alpha;
      instance.seconds = saved.sequenceSeconds;
      instance.playing = saved.sequencePlaying;
      instance.pendingSequence = saved.pendingSequence;
    }
    _order
      ..clear()
      ..addAll(snapshot.order);
    _warnings
      ..clear()
      ..addAll(snapshot.warnings);
    _currentRef = snapshot.currentRef;
    _overlayAlpha = snapshot.overlayAlpha;
    _backgroundAlpha = snapshot.backgroundAlpha;
    _suppressed = snapshot.postEffectSuppressed;
    _lastStoryUs = actualStoryUs;
    _speed = speed;
    _paused = paused;
    _nextOperation = snapshot.nextOperation;
    _fades.clear();
    for (final saved in snapshot._fades) {
      _fades[saved.key] = saved.restore();
    }
    final restored = <int, StoryDispatchOperation>{};
    for (final saved in snapshot._operations) {
      final operation = _Operation(
        saved.id,
        saved.commandIndex,
        saved.executionId,
        saved.waitForCompletion,
        saved.pending,
      );
      _operations[operation.id] = operation;
      restored[operation.id] = operation.dispatched;
    }
    return Map.unmodifiable(restored);
  }

  void close([String reason = 'closed']) {
    if (_closed) return;
    for (final id in _operations.keys.toList()) {
      _cancelOperation(id, reason);
    }
    _fades.clear();
    for (final instance in _instances.values) {
      instance.animator.stop();
      instance.playing = false;
      instance.pendingSequence = null;
    }
    _closed = true;
  }
}
