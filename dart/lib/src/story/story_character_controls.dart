/// AdvSession retains EyeBlink state by target name, including before In.
/// Explicit modes use ordinal case-insensitive comparison without trimming.
final class StoryCharacterControls {
  static const eyeBlinkTransitionSeconds = 0.20000000298023224;
  final _eyeBlinkStopped = <String>{};

  bool eyeBlinkStopped(String target) => _eyeBlinkStopped.contains(target);
  List<String> snapshot() => List.unmodifiable(_eyeBlinkStopped);

  void restore(Iterable<String> stoppedTargets) {
    _eyeBlinkStopped
      ..clear()
      ..addAll(stoppedTargets);
  }

  /// Invalid parameters have no side effects, matching TryResolveStopRequest.
  bool? applyEyeBlink(String target, String? parameter) {
    final mode = parameter?.toLowerCase() ?? '';
    final stopped = switch (mode) {
      '' => !eyeBlinkStopped(target),
      'stop' => true,
      'resume' => false,
      _ => null,
    };
    if (stopped == true) _eyeBlinkStopped.add(target);
    if (stopped == false) _eyeBlinkStopped.remove(target);
    return stopped;
  }
}
