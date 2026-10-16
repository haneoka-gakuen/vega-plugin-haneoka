import 'dart:typed_data';

import 'story_command_decoder.dart';

final class StoryCharacterMovement {
  const StoryCharacterMovement(this.offset, {required this.sortDepth});
  final Float32List offset;
  final bool sortDepth;
  static const ease = 6;
}

StoryCharacterMovement storyCharacterMovement(StoryDecodedCommand command) {
  final value = command.numericParameter(0) ?? 0;
  final offset = switch (command.opcode) {
    13 => [value, 0.0, 0.0],
    14 => [-value, 0.0, 0.0],
    60 => [0.0, value, 0.0],
    61 => [0.0, -value, 0.0],
    62 => [0.0, 0.0, -value],
    63 => [0.0, 0.0, value],
    64 => [
      value,
      command.numericParameter(1) ?? 0,
      command.numericParameter(2) ?? 0,
    ],
    _ => throw ArgumentError('story_character_movement:${command.opcode}'),
  };
  return StoryCharacterMovement(
    Float32List.fromList(offset),
    sortDepth: command.opcode == 62 || command.opcode == 63,
  );
}
