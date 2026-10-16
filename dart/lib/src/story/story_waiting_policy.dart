import 'story_command_decoder.dart';

enum StoryDialogueWaitPhase {
  preparing,
  reveal,
  nextUpdate,
  voice,
  postVoice,
  textDelay,
  minimumDisplay,
  autoDelay,
  manualNext,
  subtitleMovie,
  subtitleNext,
  subtitleLingering,
  done,
}

/// Source continuation data; media and text input barriers remain host ports.
final class StoryDialogueWaitState {
  StoryDialogueWaitState({
    required this.commandIndex,
    required this.opcode,
    required this.automatic,
    required this.capturedSpeed,
    this.phase = StoryDialogueWaitPhase.preparing,
    this.autoStartedUs = 0,
    this.timerPhase,
    this.timerDeadlineUs,
  });
  final int commandIndex, opcode;
  StoryDialogueWaitPhase phase;
  bool automatic;
  double capturedSpeed;
  int autoStartedUs;
  StoryDialogueWaitPhase? timerPhase;
  int? timerDeadlineUs;
  bool get autoOnly => switch (phase) {
    StoryDialogueWaitPhase.nextUpdate ||
    StoryDialogueWaitPhase.postVoice ||
    StoryDialogueWaitPhase.textDelay ||
    StoryDialogueWaitPhase.minimumDisplay ||
    StoryDialogueWaitPhase.autoDelay ||
    StoryDialogueWaitPhase.subtitleLingering => true,
    StoryDialogueWaitPhase.voice => opcode != 52,
    _ => false,
  };
  Map<String, Object?> toData() => {
    'commandIndex': commandIndex,
    'opcode': opcode,
    'phase': phase.name,
    'automatic': automatic,
    'capturedSpeed': capturedSpeed,
    'autoStartedUs': autoStartedUs,
    'timerPhase': timerPhase?.name,
    'timerDeadlineUs': timerDeadlineUs,
  };
  factory StoryDialogueWaitState.fromData(Map data) => StoryDialogueWaitState(
    commandIndex: data['commandIndex'] as int,
    opcode: data['opcode'] as int,
    phase: StoryDialogueWaitPhase.values.byName(data['phase'] as String),
    automatic: data['automatic'] as bool,
    capturedSpeed: (data['capturedSpeed'] as num).toDouble(),
    autoStartedUs: data['autoStartedUs'] as int,
    timerPhase: data['timerPhase'] == null
        ? null
        : StoryDialogueWaitPhase.values.byName(data['timerPhase'] as String),
    timerDeadlineUs: data['timerDeadlineUs'] as int?,
  );
  StoryDialogueWaitState copy() => StoryDialogueWaitState.fromData(toData());
}

enum StoryWaitCondition {
  preparedMedia,
  startedMedia,
  endedMedia,
  finishedFade,
  talkNextStep,
  clipEndOrFirstTap,
  subsequentNextStep,
  actualAutomaticTextWait,
  uiBodyComplete,
}

enum StoryVideoOperation { none, movie, clipStart, clipStop }

enum StoryChatOperation { none, window, talk, stamp, read, typing }

/// Typed native waiting rules derived from actual ADV commands. Host awaits
/// real media/UI signals; this plan never substitutes predicted timestamps.
final class StoryWaitingPolicy {
  const StoryWaitingPolicy({
    required this.alwaysAwaitHandler,
    required this.conditions,
    this.videoOperation = StoryVideoOperation.none,
    this.fadeInSeconds = 0,
    this.fadeOutSeconds = 0,
    this.alpha = 1,
    this.suppressClipControls = false,
    this.clearClipSkip = false,
    this.waitVideoAutoLingering = false,
    this.waitSubtitleAutoLingering = false,
    this.chatOperation = StoryChatOperation.none,
    this.skipChatFinalWait = false,
  });
  final bool alwaysAwaitHandler;
  final List<StoryWaitCondition> conditions;
  final StoryVideoOperation videoOperation;
  final double fadeInSeconds, fadeOutSeconds, alpha;
  final bool suppressClipControls, clearClipSkip;
  final bool waitVideoAutoLingering, waitSubtitleAutoLingering;
  final StoryChatOperation chatOperation;

  /// Visibility/memory and a closing window can also omit the final wait;
  /// those decisions require actual host UI state.
  final bool skipChatFinalWait;
}

