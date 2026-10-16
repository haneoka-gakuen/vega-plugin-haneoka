/// Source presentation durations during a normal run or a shortcut replay.
/// The host already advances accepted scene time at the selected playback speed.
final class StoryPresentationTiming {
  const StoryPresentationTiming({this.shortcut = false});

  final bool shortcut;

  int durationUs(int authoredDurationUs) => shortcut ? 0 : authoredDurationUs;
}
