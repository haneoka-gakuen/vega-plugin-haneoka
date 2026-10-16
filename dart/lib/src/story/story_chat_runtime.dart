import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:characters/characters.dart';

import '../../render_profile.dart';

double _f(double value) => Float32List.fromList([value])[0];

final class StoryChatUpdateStamp {
  const StoryChatUpdateStamp({
    required this.sourceEpoch,
    required this.updateIndex,
    required this.storyUs,
    required this.speed,
    required this.paused,
  });
  final int sourceEpoch, updateIndex, storyUs;
  final double speed;
  final bool paused;
}

/// The selected phone retains its real memory and template instances. A host
/// Update advances transitions; neither a getter nor a timer advances them.
final class StoryChatRuntime {
  StoryChatRuntime({
    StoryChatWindowSource? source,
    required StorySourceIdentity identity,
    required this.sourceEpoch,
  }) : _source = source,
       memory = StoryChatPresentationController(
         sourceIdentity: identity,
         sourceEpoch: sourceEpoch,
       );

  StoryChatWindowSource? _source;
  bool get hasWindowSource => _source != null;
  StoryChatWindowSource get source =>
      _source ??
      (throw const FormatException('story_chat_window_not_selected'));
  final int sourceEpoch;
  final StoryChatPresentationController memory;
  final _entries = <StoryChatEntry>[];
  List<StoryChatEntry> get entries => List.unmodifiable(_entries);
  var revision = 0;
  bool active = false, _closed = false;
  bool skipWindowAdvance = true;
  String windowName = '', readText = '', typingText = '';
  int battery = 0, visibleTyping = 0, screenMode = 0;
  double viewWidth = 0, viewHeight = 0, targetY = 0;
  double scroll = 0, lockScroll = 0;
  bool _pendingMainScroll = false, _pendingLockScroll = false;
  bool _immediateMainScroll = false, _immediateLockScroll = false;
  _PhoneScroll? _mainScroll, _lockScroll;
  (double, double)? _mainScrollBounds, _lockScrollBounds;

  /// ScrollRect normalized position is resolved after its real content layout.
  bool resolveScrollLayout({
    required bool lock,
    required bool activeInHierarchy,
    required double bottomOffset,
    required double hiddenLength,
  }) {
    if (lock) {
      _lockScrollBounds = (bottomOffset, hiddenLength);
    } else {
      _mainScrollBounds = (bottomOffset, hiddenLength);
    }
    if (!activeInHierarchy) return false;
    final pending = lock ? _pendingLockScroll : _pendingMainScroll;
    final immediate = lock ? _immediateLockScroll : _immediateMainScroll;
    final current = lock ? lockScroll : scroll;
    if (pending) {
      final normalized = hiddenLength <= 0
          ? 0.0
          : _f((bottomOffset - current) / hiddenLength);
      final tween = immediate
          ? null
          : _PhoneScroll(
              normalized,
              _f(
                (source.viewController['_scrollDuration'] as num).toDouble() /
                    (_last?.speed ?? 1),
              ),
            );
      if (lock) {
        _pendingLockScroll = _immediateLockScroll = false;
        _lockScroll = tween;
      } else {
        _pendingMainScroll = _immediateMainScroll = false;
        _mainScroll = tween;
      }
    }
    final tween = lock ? _lockScroll : _mainScroll;
    final next = pending && immediate
        ? bottomOffset
        : tween == null
        ? current
        : _f(bottomOffset - _f(hiddenLength * tween.normalized));
    if (lock)
      lockScroll = next;
    else
      scroll = next;
    if (next != current) revision++;
    return next != current;
  }

  void _requestScroll({bool lock = false, required bool immediate}) {
    if (lock) {
      _pendingLockScroll = true;
      _immediateLockScroll = immediate;
    } else {
      _pendingMainScroll = true;
      _immediateMainScroll = immediate;
    }
  }

  _PhoneTransition? _transition;
  StoryChatUpdateStamp? _last;
  Completer<void>? _next;
  StoryTextPresentationController? _typing, _read;
  int? readExecutionId, typingExecutionId;
  StoryTextPresentation? presentationForExecution(int id) =>
      typingExecutionId == id
      ? typing
      : readExecutionId == id
      ? _read?.active
      : null;
  void quiesce() {
    _transition?.cancel('story_seek');
    _transition = null;
    _mainScroll = _lockScroll = null;
    _read?.cancelActive('story_seek');
    _typing?.cancelActive('story_seek');
    if (_next != null && !_next!.isCompleted) {
      _next!.completeError(const StoryPresentationCancelled('story_seek'));
    }
    _next = null;
  }

