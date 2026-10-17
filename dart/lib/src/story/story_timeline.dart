import 'dart:async';

import 'package:vega_protocol/execution.dart';

import 'story_command_decoder.dart';
import 'story_scene_state.dart';

/// The controller records the real start/completion after dispatching a row.
/// Repeated branch executions retain separate identities and source indices.
typedef StoryCommandExecution = VegaExecutionRecord;

/// Pure reconstruction over actual command execution history. Resource and
/// media dispatch remain host-owned; text length never invents a completion.
final class StoryTimeline {
  StoryTimeline(this.chapter, Iterable<StoryCommandExecution> executions)
    : executions = List.unmodifiable(executions) {
    final ids = <int>{};
    var previous = -1;
    for (final entry in this.executions) {
      if (!ids.add(entry.executionId) ||
          entry.startedAtUs < previous ||
          !_commands.containsKey(entry.commandIndex)) {
        throw const FormatException('story_command_execution_history');
      }
      previous = entry.startedAtUs;
    }
  }
  final StoryChapterDocument chapter;
  final List<StoryCommandExecution> executions;
  late final Map<int, StoryDecodedCommand> _commands = {
    for (final command in chapter.commands) command.index: command,
  };

  StorySceneState seek(int atUs, StoryRuntimeInputs observations) {
    return evaluateAt(
      StoryRuntimeInputs(
        sourceIdentity: observations.sourceIdentity,
        atUs: atUs,
        sourceEpoch: observations.sourceEpoch,
        executionOwnershipKnown:
            atUs == observations.atUs && observations.executionOwnershipKnown,
        blockingExecutionId: atUs == observations.atUs
            ? observations.blockingExecutionId
            : null,
        mediaObservations: observations.mediaObservations,
        acknowledgements: observations.acknowledgements,
        dispatchedCommands: observations.dispatchedCommands,
      ),
    );
  }

  StorySceneState evaluateAt(StoryRuntimeInputs inputs) {
    if (inputs.sourceIdentity != chapter.sourceIdentity) {
      throw const FormatException('story_timeline_source_mismatch');
    }
    final intents = <StoryEffectIntent>[];
    final media = <StoryMediaEvent>[];
    final completed = <int>{};
    StoryBlocker? blocker;
    var cursor = chapter.commands.isEmpty ? 0 : chapter.commands.first.index;
    for (final execution in executions) {
      if (execution.startedAtUs > inputs.atUs) break;
      final command = _commands[execution.commandIndex]!;
      cursor = command.index;
      if (command.ignoreData) {
        completed.add(command.index);
        continue;
      }
      if (!command.isKnownNativeOpcode) {
        if (inputs.executionOwnershipKnown &&
            inputs.blockingExecutionId != execution.executionId) {
          continue;
        }
        blocker = StoryBlocker(
          command.index,
          'unsupported_opcode:${command.opcode}',
        );
        break;
      }
      final kind = _intentKind(command.opcode);
      final pass = _pass(command.opcode);
      intents.add(
        StoryEffectIntent(
          kind: kind,
          pass: pass,
          executionId: execution.executionId,
          commandIndex: command.index,
          opcode: command.opcode,
          startedAtUs: execution.startedAtUs,
          durationUs: _visualDuration(command),
          parameters: command.parameters,
          resourceRefs: command.resourceRefs,
          targets: command.targets,
          payload: command.payload,
        ),
      );
      _appendMedia(command, execution.startedAtUs, media);
      if (execution.completedAtUs != null &&
          execution.completedAtUs! <= inputs.atUs) {
        completed.add(command.index);
        cursor = execution.nextCommandIndex ?? _nextIndex(command.index);
        continue;
      }
      if (execution.waitForCompletion == false) continue;
      if (inputs.executionOwnershipKnown &&
          inputs.blockingExecutionId != execution.executionId) {
        continue;
      }
      // An acknowledgement or a media observation alone cannot prove that
      // native subtitle/talk waiting rules finished. The controller records
      // actual completion after all waits and resource work have resolved.
      blocker = StoryBlocker(
        command.index,
        _requiresAcknowledgement(command.opcode)
            ? 'actual_ui_command_completion_required'
            : 'actual_command_completion_required',
      );
      break;
    }
    if (executions.isEmpty &&
        chapter.commands.isNotEmpty &&
        !inputs.executionOwnershipKnown) {
      blocker = StoryBlocker(cursor, 'command_dispatch_required');
    }
    return StorySceneState(
      sourceIdentity: chapter.sourceIdentity,
      atUs: inputs.atUs,
      cursor: cursor,
      intents: intents,
      mediaEvents: media,
      completedCommands: completed,
      blocker: blocker,
    );
  }

