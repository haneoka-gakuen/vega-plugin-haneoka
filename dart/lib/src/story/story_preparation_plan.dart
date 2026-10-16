import 'package:vega_protocol/vega_protocol.dart';

import 'story_frame_source.dart';

/// Registrations before the first character/text/movie presentation are
/// preparation candidates. Later costumes stay lazy.
List<StoryDecodedCommand> storyInitialCharacterLoads(
  Iterable<StoryDecodedCommand> commands,
) {
  final result = <StoryDecodedCommand>[];
  final identities = <(String, int, String)>{};
  for (final command in commands) {
    if (command.ignoreData) continue;
    if (const {0, 2, 26, 27, 28, 29, 30, 37, 41}.contains(command.opcode)) {
      break;
    }
    if (command.opcode != 23) continue;
    final identity = (
      command.payload['targetName'] as String,
      command.payload['targetAssetIndex'] as int? ?? 0,
      command.payload['live2dKey'] as String,
    );
    if (identities.add(identity)) result.add(command);
  }
  return List.unmodifiable(result);
}

final class StorySeekPreparationPlan {
  const StorySeekPreparationPlan(
    this.commandLimit,
    this.checkpointPositions,
    this.blockedReason,
  );
  final int commandLimit;
  final Set<int> checkpointPositions;
  final String? blockedReason;
}

/// A fresh chapter has no selected Choice path. Prepare its reachable prefix
/// and distribute the bounded snapshots across actual Talk boundaries.
StorySeekPreparationPlan storySeekPreparationPlan(
  List<StoryDecodedCommand> commands, {
  required int checkpointBudget,
  required Set<int> knownChoices,
  String? Function(StoryDecodedCommand command)? backendBarrier,
}) {
  if (checkpointBudget < 3) throw ArgumentError.value(checkpointBudget);
  var limit = commands.length;
  String? blockedReason;
  for (var i = 0; i < commands.length; i++) {
    final command = commands[i];
    if (!command.ignoreData &&
        command.opcode == 41 &&
        !knownChoices.contains(command.index)) {
      limit = i;
      blockedReason = 'unresolved-choice';
      break;
    }
    if (!command.ignoreData &&
        (blockedReason = backendBarrier?.call(command)) != null) {
      limit = i;
      break;
    }
  }
  final candidates = <int>[
    0,
    for (var i = 0; i < limit; i++)
      if (const {2, 28, 29, 52}.contains(commands[i].opcode)) i + 1,
    if (limit > 0) limit,
  ].toSet().toList()..sort();
  final selected = candidates.length <= checkpointBudget
      ? candidates.toSet()
      : {
          for (var i = 0; i < checkpointBudget; i++)
            candidates[(i * (candidates.length - 1) / (checkpointBudget - 1))
                .floor()],
        };
  return StorySeekPreparationPlan(
    limit,
    Set.unmodifiable(selected),
    blockedReason,
  );
}

/// A chapter-wide resource closure, including commands behind future choices
/// and seeks. Unsupported references keep their command-time boundary.
final class StoryFramePreparationPlan {
  StoryFramePreparationPlan.forChapter(
    StoryChapterDocument chapter,
    Map<String, StoryFrameSource> frames,
  ) : sourceIdentity = chapter.sourceIdentity {
    final requested = <String>{},
        missing = <String>{},
        unsupported = <String>{};
    final unresolved = <int>{};
    final textures = <String, String>{}, pathHashes = <String, String>{};
    final straight = <String, String>{};
    void include(String path, String hash) {
      final previous = pathHashes[path];
      if (previous != null && previous != hash) {
        throw FormatException('story_frame_texture_alias:$path');
      }
      pathHashes[path] = hash;
      textures.putIfAbsent(hash, () => path);
    }

    for (final command in chapter.commands) {
      if (command.opcode != 44 || command.ignoreData) continue;
      final ref = command.resourceRefs['frameRef'];
      if (ref == null || ref.isEmpty) {
        unresolved.add(command.index);
        continue;
      }
      if (!requested.add(ref)) continue;
      final source = frames[ref];
      if (source == null) {
        missing.add(ref);
        continue;
      }
      if (source.unsupported.isNotEmpty) {
        unsupported.add(ref);
        continue;
      }
      for (final node in source.nodes) {
        final image = node.image, texture = node.image?.texture;
        if (texture == null) continue;
        final hash = image!.textureHash;
        if (hash == null)
          throw FormatException('story_frame_texture_hash_missing:$ref');
        include(texture, hash);
      }
      final particles = source.particleSource;
      if (particles != null) {
        for (final entry in particles.texturePaths.entries) {
          include(entry.value, particles.textureHashes[entry.key]!);
          straight[entry.key] = entry.value;
        }
      }
    }
    frameRefs = Set.unmodifiable(requested);
    missingRefs = Set.unmodifiable(missing);
    unsupportedRefs = Set.unmodifiable(unsupported);
    unresolvedCommands = Set.unmodifiable(unresolved);
    texturesByHash = Map.unmodifiable(textures);
    straightTexturePaths = Map.unmodifiable(straight);
  }
  final StorySourceIdentity sourceIdentity;
  late final Set<String> frameRefs, missingRefs, unsupportedRefs;
  late final Set<int> unresolvedCommands;

  /// Expected SHA256 to one pinned source path; identical resources fetch once.
  late final Map<String, String> texturesByHash;

  /// Raw PNG channels for materials whose Source blend consumes straight alpha.
  late final Map<String, String> straightTexturePaths;
}
