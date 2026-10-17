import 'dart:math' as math;

import 'story_command_decoder.dart';

final class StoryCharacterMotionRequest {
  const StoryCharacterMotionRequest({
    required this.commandIndex,
    required this.motionName,
    required this.expressionName,
    required this.fade,
    required this.waitSeconds,
  });

  factory StoryCharacterMotionRequest.fromCommand(
    StoryDecodedCommand command, {
    bool shortcut = false,
  }) => StoryCharacterMotionRequest(
    commandIndex: command.index,
    motionName: command.opcode == 21
        ? command.payload['motionName'] as String? ?? ''
        : '',
    expressionName: command.payload['expressionName'] as String? ?? '',
    fade: shortcut
        ? 0
        : (command.payload['motionFadeIn'] as num?)?.toDouble() ?? 0,
    waitSeconds: shortcut || command.opcode != 21
        ? 0
        : math.max(0, (command.payload['motionWait'] as num?)?.toDouble() ?? 0),
  );

  final int commandIndex;
  final String motionName, expressionName;
  final double fade, waitSeconds;
}

final class StoryCharacterMotionEntry<T> {
  StoryCharacterMotionEntry({
    required this.target,
    required this.controller,
    required this.request,
    required this.remainingSeconds,
    this.admittedAtUs,
  });
  final String target;
  final T controller;
  final StoryCharacterMotionRequest request;
  double remainingSeconds;
  int? admittedAtUs;

  StoryCharacterMotionEntry<T> copy() => StoryCharacterMotionEntry(
    target: target,
    controller: controller,
    request: request,
    remainingSeconds: remainingSeconds,
    admittedAtUs: admittedAtUs,
  );
}

/// AdvMotionController serializes waits per character and retains the selected
/// controller. A completed wait never lends its overshoot to the next request.
final class StoryCharacterMotionQueue<T> {
  final _queues = <String, List<StoryCharacterMotionEntry<T>>>{};

  bool get isEmpty => _queues.isEmpty;

  void dispatch({
    required String target,
    required T controller,
    required StoryCharacterMotionRequest request,
    required void Function(T, StoryCharacterMotionRequest) play,
    int? atUs,
  }) {
    if (request.waitSeconds <= 0) {
      play(controller, request);
      _queues.remove(target);
      return;
    }
    final queue = _queues[target] ??= [];
    queue.add(
      StoryCharacterMotionEntry(
        target: target,
        controller: controller,
        request: request,
        remainingSeconds: request.waitSeconds,
        admittedAtUs: queue.isEmpty ? atUs : null,
      ),
    );
  }

  void advance(
    double deltaSeconds, {
    required bool Function(String, T) showing,
    required void Function(T, StoryCharacterMotionRequest) play,
    int? atUs,
    double speed = 1,
  }) {
    if (_queues.isEmpty) return;
    for (final entry in _queues.entries.toList()) {
      final queue = entry.value, current = entry.value.first;
      final admittedAtUs = current.admittedAtUs;
      current.admittedAtUs = null;
      if (!showing(entry.key, current.controller)) continue;
      final elapsed = admittedAtUs != null && atUs != null
          ? math.min(
              deltaSeconds,
              math.max(0, atUs - admittedAtUs) / 1000000 * speed,
            )
          : deltaSeconds;
      current.remainingSeconds -= elapsed;
      if (current.remainingSeconds > 0) continue;
      queue.removeAt(0);
      if (queue.isEmpty) _queues.remove(entry.key);
      play(current.controller, current.request);
    }
  }

  double? nextWaitSeconds({required bool Function(String, T) showing}) {
    double? next;
    for (final entry in _queues.entries) {
      final current = entry.value.first;
      if (!showing(entry.key, current.controller)) continue;
      next = math.min(
        next ?? current.remainingSeconds,
        current.remainingSeconds,
      );
    }
    return next;
  }

  List<StoryCharacterMotionEntry<T>> snapshot() => [
    for (final queue in _queues.values)
      for (final entry in queue) entry.copy(),
  ];

  void restore(Iterable<StoryCharacterMotionEntry<T>> entries) {
    _queues.clear();
    for (final entry in entries) {
      final restored = entry.copy()..admittedAtUs = null;
      (_queues[entry.target] ??= []).add(restored);
    }
  }

  void clear() => _queues.clear();
}