  int _nextIndex(int index) {
    final current = chapter.commands.indexWhere(
      (command) => command.index == index,
    );
    return current + 1 < chapter.commands.length
        ? chapter.commands[current + 1].index
        : index + 1;
  }
}

bool _requiresAcknowledgement(int opcode) =>
    const {2, 28, 29, 37, 41}.contains(opcode);

int _visualDuration(StoryDecodedCommand command) {
  if (command.opcode == 30) {
    return ((command.numericParameter(0) ?? 0).clamp(0, double.infinity) *
            1000000)
        .round();
  }
  if (command.opcode == 43) {
    final parameter = command.numericParameter(0);
    if (parameter != null && parameter > 0) {
      return (parameter * 1000000).round();
    }
  }
  if (command.opcode == 11 && command.durationUs <= 0) return 300000;
  return command.durationUs < 0 ? 0 : command.durationUs;
}

StoryIntentKind _intentKind(int opcode) {
  if (const {
    0,
    1,
    9,
    10,
    13,
    14,
    17,
    18,
    19,
    21,
    23,
    24,
    32,
    46,
    60,
    61,
    62,
    63,
    64,
    66,
    68,
    69,
  }.contains(opcode)) {
    return StoryIntentKind.character;
  }
  if (const {7, 33, 34, 47, 48, 49, 50, 51, 53, 67}.contains(opcode)) {
    return StoryIntentKind.camera;
  }
  if (const {20, 25, 57, 58}.contains(opcode)) return StoryIntentKind.stage;
  if (const {4, 5, 6, 12, 55}.contains(opcode)) return StoryIntentKind.fade;
  if (opcode == 11) return StoryIntentKind.flash;
  if (opcode == 30) return StoryIntentKind.still;
  if (opcode == 26 || opcode == 27) return StoryIntentKind.video;
  if (opcode == 44) return StoryIntentKind.frame;
  if (opcode == 54) return StoryIntentKind.effect;
  if (opcode == 43) return StoryIntentKind.volume;
  if (const {15, 16, 31, 52}.contains(opcode)) {
    return StoryIntentKind.audio;
  }
  if (const {2, 28, 35, 36, 37, 38, 39, 65}.contains(opcode)) {
    return StoryIntentKind.dialogue;
  }
  if (opcode == 40 || opcode == 41) return StoryIntentKind.choice;
  if (opcode == 45) return StoryIntentKind.timeline;
  return StoryIntentKind.control;
}

StoryPassKind _pass(int opcode) => switch (opcode) {
  26 || 27 => StoryPassKind.video,
  30 => StoryPassKind.still,
  44 => StoryPassKind.frame,
  5 || 6 || 11 => StoryPassKind.front,
  2 ||
  28 ||
  35 ||
  36 ||
  37 ||
  38 ||
  39 ||
  40 ||
  41 ||
  65 => StoryPassKind.dialogue,
  _ => StoryPassKind.world,
};

/// Shared authored Voice/SE lookahead; hosts supply resource keys and decoders.
final class StoryMediaPreparationPlan {
  StoryMediaPreparationPlan(Iterable<StoryDecodedCommand> commands) {
    final media = <StoryMediaEvent>[];
    for (final command in commands) {
      if (!command.ignoreData) {
        _appendMedia(command, 0, media, forPreparation: true);
      }
    }
    entries = List.unmodifiable(
      media.where(
        (event) =>
            !event.stop &&
            (event.kind == StoryMediaKind.voice ||
                event.kind == StoryMediaKind.sfx),
      ),
    );
  }
  static const lookahead = 4, concurrency = 2;
  late final List<StoryMediaEvent> entries;
  List<StoryMediaEvent> upcoming(
    int commandIndex,
    String Function(StoryMediaEvent) keyOf,
  ) {
    final keys = <String>{}, selected = <StoryMediaEvent>[];
    for (final event in entries) {
      if (event.commandIndex < commandIndex || !keys.add(keyOf(event)))
        continue;
      selected.add(event);
      if (selected.length == lookahead) break;
    }
    return List.unmodifiable(selected);
  }
}

