import 'story_character_controls.dart';
import 'story_character_order.dart';
import 'story_character_placement.dart';
import 'story_command_decoder.dart';
import 'story_presentation_timing.dart';

/// Numeric presentation state shared by the Source controller and its host.
/// Resources, model evaluation and accepted scene time belong to the caller.
class StoryCharacterPresentationState {
  int slot = 0, fadeStart = 0, fadeDuration = 0;
  double opacity = 0, from = 0, to = 0;
  double brightness = 1, sortingDepth = 0;
}

sealed class StoryCharacterPresentationEffect {
  const StoryCharacterPresentationEffect();
}

final class StoryCharacterVisibility extends StoryCharacterPresentationEffect {
  const StoryCharacterVisibility(this.visible);
  final bool visible;
}

final class StoryCharacterAngleLookReset
    extends StoryCharacterPresentationEffect {
  const StoryCharacterAngleLookReset();
}

final class StoryCharacterDepthSort extends StoryCharacterPresentationEffect {
  const StoryCharacterDepthSort();
}

final class StoryCharacterSourcePause extends StoryCharacterPresentationEffect {
  const StoryCharacterSourcePause(this.paused);
  final bool paused;
}

final class StoryCharacterEyeBlink extends StoryCharacterPresentationEffect {
  const StoryCharacterEyeBlink(this.stopped, {this.transitionSeconds = 0});
  final bool stopped;
  final double transitionSeconds;
}

typedef StoryCharacterPresentationSink<T> = void Function(
  T actor,
  StoryCharacterPresentationEffect effect,
);

/// Synchronous Adv character presence, retained controls and appearance fades.
/// Effects are applied synchronously to retain the original command order.
final class StoryCharacterPresentation {
  final placements = StoryCharacterPlacement();
  final controls = StoryCharacterControls();
  final order = StoryCharacterOrder();

  void show<T extends StoryCharacterPresentationState>(
    StoryDecodedCommand command, {
    required Map<String, T> actors,
    required bool visible,
    required int atUs,
    required StoryCharacterPresentationSink<T> apply,
    StoryPresentationTiming timing = const StoryPresentationTiming(),
  }) {
    final targets = command.targets.isEmpty
        ? [command.payload['targetName'] as String]
        : command.targets;
    for (final target in targets) {
      final actor = actors[target];
      if (actor == null) throw StateError('story_actor_not_loaded:$target');
      if (visible) {
        final position = command.payload['positionType'] as int;
        if (position > 0) {
          if (position.isEven || position > 9) {
            throw ArgumentError('story_character_position:$position');
          }
          actor.slot = (position - 1) ~/ 2;
        }
        apply(actor, const StoryCharacterVisibility(true));
        if (controls.eyeBlinkStopped(target)) {
          apply(actor, const StoryCharacterEyeBlink(true));
        }
        placements.place(target, position);
        apply(actor, const StoryCharacterAngleLookReset());
        apply(actor, const StoryCharacterDepthSort());
      }
      actor.fadeStart = atUs;
      actor.fadeDuration = timing.durationUs(command.durationUs);
      actor.from = actor.opacity;
      actor.to = visible ? 1 : 0;
      if (actor.fadeDuration == 0) {
        actor.opacity = actor.to;
        if (!visible) apply(actor, const StoryCharacterVisibility(false));
      }
    }
  }

  void reorder(StoryDecodedCommand command) => order.move(
    command.payload['positionType'] as int,
    forward: command.opcode == 9,
  );

  void characterControl<T extends StoryCharacterPresentationState>(
    StoryDecodedCommand command, {
    required Map<String, T> actors,
    required bool shortcut,
    required StoryCharacterPresentationSink<T> apply,
  }) {
    for (final target in command.targets) {
      final actor = actors[target];
      if (command.opcode == 69) {
        final stopped = controls.applyEyeBlink(target, command.parameter(0));
        if (stopped != null && actor != null) {
          apply(
            actor,
            StoryCharacterEyeBlink(
              stopped,
              transitionSeconds: shortcut
                  ? 0
                  : StoryCharacterControls.eyeBlinkTransitionSeconds,
            ),
          );
        }
      } else if (actor != null) {
        apply(actor, StoryCharacterSourcePause(command.opcode == 18));
      }
    }
  }

  void advanceFade<T extends StoryCharacterPresentationState>(
    T actor, {
    required bool visible,
    required double atUs,
    required StoryCharacterPresentationSink<T> apply,
  }) {
    if (!visible || actor.fadeDuration <= 0) return;
    final t = ((atUs - actor.fadeStart) / actor.fadeDuration).clamp(0.0, 1.0);
    actor.opacity = actor.from + (actor.to - actor.from) * t;
    if (t >= 1 && actor.to == 0) {
      apply(actor, const StoryCharacterVisibility(false));
    }
  }
}