  StoryTextPresentation? get readPresentation => _read?.active;
  void bindSource(StoryChatWindowSource next) {
    _current(sourceEpoch);
    final old = _source;
    if (old != null && next.packet['sourceId'] != old.packet['sourceId']) {
      throw const FormatException('story_chat_source_changed');
    }
    if (old != null &&
        (old.selection.instanceKey != next.selection.instanceKey ||
            old.windowDomain['sourceHash'] !=
                next.windowDomain['sourceHash'])) {
      _transition?.cancel();
      _transition = null;
      _read?.close();
      _read = null;
      readExecutionId = null;
      clearTyping();
      typingExecutionId = null;
    }
    _source = next;
  }

  StoryTextPresentation presentRead({
    required StoryDecodedCommand command,
    required String text,
    required int executionId,
    required int renderedLength,
    required StoryChatUpdateStamp stamp,
  }) {
    _current(stamp.sourceEpoch);
    readExecutionId = executionId;
    _read ??= StoryTextPresentationController(
      sourceIdentity: memory.sourceIdentity,
      sourceEpoch: sourceEpoch,
    );
    return _read!.present(
      StoryTextInput(
        sourceIdentity: memory.sourceIdentity,
        sourceEpoch: sourceEpoch,
        commandIndex: command.index,
        text: text,
        letterTestText: text,
        renderedLength: renderedLength,
        kind: StoryTextKind.instant,
        typingDelaySeconds: 0,
        uiLanguageMode: 0,
        playbackSpeed: stamp.speed,
        sourceUiPath: source.windowDomain['sourcePath'] as String,
        sourceUiHash: source.windowDomain['sourceHash'] as String,
      ),
      stamp.updateIndex,
    );
  }

  StoryTextTapResult tap() {
    if (_closed) return StoryTextTapResult.ignored;
    if (_typing?.active case final presentation?) {
      if (presentation.visibleLength < presentation.renderedLength) {
        return _typing!.tap();
      }
    }
    if (acceptNext()) return StoryTextTapResult.advanced;
    return _read?.tap() ?? StoryTextTapResult.ignored;
  }

  StoryTextPresentation? get typing => _typing?.active;
  bool get nextRequested => _next != null && !_next!.isCompleted;

  void _current(int epoch) {
    if (_closed || epoch != sourceEpoch) {
      throw const StoryPresentationCancelled('chat_source_epoch');
    }
  }

  String get instanceKey => source.selection.instanceKey;
  int soundFor(StoryDecodedCommand command, {required bool window}) {
    final id = window
        ? source.selection.inOutSoundId
        : source.selection.chatSoundId;
    if (command.payload[window
            ? 'chatWindowSoundUnavailableId'
            : 'chatSoundUnavailableId'] ==
        id)
      return 0;
    return id;
  }

  double get targetX {
    if (_source == null) return 0;
    final view = source.viewController;
    final parent = source.component(
      'widget',
      source.pointer(view['_windowParentRect']),
    );
    final original = parent['m_AnchoredPosition'] as Map;
    final window = source.windowController['_windowPosition'] as Map;
    final offset = view['_incomingCallPositionOffset'] as Map;
    return _f(
      _f((original['x'] as num).toDouble() + (window['x'] as num).toDouble()) +
          (screenMode == 1 ? (offset['x'] as num).toDouble() : 0),
    );
  }

  int? memoryId(StoryDecodedCommand command) {
    final parsed = int.tryParse(command.parameters[2].trim());
    return parsed != null && parsed > 0 ? parsed : null;
  }

  void configurePixelViewport(int width, int height) {
    final scaler = source.widgetRecords.values
        .map((r) => r['data'] as Map)
        .singleWhere(
          (data) =>
              ((data['m_Script'] as Map?)?['reference'] as Map?)?['name'] ==
              'CanvasScaler',
        );
    if (scaler['m_UiScaleMode'] != 1 || scaler['m_ScreenMatchMode'] != 1) {
      throw const FormatException('story_chat_viewport_scaler');
    }
    final reference = scaler['m_ReferenceResolution'] as Map;
    final scale = math.min(
      width / (reference['x'] as num),
      height / (reference['y'] as num),
    );
    final w = _f(width / scale), h = _f(height / scale);
    if (viewWidth != w || viewHeight != h) configureViewport(w, h);
  }