void _appendMedia(
  StoryDecodedCommand command,
  int atUs,
  List<StoryMediaEvent> output, {
  bool forPreparation = false,
}) {
  if (command.opcode == 15) {
    output.add(
      StoryMediaEvent(
        kind: StoryMediaKind.bgm,
        cueId: command.bgmId,
        commandIndex: command.index,
        atUs: atUs,
        resourceRef: command.resourceRefs['bgmRef'],
        stop: (BigInt.tryParse(command.bgmId) ?? BigInt.zero) < BigInt.one,
      ),
    );
  }
  final stopSfx =
      command.parameters.isNotEmpty &&
      command.parameters[0].toLowerCase() == 'stop';
  if (command.opcode == 31 && (command.seId != '0' || stopSfx)) {
    output.add(
      StoryMediaEvent(
        kind: StoryMediaKind.sfx,
        cueId: command.seId,
        commandIndex: command.index,
        atUs: atUs,
        resourceRef: command.resourceRefs['seRef'],
        stop: stopSfx,
      ),
    );
  }
  if (const {2, 28, 52}.contains(command.opcode) ||
      (forPreparation && command.opcode == 37)) {
    for (var index = 0; index < command.voiceIds.length; index++) {
      output.add(
        StoryMediaEvent(
          kind: StoryMediaKind.voice,
          cueId: command.voiceIds[index],
          commandIndex: command.index,
          atUs: atUs,
          resourceRef: index < command.voiceRefs.length
              ? command.voiceRefs[index]
              : null,
        ),
      );
    }
  }
  if (command.opcode == 26 || command.opcode == 27) {
    output.add(
      StoryMediaEvent(
        kind: StoryMediaKind.movie,
        cueId: command.videoId,
        commandIndex: command.index,
        atUs: atUs,
        resourceRef: command.resourceRefs['videoRef'],
        stop: command.videoId == '0',
      ),
    );
  }
}

final class StoryDispatchCompletion {
  const StoryDispatchCompletion({this.nextCommandIndex});
  final int? nextCommandIndex;
}

/// Native command handlers choose their actual waiting rule. In particular,
/// FadeOut, Movie, Clip and Subtitles do not share one generic noWait rule.
final class StoryDispatchOperation {
  const StoryDispatchOperation({
    required this.completion,
    required this.waitForCompletion,
  });
  final Future<StoryDispatchCompletion> completion;
  final bool waitForCompletion;
}

final class StoryDispatchContext {
  const StoryDispatchContext({
    required this.executionId,
    required this.inputs,
    required this.isCurrent,
    this.resuming = false,
  });
  final int executionId;
  final StoryRuntimeInputs inputs;
  final bool Function() isCurrent;
  final bool resuming;
}

typedef StoryCommandDispatcher = StoryDispatchOperation Function(
  StoryDecodedCommand command,
  StoryDispatchContext context,
);

/// Drives actual native handlers, recording real clocks instead of assigning
/// synthetic durations to dialogue, resource loading or media playback.
final class StoryPlaybackController {
  StoryPlaybackController({
    required this.chapter,
    required this.inputs,
    required this.dispatcher,
    required this.driver,
  });
  final StoryChapterDocument chapter;
  final StoryRuntimeInputs Function() inputs;
  final StoryCommandDispatcher dispatcher;
  final VegaExecutionDriver driver;
  StoryTimeline? _timeline;
  var _disposed = false;
  var _lastCursor = 0;
  Completer<void>? _resume;
  StoryBlocker? failure;
  bool get playing => !_disposed && driver.playing;
  int get cursor => _disposed ? _lastCursor : driver.cursor;

  StorySceneState snapshot() {
    final observations = inputs();
    final timeline = _timeline ??= StoryTimeline(chapter, driver.history);
    return timeline.evaluateAt(observations);
  }

  void invalidateSnapshot() => _timeline = null;

  void pause() {
    if (_disposed) return;
    driver.pause();
    _resume ??= Completer<void>();
  }

  void resume() {
    if (!_disposed) driver.resume();
    final pending = _resume;
    _resume = null;
    pending?.complete();
  }

  void stop() {
    if (_disposed) return;
    driver.stop();
    resume();
  }

  void dispose() {
    if (_disposed) return;
    stop();
    _lastCursor = driver.cursor;
    _disposed = true;
    driver.dispose();
  }