/// `videoPlaying` is a real native observation (including seek/respeed).
/// Durations remain source seconds; host applies actual playback speed and
/// source runtime lingering settings instead of invented text/movie lengths.
StoryWaitingPolicy? storyWaitingPolicy(
  StoryDecodedCommand command, {
  required bool videoPlaying,
  required bool autoPlayback,
}) {
  double parameter(int index) => command.numericParameter(index) ?? 0;
  double fade(int index) => parameter(index) > 0 ? parameter(index) : 0;
  double alpha(int index) =>
      parameter(index) <= 0 ? 1 : parameter(index).clamp(0, 1).toDouble();
  final marker = (command.parameter(2) ?? '').trim().toLowerCase();
  final chatOperation = switch (command.opcode) {
    36 => StoryChatOperation.window,
    37 => StoryChatOperation.talk,
    38 => StoryChatOperation.stamp,
    39 => StoryChatOperation.read,
    65 => StoryChatOperation.typing,
    _ => StoryChatOperation.none,
  };
  if (chatOperation != StoryChatOperation.none) {
    return StoryWaitingPolicy(
      alwaysAwaitHandler:
          chatOperation != StoryChatOperation.window || !command.noWait,
      chatOperation: chatOperation,
      skipChatFinalWait: command.noWait,
      conditions: [
        StoryWaitCondition.uiBodyComplete,
        if (!command.noWait) ...[
          if (autoPlayback) StoryWaitCondition.actualAutomaticTextWait,
          StoryWaitCondition.talkNextStep,
        ],
      ],
    );
  }
  if (command.opcode == 26) {
    if (command.videoId == '0') {
      return const StoryWaitingPolicy(alwaysAwaitHandler: true, conditions: []);
    }
    return StoryWaitingPolicy(
      alwaysAwaitHandler: true,
      conditions: const [
        StoryWaitCondition.preparedMedia,
        StoryWaitCondition.startedMedia,
        StoryWaitCondition.endedMedia,
        StoryWaitCondition.finishedFade,
      ],
      videoOperation: StoryVideoOperation.movie,
      fadeInSeconds: fade(0),
      fadeOutSeconds: fade(1),
      alpha: alpha(2),
      waitVideoAutoLingering: autoPlayback && videoPlaying,
    );
  }
  if (command.opcode == 27) {
    final stop = command.videoId == '0';
    return StoryWaitingPolicy(
      alwaysAwaitHandler: true,
      conditions: stop
          ? const [StoryWaitCondition.finishedFade]
          : [
              if (videoPlaying) StoryWaitCondition.finishedFade,
              StoryWaitCondition.preparedMedia,
              StoryWaitCondition.startedMedia,
            ],
      videoOperation: stop
          ? StoryVideoOperation.clipStop
          : StoryVideoOperation.clipStart,
      fadeInSeconds: stop ? 0 : fade(0),
      fadeOutSeconds: fade(0),
      alpha: alpha(1),
      suppressClipControls: marker == 'hideclipcontrol',
      clearClipSkip: stop && marker == 'skipcliptarget',
      waitVideoAutoLingering: autoPlayback && (stop || videoPlaying),
    );
  }
  if (command.opcode == 28) {
    final valid =
        command.payload['advTextId'] is String &&
        command.payload['advTextId'] != '0' &&
        (command.payload['advTextId'] as String).isNotEmpty;
    if (!valid || command.noWait) {
      return const StoryWaitingPolicy(alwaysAwaitHandler: true, conditions: []);
    }
    return StoryWaitingPolicy(
      alwaysAwaitHandler: true,
      conditions: videoPlaying
          ? const [
              StoryWaitCondition.clipEndOrFirstTap,
              StoryWaitCondition.subsequentNextStep,
            ]
          : autoPlayback
          ? const [
              StoryWaitCondition.actualAutomaticTextWait,
              StoryWaitCondition.talkNextStep,
            ]
          : const [StoryWaitCondition.talkNextStep],
      waitSubtitleAutoLingering: videoPlaying && autoPlayback,
    );
  }
  if (command.opcode == 5) {
    return const StoryWaitingPolicy(
      alwaysAwaitHandler: true,
      conditions: [StoryWaitCondition.finishedFade],
    );
  }
  return null;
}