  void configureViewport(double width, double height) {
    _current(sourceEpoch);
    if (!width.isFinite || !height.isFinite || width <= 0 || height <= 0) {
      throw ArgumentError('native_chat_viewport');
    }
    viewWidth = _f(width);
    viewHeight = _f(height);
    if (!active) targetY = _f(-height);
    revision++;
  }

  StoryChatWindowChange selectWindow(StoryDecodedCommand command, String name) {
    _current(sourceEpoch);
    if ('${command.payload['targetChatID']}' != source.selection.id) {
      throw UnsupportedError('native_chat_window_source');
    }
    final p = int.tryParse(command.parameters[1].trim());
    final mode = p == 1 || p == 2 ? p! : 0;
    final changed = memory.selectWindow(
      sourceEpoch,
      StoryChatWindowRequest(
        chatId: source.selection.id,
        windowInstanceKey: instanceKey,
        memoryId: memoryId(command),
        mode: mode,
        actualWindowActive: active,
        actualWindowChanged: memory.windowInstanceKey != instanceKey,
      ),
    );
    skipWindowAdvance = changed.skipFinalWait;
    if (changed.action != StoryChatWindowAction.close) {
      screenMode = mode;
      if (mode == 0 && _pendingMainScroll) _immediateMainScroll = true;
      if (mode == 2 && _pendingLockScroll) _immediateLockScroll = true;
      windowName = _formatName(name, command);
      final rawBattery = double.tryParse(command.parameters[0].trim()) ?? 0;
      battery = rawBattery.isFinite ? rawBattery.truncate() : -2147483648;
      if (changed.replaceVisibleEntries) {
        _entries
          ..clear()
          ..addAll(changed.restoreEntries);
        scroll = 0;
        lockScroll = 0;
        _mainScroll = _lockScroll = null;
        _pendingMainScroll = _pendingLockScroll = false;
        _immediateMainScroll = _immediateLockScroll = false;
        if (_entries.isNotEmpty)
          _requestScroll(lock: mode == 2, immediate: true);
      }
      typingText = '';
      visibleTyping = 0;
      revision++;
    }
    return changed;
  }

  String _formatName(String sourceName, StoryDecodedCommand command) {
    var width = 0;
    final value = StringBuffer();
    for (final char in sourceName.characters) {
      final code = char.runes.first;
      final next =
          code == 0xa0 ||
              code >= 0x20 && code < 0x7f ||
              code >= 0xff61 && code < 0xffa0
          ? 1
          : 2;
      if (width + next > 12) return '${value.toString().trimRight()}...';
      value.write(char);
      width += next;
    }
    final members = int.tryParse(command.parameters[3].trim()) ?? 0;
    final controller = source.windowController;
    return controller['_isGroupChat'] == 1 &&
            controller['_chatLayoutMode'] == 0 &&
            members >= 2 &&
            members <= 99
        ? '$value($members)'
        : value.toString();
  }

  Future<void> transition(
    bool show,
    StoryChatUpdateStamp stamp, {
    required bool shortcut,
    required int executionId,
  }) {
    _current(stamp.sourceEpoch);
    _transition?.cancel();
    final view = source.viewController;
    final windowY =
        (source.windowController['_windowPosition'] as Map)['y'] as num;
    final offset = view['_incomingCallPositionOffset'] as Map;
    final end = show
        ? _f(
            windowY.toDouble() +
                (screenMode == 1 ? (offset['y'] as num).toDouble() : 0),
          )
        : _f(-viewHeight);
    if (show) {
      targetY = _f(-viewHeight);
      active = true;
      if (_pendingMainScroll) _immediateMainScroll = true;
      if (_pendingLockScroll) _immediateLockScroll = true;
      memory.observeVisibility(sourceEpoch, instanceKey, true);
    }
    final seconds = shortcut
        ? 0.0
        : _f(
            (view[show ? '_showEaseDuration' : '_hideEaseDuration'] as num)
                    .toDouble() /
                stamp.speed,
          );
    final tween = _PhoneTransition(
      targetY,
      end,
      seconds,
      (view[show ? '_showEase' : '_hideEase'] as num).toInt(),
      show,
      executionId,
    );
    _transition = tween;
    revision++;
    if (seconds == 0) _finish(tween);
    return tween.finished.future;
  }

