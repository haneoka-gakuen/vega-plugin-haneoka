export 'package:vega_protocol/vega_protocol.dart' show StorySourceIdentity;

import 'package:vega_protocol/vega_protocol.dart' show StorySourceIdentity;

enum StoryMediaKind { voice, bgm, sfx, movie }

final class StoryMediaObservation {
  StoryMediaObservation({
    required this.cueId,
    required this.kind,
    required this.positionUs,
    required this.playing,
    required this.completed,
    this.durationUs,
    this.error,
    required this.sourceEpoch,
  }) {
    if (cueId.isEmpty ||
        positionUs < 0 ||
        (durationUs != null && durationUs! < 0)) {
      throw const FormatException('story_media_observation');
    }
  }
  final String cueId;
  final StoryMediaKind kind;
  final int positionUs, sourceEpoch;
  final int? durationUs;
  final bool playing, completed;
  final String? error;
}

final class StoryAcknowledgement {
  const StoryAcknowledgement({
    required this.commandIndex,
    required this.atUs,
    this.choiceKey,
  });
  final int commandIndex, atUs;
  final String? choiceKey;
}

final class StoryRuntimeInputs {
  StoryRuntimeInputs({
    required this.sourceIdentity,
    required this.atUs,
    required this.sourceEpoch,
    this.executionOwnershipKnown = false,
    this.blockingExecutionId,
    Iterable<StoryMediaObservation> mediaObservations = const [],
    Iterable<StoryAcknowledgement> acknowledgements = const [],
    Set<int> dispatchedCommands = const {},
  }) : mediaObservations = List.unmodifiable(mediaObservations),
       acknowledgements = List.unmodifiable(acknowledgements),
       dispatchedCommands = Set.unmodifiable(dispatchedCommands) {
    if (atUs < 0 || sourceEpoch < 0) {
      throw const FormatException('story_runtime_clock');
    }
    if (this.mediaObservations.any(
      (value) => value.sourceEpoch != sourceEpoch,
    )) {
      throw const FormatException('story_media_epoch');
    }
  }
  final StorySourceIdentity sourceIdentity;
  final int atUs, sourceEpoch;
  final bool executionOwnershipKnown;
  final int? blockingExecutionId;
  final List<StoryMediaObservation> mediaObservations;
  final List<StoryAcknowledgement> acknowledgements;
  final Set<int> dispatchedCommands;
}

enum StoryPassKind { world, video, still, screenImage, frame, front, dialogue }

enum StoryIntentKind {
  character,
  camera,
  stage,
  still,
  video,
  fade,
  flash,
  frame,
  effect,
  volume,
  audio,
  dialogue,
  choice,
  timeline,
  control,
}

/// An effect intent retains the actual decoded row. The GPU host resolves
/// source-owned geometry/material/model records rather than substituting art.
final class StoryEffectIntent {
  const StoryEffectIntent({
    required this.kind,
    required this.pass,
    required this.executionId,
    required this.commandIndex,
    required this.opcode,
    required this.startedAtUs,
    required this.durationUs,
    required this.parameters,
    required this.resourceRefs,
    required this.targets,
    required this.payload,
  });
  final StoryIntentKind kind;
  final StoryPassKind pass;
  final int executionId, commandIndex, opcode, startedAtUs, durationUs;
  final List<String> parameters, targets;
  final Map<String, String> resourceRefs;
  final Map<String, Object?> payload;
}

final class StoryMediaEvent {
  const StoryMediaEvent({
    required this.kind,
    required this.cueId,
    required this.commandIndex,
    required this.atUs,
    this.resourceRef,
    this.positionUs,
    this.stop = false,
  });
  final StoryMediaKind kind;
  final String cueId;
  final int commandIndex, atUs;
  final String? resourceRef;
  final int? positionUs;
  final bool stop;
}

/// A command boundary that needs real UI/media completion or unsupported data.
final class StoryBlocker {
  const StoryBlocker(this.commandIndex, this.reason);
  final int commandIndex;
  final String reason;
}

final class StorySceneState {
  StorySceneState({
    required this.sourceIdentity,
    required this.atUs,
    required this.cursor,
    required List<StoryEffectIntent> intents,
    required List<StoryMediaEvent> mediaEvents,
    required Set<int> completedCommands,
    this.blocker,
  }) : intents = List.unmodifiable(intents),
       mediaEvents = List.unmodifiable(mediaEvents),
       completedCommands = Set.unmodifiable(completedCommands);
  final StorySourceIdentity sourceIdentity;
  final int atUs, cursor;
  final List<StoryEffectIntent> intents;
  final List<StoryMediaEvent> mediaEvents;
  final Set<int> completedCommands;
  final StoryBlocker? blocker;
  bool get isBlocked => blocker != null;
}
