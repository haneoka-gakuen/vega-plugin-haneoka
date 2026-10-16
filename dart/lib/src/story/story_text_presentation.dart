import 'dart:async';
import 'dart:typed_data';

import 'story_scene_state.dart';

enum StoryTextKind { talk, chatTyping, instant }

enum StoryTextTapResult { revealRequested, advanced, ignored, choiceLocked }

final class StoryPresentationCancelled implements Exception {
  const StoryPresentationCancelled(this.reason);
  final String reason;
  @override
  String toString() => 'StoryPresentationCancelled($reason)';
}

final _floatSlot = Float32List(1);
double _f32(double value) {
  _floatSlot[0] = value;
  return _floatSlot[0];
}

/// These inputs come from the actual native UI layout and source prefab.
/// The glyph count includes the renderer's ruby/emoji preprocessing.
final class StoryTextInput {
  StoryTextInput({
    required this.sourceIdentity,
    required this.sourceEpoch,
    required this.commandIndex,
    required this.text,
    required this.letterTestText,
    required this.renderedLength,
    required this.kind,
    required this.typingDelaySeconds,
    required this.uiLanguageMode,
    required this.playbackSpeed,
    required this.sourceUiPath,
    required this.sourceUiHash,
  }) {
    if (sourceEpoch < 0 ||
        commandIndex < 0 ||
        renderedLength < 0 ||
        !typingDelaySeconds.isFinite ||
        typingDelaySeconds < 0 ||
        !playbackSpeed.isFinite ||
        playbackSpeed <= 0 ||
        sourceUiPath.isEmpty ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(sourceUiHash)) {
      throw const FormatException('story_text_presentation_input');
    }
  }
  final StorySourceIdentity sourceIdentity;
  final int sourceEpoch, commandIndex, renderedLength, uiLanguageMode;
  final String text, letterTestText, sourceUiPath, sourceUiHash;
  final StoryTextKind kind;
  final double typingDelaySeconds, playbackSpeed;

  double get capturedDelaySeconds {
    final source =
        kind == StoryTextKind.talk &&
            (uiLanguageMode == 1 || uiLanguageMode == 4)
        ? _f32(.015)
        : _f32(typingDelaySeconds);
    final divided = _f32(source / playbackSpeed);
    return _f32((divided * 1000 + .5).truncate() / 1000);
  }
}

final class StoryTextFrame {
  StoryTextFrame({
    required this.sourceEpoch,
    required this.updateIndex,
    required this.deltaSeconds,
    required this.paused,
  }) {
    if (updateIndex < 0 || !deltaSeconds.isFinite || deltaSeconds < 0) {
      throw const FormatException('story_text_frame');
    }
  }
  final int sourceEpoch, updateIndex;
  final double deltaSeconds;
  final bool paused;
}

enum _TypingPhase { nextUpdate, delay, complete }

final class StoryTextPresentationSnapshot {
  const StoryTextPresentationSnapshot._(
    this.input,
    this.visibleLength,
    this.phase,
    this.delayElapsed,
    this.revealRequested,
    this.choiceLocked,
    this.firstTapAccepted,
    this.nextWaiting,
  );
  final StoryTextInput input;
  final int visibleLength;
  final _TypingPhase phase;
  final double delayElapsed;
  final bool revealRequested, choiceLocked, firstTapAccepted, nextWaiting;

  Map<String, Object?> toData() => {
    'version': 1,
    'source': input.sourceIdentity.toJson(),
    'input': {
      'commandIndex': input.commandIndex,
      'text': input.text,
      'letterTestText': input.letterTestText,
      'renderedLength': input.renderedLength,
      'kind': input.kind.name,
      'typingDelaySeconds': input.typingDelaySeconds,
      'uiLanguageMode': input.uiLanguageMode,
      'playbackSpeed': input.playbackSpeed,
      'sourceUiPath': input.sourceUiPath,
      'sourceUiHash': input.sourceUiHash,
    },
    'visibleLength': visibleLength,
    'phase': phase.name,
    'delayElapsed': delayElapsed,
    'revealRequested': revealRequested,
    'choiceLocked': choiceLocked,
    'firstTapAccepted': firstTapAccepted,
    'nextWaiting': nextWaiting,
  };