  bool get hasPendingTimeline =>
      _transition != null ||
      typing?.typing == true ||
      _mainScroll != null ||
      _lockScroll != null;
  Future<void>? pendingCompletionForExecution(int executionId) =>
      _transition?.executionId == executionId
      ? _transition!.finished.future
      : null;

  void _finish(_PhoneTransition tween) {
    targetY = tween.end;
    if (!tween.show) {
      active = false;
      screenMode = 0;
      memory.observeVisibility(sourceEpoch, instanceKey, false);
    }
    _transition = null;
    if (!tween.finished.isCompleted) tween.finished.complete();
    revision++;
  }

  StoryChatMutation append(
    StoryDecodedCommand command, {
    required String text,
    required String name,
    String stampAsset = '',
  }) {
    _current(sourceEpoch);
    final mutation = memory.append(
      epoch: sourceEpoch,
      commandIndex: command.index,
      kind: command.opcode == 38
          ? StoryChatEntryKind.stamp
          : StoryChatEntryKind.text,
      senderId: '${command.payload['targetChatID']}',
      name: name,
      text: text,
      stampAsset: stampAsset,
      voiceIds: command.voiceIds,
      readCount: int.tryParse(command.parameters[0].trim()) ?? 0,
      requestedMemoryId: memoryId(command),
      skipLog: command.parameters[3].trim().toLowerCase() == 'skiptalklog',
    );
    if (mutation.applyToView) {
      _entries.add(mutation.entry);
      if (!mutation.isOther) clearTyping();
      _requestScroll(immediate: false);
      if (screenMode == 2) _requestScroll(lock: true, immediate: false);
      revision++;
    }
    return mutation;
  }

  void applyRead(StoryDecodedCommand command) {
    _current(sourceEpoch);
    final count = int.tryParse(command.parameters[0].trim()) ?? 0;
    memory.applyRead(
      sourceEpoch,
      '${command.payload['targetChatID']}',
      count,
      memoryId(command),
    );
    final requested = memory.resolveMemoryId(memoryId(command));
    if (requested != null && !memory.isMemoryVisible(requested)) return;
    final sender = '${command.payload['targetChatID']}';
    for (final entry in _entries) {
      if (entry.senderId == (sender == '0' ? memory.currentChatId : sender)) {
        entry.readCount = math.max(entry.readCount ?? 0, count);
      }
    }
    revision++;
  }

  StoryTextPresentation beginTyping({
    required StoryDecodedCommand command,
    required String text,
    required int renderedLength,
    required int executionId,
    required StoryChatUpdateStamp stamp,
    required bool instant,
    required int languageMode,
  }) {
    _current(stamp.sourceEpoch);
    typingExecutionId = executionId;
    typingText = text;
    _typing ??= StoryTextPresentationController(
      sourceIdentity: memory.sourceIdentity,
      sourceEpoch: sourceEpoch,
    );
    final presentation = _typing!.present(
      StoryTextInput(
        sourceIdentity: memory.sourceIdentity,
        sourceEpoch: sourceEpoch,
        commandIndex: command.index,
        text: text,
        letterTestText: text,
        renderedLength: renderedLength,
        kind: instant ? StoryTextKind.instant : StoryTextKind.chatTyping,
        typingDelaySeconds: (source.viewController['_typingDelay'] as num)
            .toDouble(),
        uiLanguageMode: languageMode,
        playbackSpeed: stamp.speed,
        sourceUiPath: source.windowDomain['sourcePath'] as String,
        sourceUiHash: source.windowDomain['sourceHash'] as String,
      ),
      stamp.updateIndex,
    );
    visibleTyping = presentation.visibleLength;
    revision++;
    return presentation;
  }

  void clearTyping() {
    typingText = '';
    visibleTyping = 0;
    _typing?.close();
    _typing = null;
    revision++;
  }

  Future<void> requestNext() {
    _current(sourceEpoch);
    _next = Completer<void>();
    unawaited(_next!.future.catchError((Object _) {}));
    revision++;
    return _next!.future;
  }

  bool acceptNext() {
    if (_closed || !nextRequested) return false;
    _next!.complete();
    revision++;
    return true;
  }

