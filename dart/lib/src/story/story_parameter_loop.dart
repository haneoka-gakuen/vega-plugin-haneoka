import 'story_command_decoder.dart';

/// Adv MotionLoop uses parameter1 Stop independently of the repeated clip name.
({bool stop, String motionName, double fade}) storyParameterLoopRequest(
  StoryDecodedCommand command, {
  required bool shortcut,
}) {
  if (command.opcode != 68) {
    throw ArgumentError('story_parameter_loop_opcode:${command.opcode}');
  }
  return (
    stop: command.parameter(0)?.toLowerCase() == 'stop',
    motionName: command.payload['motionName'] as String? ?? '',
    fade: shortcut
        ? 0
        : (command.payload['motionFadeIn'] as num?)?.toDouble() ?? 0,
  );
}