  Future<void> play() async {
    if (_disposed || !driver.start()) return;
    final generation = driver.generation;
    final pending = <Future<void>>[];
    final restored = driver is VegaCheckpointExecutionDriver
        ? (driver as VegaCheckpointExecutionDriver)
              .captureCheckpoint()
              .activeExecutionIds
              .toSet()
        : <int>{};
    StoryDispatchContext contextFor(
      VegaExecutionRecord execution,
      StoryRuntimeInputs observed, {
      bool resuming = false,
    }) => StoryDispatchContext(
      executionId: execution.executionId,
      inputs: observed,
      resuming: resuming,
      isCurrent: () =>
          !_disposed &&
          generation == driver.generation &&
          inputs().sourceEpoch == observed.sourceEpoch,
    );
    void detach(
      VegaExecutionRecord execution,
      StoryDispatchOperation operation,
      int epoch,
    ) {
      pending.add(
        operation.completion
            .then((completion) {
              if (!_disposed && generation == driver.generation) {
                _complete(execution, completion, epoch);
              }
            })
            .catchError((Object error) {
              if (!_disposed && generation == driver.generation) {
                failure = StoryBlocker(
                  execution.commandIndex,
                  error.toString(),
                );
                stop();
              }
            }),
      );
    }

    try {
      // These commands already advanced the cursor before capture. Reconnect
      // their host-owned effect state without another admission or dispatch.
      for (final execution in driver.history.where(
        (row) =>
            restored.contains(row.executionId) &&
            row.waitForCompletion == false,
      )) {
        final observed = inputs();
        if (observed.sourceIdentity != chapter.sourceIdentity) {
          throw const FormatException('story_dispatch_source_mismatch');
        }
        final command = chapter.commands.singleWhere(
          (row) => row.index == execution.commandIndex,
        );
        final operation = dispatcher(
          command,
          contextFor(execution, observed, resuming: true),
        );
        if (operation.waitForCompletion) {
          throw const FormatException('story_restored_detached_admission');
        }
        detach(execution, operation, observed.sourceEpoch);
      }
      while (!_disposed &&
          playing &&
          generation == driver.generation &&
          cursor < chapter.commands.length) {
        final paused = _resume;
        if (paused != null) await paused.future;
        if (_disposed || !playing || generation != driver.generation) return;
        final observed = inputs();
        if (observed.sourceIdentity != chapter.sourceIdentity) {
          throw const FormatException('story_dispatch_source_mismatch');
        }
        final command = chapter.commands[cursor];
        final execution = driver.begin(observed.atUs);
        final id = execution.executionId;
        _timeline = null;
        if (command.ignoreData) {
          driver.admit(id, waitForCompletion: false);
          _complete(
            execution,
            const StoryDispatchCompletion(),
            observed.sourceEpoch,
          );
          continue;
        }
        if (!command.isKnownNativeOpcode) {
          throw UnsupportedError('story_opcode:${command.opcode}');
        }
        final operation = dispatcher(
          command,
          contextFor(execution, observed, resuming: restored.contains(id)),
        );
        if (restored.contains(id) &&
            operation.waitForCompletion != execution.waitForCompletion) {
          throw const FormatException('story_restored_blocking_admission');
        }
        driver.admit(id, waitForCompletion: operation.waitForCompletion);
        _timeline = null;
        if (operation.waitForCompletion) {
          final completion = await operation.completion;
          if (_disposed ||
              generation != driver.generation ||
              inputs().sourceEpoch != observed.sourceEpoch) {
            return;
          }
          _complete(execution, completion, observed.sourceEpoch);
        } else {
          detach(execution, operation, observed.sourceEpoch);
        }
      }
      if (!_disposed &&
          generation == driver.generation &&
          cursor >= chapter.commands.length) {
        await Future.wait(pending);
      }
    } catch (error) {
      if (_disposed || generation != driver.generation) return;
      failure = StoryBlocker(
        cursor < chapter.commands.length
            ? chapter.commands[cursor].index
            : cursor,
        error.toString(),
      );
      stop();
      rethrow;
    } finally {
      if (!_disposed && generation == driver.generation) driver.finish();
    }
  }

  void _complete(
    StoryCommandExecution execution,
    StoryDispatchCompletion completion,
    int sourceEpoch,
  ) {
    if (_disposed) return;
    final observed = inputs();
    if (observed.sourceIdentity != chapter.sourceIdentity ||
        observed.sourceEpoch != sourceEpoch) {
      return;
    }
    driver.complete(
      execution.executionId,
      observed.atUs,
      nextCommandIndex: completion.nextCommandIndex,
    );
    _timeline = null;
  }
}