  void actualUiPhase(StoryChatUpdateStamp stamp) {
    _current(stamp.sourceEpoch);
    final previous = _last;
    if (previous?.updateIndex == stamp.updateIndex) return;
    if (previous != null && stamp.updateIndex < previous.updateIndex) {
      throw const FormatException('native_chat_update_order');
    }
    _last = stamp;
    final delta = previous == null || stamp.paused
        ? 0.0
        : _f((stamp.storyUs - previous.storyUs) / 1000000);
    for (final lock in [false, true]) {
      final value = lock ? _lockScroll : _mainScroll;
      final bounds = lock ? _lockScrollBounds : _mainScrollBounds;
      if (value == null || bounds == null || delta == 0) continue;
      value.elapsed = _f(value.elapsed + delta);
      final position = _f(bounds.$1 - _f(bounds.$2 * value.normalized));
      if (lock)
        lockScroll = position;
      else
        scroll = position;
      if (value.elapsed >= value.seconds) {
        if (lock)
          _lockScroll = null;
        else
          _mainScroll = null;
      }
      revision++;
    }
    final tween = _transition;
    if (tween != null) {
      tween.elapsed = _f(tween.elapsed + delta);
      final t = (tween.elapsed / tween.seconds).clamp(0.0, 1.0);
      final eased = switch (tween.ease) {
        18 => t == 1 ? 1.0 : 1 - math.pow(2, -10 * t).toDouble(),
        _ => throw UnsupportedError('native_chat_source_ease:${tween.ease}'),
      };
      targetY = _f(tween.start + _f((tween.end - tween.start) * eased));
      revision++;
      if (t >= 1) _finish(tween);
    }
    _read?.update(
      StoryTextFrame(
        sourceEpoch: sourceEpoch,
        updateIndex: stamp.updateIndex,
        deltaSeconds: delta,
        paused: stamp.paused,
      ),
    );
    final text = typing;
    if (text != null) {
      final before = text.visibleLength;
      _typing!.update(
        StoryTextFrame(
          sourceEpoch: sourceEpoch,
          updateIndex: stamp.updateIndex,
          deltaSeconds: delta,
          paused: stamp.paused,
        ),
      );
      visibleTyping = text.visibleLength;
      if (before != visibleTyping) revision++;
    }
  }

  Map<String, Object?> snapshotData() => {
    'version': 1,
    'sourceIdentity': memory.sourceIdentity.toJson(),
    'windowId': _source?.selection.id,
    'windowHash': _source?.windowDomain['sourceHash'],
    'memory': memory.snapshotData(visibleEntries: _entries),
    'active': active,
    'skipWindowAdvance': skipWindowAdvance,
    'windowName': windowName,
    'readText': readText,
    'typingText': typingText,
    'battery': battery,
    'visibleTyping': visibleTyping,
    'screenMode': screenMode,
    'viewWidth': viewWidth,
    'viewHeight': viewHeight,
    'targetY': targetY,
    'scroll': scroll,
    'lockScroll': lockScroll,
    'pendingMainScroll': _pendingMainScroll,
    'pendingLockScroll': _pendingLockScroll,
    'immediateMainScroll': _immediateMainScroll,
    'immediateLockScroll': _immediateLockScroll,
    if (_mainScroll != null) 'mainScrollTween': _mainScroll!.toData(),
    if (_lockScroll != null) 'lockScrollTween': _lockScroll!.toData(),
    'readExecutionId': readExecutionId,
    'typingExecutionId': typingExecutionId,
    'read': _read?.active?.snapshot().toData(),
    'typing': _typing?.active?.snapshot().toData(),
    if (_transition case final t?)
      'transition': {
        'start': t.start,
        'end': t.end,
        'seconds': t.seconds,
        'ease': t.ease,
        'show': t.show,
        'elapsed': t.elapsed,
        'executionId': t.executionId,
      },
  };