  factory StoryTextPresentationSnapshot.fromData(
    Map data, {
    required StorySourceIdentity sourceIdentity,
    required int sourceEpoch,
    required bool Function(String path, String hash) validateUiSource,
  }) {
    if (data['version'] != 1 ||
        StorySourceIdentity.fromJson(data['source'] as Map) != sourceIdentity) {
      throw const FormatException('story_text_data_source');
    }
    final saved = data['input'] as Map;
    final path = saved['sourceUiPath'] as String,
        hash = saved['sourceUiHash'] as String;
    if (!validateUiSource(path, hash)) {
      throw const FormatException('story_text_data_ui_binding');
    }
    final input = StoryTextInput(
      sourceIdentity: sourceIdentity,
      sourceEpoch: sourceEpoch,
      commandIndex: saved['commandIndex'] as int,
      text: saved['text'] as String,
      letterTestText: saved['letterTestText'] as String,
      renderedLength: saved['renderedLength'] as int,
      kind: StoryTextKind.values.firstWhere(
        (kind) => kind.name == saved['kind'],
        orElse: () => throw const FormatException('story_text_data_kind'),
      ),
      typingDelaySeconds: (saved['typingDelaySeconds'] as num).toDouble(),
      uiLanguageMode: saved['uiLanguageMode'] as int,
      playbackSpeed: (saved['playbackSpeed'] as num).toDouble(),
      sourceUiPath: path,
      sourceUiHash: hash,
    );
    final visible = data['visibleLength'] as int,
        elapsed = (data['delayElapsed'] as num).toDouble();
    final phase = _TypingPhase.values.firstWhere(
      (phase) => phase.name == data['phase'],
      orElse: () => throw const FormatException('story_text_data_phase'),
    );
    if (visible < 0 ||
        visible > input.renderedLength ||
        !elapsed.isFinite ||
        elapsed < 0 ||
        (phase == _TypingPhase.complete && visible != input.renderedLength) ||
        (input.kind == StoryTextKind.instant &&
            phase != _TypingPhase.complete)) {
      throw const FormatException('story_text_data_progress');
    }
    return StoryTextPresentationSnapshot._(
      input,
      visible,
      phase,
      elapsed,
      data['revealRequested'] as bool,
      data['choiceLocked'] as bool,
      data['firstTapAccepted'] as bool,
      data['nextWaiting'] as bool,
    );
  }
}

