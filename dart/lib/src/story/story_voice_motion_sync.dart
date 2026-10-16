import 'package:vega_protocol/vega_protocol.dart';
import 'package:vega_plugin_cubism/motion_sync_profile.dart';

/// The Source model uses its first authored MotionSync setting.
MotionSyncProfile? storyMotionSyncProfileFromCatalog(Map catalog) {
  final runtime = catalog['runtime'] as Map?;
  final motionSync = runtime?['motionSync'] as Map?;
  final settings = motionSync?['settings'] as List?;
  if (settings == null || settings.isEmpty) return null;
  return MotionSyncProfile.fromSetting(
    (settings.first as Map).cast<String, Object?>(),
  );
}

/// Resolves original parallel voice/target indices without compacting empty
/// entries. A saved cue carries its originating command index; legacy cues
/// bind only when the immutable voice identity selects one source command.
final class StoryVoiceSourceBindings {
  StoryVoiceSourceBindings(Iterable<StoryDecodedCommand> commands)
    : _commands = {for (final command in commands) command.index: command};

  final Map<int, StoryDecodedCommand> _commands;

  List<String> targets({
    required int? commandIndex,
    required String voiceId,
    required String resourceRef,
    required Iterable<String> showingTargets,
    required double storySpeed,
    required bool shortcut,
  }) {
    // Matches the existing Web adapter's CRI activation policy.
    if (shortcut || (storySpeed - 1).abs() >= .001) return const [];
    bool matches(StoryDecodedCommand command, int index) =>
        command.voiceIds[index] == voiceId &&
        (index >= command.voiceRefs.length ||
            command.voiceRefs[index] == resourceRef);
    final command = commandIndex == null
        ? _commands.values
              .where(
                (command) => [
                  for (var i = 0; i < command.voiceIds.length; i++)
                    matches(command, i),
                ].contains(true),
              )
              .singleOrNull
        : _commands[commandIndex];
    if (command == null ||
        !const {2, 52}.contains(command.opcode) ||
        command.payload['ignoreLipSync'] == true) {
      return const [];
    }
    final indices = [
      for (var i = 0; i < command.voiceIds.length; i++)
        if (matches(command, i)) i,
    ];
    if (indices.isEmpty) return const [];
    if (command.opcode == 2 &&
        command.parameter(0)?.trim().toLowerCase() == 'everyonelipsync') {
      return indices.contains(0) ? List.unmodifiable(showingTargets) : const [];
    }
    final configured = command.payload['lipSyncTargets'] as List?;
    final authored =
        configured != null && configured.any((value) => value != '')
        ? configured.cast<String>()
        : command.targets;
    return List.unmodifiable({
      for (final index in indices)
        if (index < authored.length && authored[index].isNotEmpty)
          authored[index],
    });
  }
}