  void restoreData(Map data, StoryChatUpdateStamp stamp) {
    _current(stamp.sourceEpoch);
    if (data['version'] != 1 ||
        data['windowId'] != _source?.selection.id ||
        data['windowHash'] != _source?.windowDomain['sourceHash']) {
      throw const FormatException('story_chat_runtime_source');
    }
    _transition?.cancel('story_seek');
    _entries
      ..clear()
      ..addAll(memory.restoreData(data['memory'] as Map));
    active = data['active'] as bool;
    if (active && _source == null)
      throw const FormatException('story_chat_active_window_missing');
    skipWindowAdvance = data['skipWindowAdvance'] as bool;
    windowName = data['windowName'] as String;
    readText = data['readText'] as String;
    typingText = data['typingText'] as String;
    battery = data['battery'] as int;
    visibleTyping = data['visibleTyping'] as int;
    screenMode = data['screenMode'] as int;
    double scalar(String key) {
      final value = (data[key] as num).toDouble();
      if (!value.isFinite)
        throw FormatException('story_chat_runtime_scalar:$key');
      return value;
    }

    viewWidth = scalar('viewWidth');
    viewHeight = scalar('viewHeight');
    targetY = scalar('targetY');
    scroll = scalar('scroll');
    lockScroll = scalar('lockScroll');
    _pendingMainScroll = data['pendingMainScroll'] as bool? ?? false;
    _pendingLockScroll = data['pendingLockScroll'] as bool? ?? false;
    _immediateMainScroll = data['immediateMainScroll'] as bool? ?? false;
    _immediateLockScroll = data['immediateLockScroll'] as bool? ?? false;
    _mainScroll = _PhoneScroll.fromData(data['mainScrollTween']);
    _lockScroll = _PhoneScroll.fromData(data['lockScrollTween']);
    _mainScrollBounds = _lockScrollBounds = null;
    readExecutionId = data['readExecutionId'] as int?;
    typingExecutionId = data['typingExecutionId'] as int?;
    StoryTextPresentationController? restoreText(Object? raw) {
      if (raw == null) return null;
      final controller = StoryTextPresentationController(
        sourceIdentity: memory.sourceIdentity,
        sourceEpoch: sourceEpoch,
      );
      controller.restoreData(
        raw as Map,
        actualUpdateIndex: stamp.updateIndex,
        validateUiSource: (path, hash) =>
            path == source.windowDomain['sourcePath'] &&
            hash == source.windowDomain['sourceHash'],
      );
      return controller;
    }

    _read?.close();
    _typing?.close();
    _read = restoreText(data['read']);
    _typing = restoreText(data['typing']);
    final raw = data['transition'];
    _transition = raw is Map
        ? (_PhoneTransition(
            (raw['start'] as num).toDouble(),
            (raw['end'] as num).toDouble(),
            (raw['seconds'] as num).toDouble(),
            raw['ease'] as int,
            raw['show'] as bool,
            raw['executionId'] as int,
          )..elapsed = (raw['elapsed'] as num).toDouble())
        : null;
    _last = stamp;
    revision++;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _mainScroll = _lockScroll = null;
    _transition?.cancel('chat_source_closed');
    _transition = null;
    _typing?.close();
    _read?.close();
    if (_next != null && !_next!.isCompleted) {
      _next!.completeError(
        const StoryPresentationCancelled('chat_source_closed'),
      );
    }
    memory.close();
    _entries.clear();
    active = false;
  }
}

final class _PhoneTransition {
  _PhoneTransition(
    this.start,
    this.end,
    this.seconds,
    this.ease,
    this.show,
    this.executionId,
  ) {
    unawaited(finished.future.catchError((Object _) {}));
  }
  final double start, end, seconds;
  final int ease, executionId;
  final bool show;
  double elapsed = 0;
  final finished = Completer<void>();
  void cancel([String? reason]) {
    if (finished.isCompleted) return;
    if (reason == null) {
      finished.complete();
    } else {
      finished.completeError(StoryPresentationCancelled(reason));
    }
  }
}

final class _PhoneScroll {
  _PhoneScroll(this.start, this.seconds);
  final double start, seconds;
  double elapsed = 0;
  double get normalized {
    if (seconds <= 0 || elapsed >= seconds) return 0;
    final t = _f(elapsed / seconds);
    final ease = _f(-t * _f(t - 2));
    return _f(start + _f(-start * ease));
  }

  Map<String, Object?> toData() => {
    'start': start,
    'seconds': seconds,
    'elapsed': elapsed,
  };
  static _PhoneScroll? fromData(Object? data) => data is Map
      ? (_PhoneScroll(
          (data['start'] as num).toDouble(),
          (data['seconds'] as num).toDouble(),
        )..elapsed = (data['elapsed'] as num).toDouble())
      : null;
}