void _observeCancellation(Future<void> future) {
  // A source may close before the host registers its await. Preserve the
  // original error future while preventing an unobserved cancellation log.
  unawaited(future.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
}

final class StoryTextPresentation {
  StoryTextPresentation._(this.input, int updateIndex)
    : _lastUpdate = updateIndex,
      _delaySeconds = input.capturedDelaySeconds,
      _phase = input.kind == StoryTextKind.instant || input.renderedLength == 0
          ? _TypingPhase.complete
          : _TypingPhase.nextUpdate,
      _visibleLength = input.kind == StoryTextKind.instant
          ? input.renderedLength
          : input.renderedLength > 0
          ? 1
          : 0 {
    _observeCancellation(_revealed.future);
    _observeCancellation(_firstTap.future);
    if (_phase == _TypingPhase.complete) _revealed.complete();
  }
  final StoryTextInput input;
  final double _delaySeconds;
  final _revealed = Completer<void>(), _firstTap = Completer<void>();
  Completer<void>? _next;
  int _lastUpdate, _visibleLength;
  double _delayElapsed = 0;
  _TypingPhase _phase;
  bool _revealRequested = false, _cancelled = false, choiceLocked = false;

  int get renderedLength => input.renderedLength;
  int get visibleLength => _visibleLength;
  bool get typing => _phase != _TypingPhase.complete && !_cancelled;
  bool get cancelled => _cancelled;
  Future<void> get fullyRevealed => _revealed.future;
  Future<void> get firstTap => _firstTap.future;

  StoryTextPresentationSnapshot snapshot() {
    if (_cancelled) throw const StoryPresentationCancelled('snapshot_closed');
    return StoryTextPresentationSnapshot._(
      input,
      _visibleLength,
      _phase,
      _delayElapsed,
      _revealRequested,
      choiceLocked,
      _firstTap.isCompleted,
      _next != null && !_next!.isCompleted,
    );
  }

  /// A new waiter has a fresh input barrier; the video first phase cannot
  /// satisfy this future using the tap that already ended that phase.
  Future<void> waitForNextStep() {
    if (_cancelled) {
      return Future.error(const StoryPresentationCancelled('closed'));
    }
    if (_next == null || _next!.isCompleted) {
      _next = Completer<void>();
      _observeCancellation(_next!.future);
    }
    return _next!.future;
  }

  /// A display preference reveals on the next real update without accepting
  /// a user's Next input or satisfying the first physical tap barrier.
  void requestReveal(int sourceEpoch) {
    if (!_cancelled && sourceEpoch == input.sourceEpoch && typing) {
      _revealRequested = true;
    }
  }

  StoryTextTapResult tap(int sourceEpoch) {
    if (_cancelled || sourceEpoch != input.sourceEpoch) {
      return StoryTextTapResult.ignored;
    }
    if (choiceLocked) return StoryTextTapResult.choiceLocked;
    if (!_firstTap.isCompleted) _firstTap.complete();
    if (typing) {
      _revealRequested = true;
      return StoryTextTapResult.revealRequested;
    }
    if (_next != null && !_next!.isCompleted) {
      _next!.complete();
      return StoryTextTapResult.advanced;
    }
    return StoryTextTapResult.ignored;
  }

  /// The host supplies the real Auto/GoNext update; no text duration is
  /// manufactured here and this does not masquerade as a physical tap.
  bool automaticNext(int sourceEpoch) {
    if (_cancelled ||
        sourceEpoch != input.sourceEpoch ||
        typing ||
        choiceLocked) {
      return false;
    }
    if (_next != null && !_next!.isCompleted) {
      _next!.complete();
      return true;
    }
    return false;
  }

  void update(StoryTextFrame frame) {
    if (_cancelled) return;
    if (frame.sourceEpoch != input.sourceEpoch) {
      cancel('source_epoch');
      return;
    }
    if (frame.updateIndex <= _lastUpdate) return;
    _lastUpdate = frame.updateIndex;
    if (_revealRequested) {
      _visibleLength = renderedLength;
      _finishTyping();
      return;
    }
    if (!typing) return;
    if (_phase == _TypingPhase.nextUpdate) {
      if (frame.paused) return;
      final index = _visibleLength - 1;
      final code = index < input.letterTestText.length
          ? input.letterTestText.codeUnitAt(index)
          : -1;
      final asciiLetter = code >= 65 && code <= 90 || code >= 97 && code <= 122;
      if (asciiLetter) {
        _advanceGlyph();
      } else {
        _phase = _TypingPhase.delay;
        _delayElapsed = 0;
      }
    } else {
      _delayElapsed = _f32(_delayElapsed + _f32(frame.deltaSeconds));
      if (_delayElapsed >= _delaySeconds) _advanceGlyph();
    }
  }

  void _advanceGlyph() {
    if (_visibleLength >= renderedLength) {
      _finishTyping();
    } else {
      _visibleLength++;
      _phase = _TypingPhase.nextUpdate;
    }
  }

  void _finishTyping() {
    _phase = _TypingPhase.complete;
    if (!_revealed.isCompleted) _revealed.complete();
  }

  void cancel(String reason) {
    if (_cancelled) return;
    _cancelled = true;
    final error = StoryPresentationCancelled(reason);
    for (final c in [_revealed, _firstTap, ?_next]) {
      if (!c.isCompleted) c.completeError(error);
    }
  }
}

final class StoryTextPresentationController {
  StoryTextPresentationController({
    required this.sourceIdentity,
    required this.sourceEpoch,
  });
  final StorySourceIdentity sourceIdentity;
  final int sourceEpoch;
  StoryTextPresentation? _active;
  bool _closed = false;
  StoryTextPresentation? get active => _active;

  StoryTextPresentation present(StoryTextInput input, int actualUpdateIndex) {
    if (_closed ||
        input.sourceEpoch != sourceEpoch ||
        input.sourceIdentity != sourceIdentity) {
      throw const StoryPresentationCancelled('source_identity');
    }
    _active?.cancel('replaced');
    return _active = StoryTextPresentation._(input, actualUpdateIndex);
  }

  StoryTextPresentation restore(
    StoryTextPresentationSnapshot snapshot,
    int actualUpdateIndex,
  ) {
    final presentation = present(snapshot.input, actualUpdateIndex);
    presentation
      .._visibleLength = snapshot.visibleLength
      .._phase = snapshot.phase
      .._delayElapsed = snapshot.delayElapsed
      .._revealRequested = snapshot.revealRequested
      ..choiceLocked = snapshot.choiceLocked;
    if (snapshot.phase == _TypingPhase.complete &&
        !presentation._revealed.isCompleted) {
      presentation._revealed.complete();
    }
    if (snapshot.firstTapAccepted) presentation._firstTap.complete();
    if (snapshot.nextWaiting) presentation.waitForNextStep();
    return presentation;
  }

  StoryTextPresentation restoreData(
    Map data, {
    required int actualUpdateIndex,
    required bool Function(String path, String hash) validateUiSource,
  }) => restore(
    StoryTextPresentationSnapshot.fromData(
      data,
      sourceIdentity: sourceIdentity,
      sourceEpoch: sourceEpoch,
      validateUiSource: validateUiSource,
    ),
    actualUpdateIndex,
  );

  void update(StoryTextFrame frame) => _active?.update(frame);
  StoryTextTapResult tap() =>
      _active?.tap(sourceEpoch) ?? StoryTextTapResult.ignored;
  void cancelActive(String reason) {
    _active?.cancel(reason);
    _active = null;
  }

  void close() {
    _closed = true;
    _active?.cancel('source_closed');
    _active = null;
  }
}
