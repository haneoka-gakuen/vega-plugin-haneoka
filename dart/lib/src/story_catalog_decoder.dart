import 'package:vega_protocol/vega_protocol.dart';

/// Master aliases can share one cue while retaining separate IDs and editorial
/// notes. Playback fields, the resolved stream and its timing remain identical.
bool haneokaStoryMediaBindingsEqual(Map a, Map b, String idField) {
  Map binding(Map record) {
    final result = Map.of(record)..remove(idField);
    if (record['raw'] case final Map raw) {
      result['raw'] = Map.of(raw)
        ..remove('_id')
        ..remove('_note');
    }
    return result;
  }

  bool same(Object? x, Object? y) {
    if (x is Map && y is Map) {
      return x.length == y.length &&
          x.keys.every((key) => y.containsKey(key) && same(x[key], y[key]));
    }
    if (x is List && y is List) {
      return x.length == y.length &&
          Iterable.generate(x.length).every((i) => same(x[i], y[i]));
    }
    return x == y;
  }

  return same(binding(a), binding(b));
}

/// Haneoka ADV opcode names supplied by this format profile.
const haneokaStoryOpcodeNames = <int, String>{
  0: 'In',
  1: 'Out',
  2: 'Talk',
  3: 'Delay',
  4: 'Shake',
  5: 'FadeOut',
  6: 'FadeIn',
  7: 'Focus',
  9: 'Forward',
  10: 'Back',
  11: 'Flash',
  12: 'Brightness',
  13: 'MoveToRight',
  14: 'MoveToLeft',
  15: 'Bgm',
  16: 'SoundVolume',
  17: 'Expression',
  18: 'Pause',
  19: 'Resume',
  20: 'Location',
  21: 'Motion',
  23: 'Character',
  24: 'Costume',
  25: 'Stage',
  26: 'Movie',
  27: 'Clip',
  28: 'Subtitles',
  29: 'Wait',
  30: 'Still',
  31: 'Se',
  32: 'Angle',
  33: 'Pan',
  34: 'Tilt',
  35: 'TalkWindow',
  36: 'ChatWindow',
  37: 'ChatTalk',
  38: 'ChatStamp',
  39: 'ChatRead',
  40: 'ChoiceSet',
  41: 'ChoiceShow',
  42: 'GoTo',
  43: 'PostEffect',
  44: 'Frame',
  45: 'Timeline',
  46: 'Look',
  47: 'Pedestal',
  48: 'Track',
  49: 'DoF',
  50: 'Role',
  51: 'CameraShake',
  52: 'Voice',
  53: 'Zoom',
  54: 'Effect',
  55: 'Alpha',
  56: 'ForceAuto',
  57: 'StageEnv',
  58: 'RimLight',
  59: 'CancelDelay',
  60: 'MoveToUp',
  61: 'MoveToDown',
  62: 'MoveToForward',
  63: 'MoveToBack',
  64: 'MoveToDirection',
  65: 'ChatTyping',
  66: 'LookTarget',
  67: 'PanV2',
  68: 'MotionLoop',
  69: 'EyeBlink',
};

int _integer(Object? value, String field) {
  if (value is! int) throw FormatException('story_integer:$field');
  return value;
}

double _number(Object? value, String field) {
  if (value is! num || !value.toDouble().isFinite) {
    throw FormatException('story_number:$field');
  }
  return value.toDouble();
}

String _string(Object? value, String field) {
  if (value is! String) throw FormatException('story_string:$field');
  return value;
}

String _identity(Object? value, String field) {
  if (value is int) return value.toString();
  if (value is String && RegExp(r'^-?\d+$').hasMatch(value)) return value;
  throw FormatException('story_native_identity:$field');
}

List<String> _strings(Object? value, String field) {
  if (value == null) return const [];
  if (value is! List) throw FormatException('story_string_list:$field');
  return List.unmodifiable(value.map((item) => _string(item, field)));
}

Object? _freeze(Object? value) => switch (value) {
  Map() => Map<String, Object?>.unmodifiable(
    value.map((key, value) {
      if (key is! String) throw const FormatException('story_record_key');
      return MapEntry(key, _freeze(value));
    }),
  ),
  List() => List<Object?>.unmodifiable(value.map(_freeze)),
  _ => value,
};

void _validateSource(StorySourceIdentity source) {
  if (!RegExp(r'^r-[a-f0-9]{20}$').hasMatch(source.revision) ||
      !RegExp(r'^[a-f0-9]{64}$').hasMatch(source.contentIdentity) ||
      source.namespace.isEmpty ||
      source.resourceScope.isEmpty ||
      source.document.isEmpty) {
    throw const FormatException('story_source_identity');
  }
}

/// Decodes the selected Haneoka catalogue entity into portable commands.
abstract final class HaneokaStoryCatalogDecoder {
  static StoryChapterDocument decode(
    Map<String, Object?> entity,
    StorySourceIdentity sourceIdentity,
  ) {
    _validateSource(sourceIdentity);
    final id = entity['storyId'];
    if (id != sourceIdentity.document ||
        entity['commands'] is! List ||
        entity['assets'] is! Map) {
      throw const FormatException('story_catalog_entity_identity');
    }
    final commands = <StoryDecodedCommand>[];
    final identities = <int>{};
    for (final item in entity['commands'] as List) {
      if (item is! Map) throw const FormatException('story_command_record');
      final record = Map<String, Object?>.from(item);
      final index = _integer(record['index'], 'index');
      if (!identities.add(index) || index < 0) {
        throw const FormatException('story_command_index');
      }
      final refs = <String, String>{};
      for (final field in [
        'backgroundRef',
        'stillRef',
        'frameRef',
        'effectRef',
        'postEffectRef',
        'live2dKey',
        'videoRef',
        'bgmRef',
        'seRef',
      ]) {
        if (record[field] != null) refs[field] = _string(record[field], field);
      }
      final targets = <String>[];
      final targetRecords = record['targets'];
      if (targetRecords is List) {
        for (final target in targetRecords) {
          if (target is! Map || target['target'] is! String) {
            throw const FormatException('story_command_target');
          }
          targets.add(target['target'] as String);
        }
      } else if (record['targetName'] is String &&
          (record['targetName'] as String).isNotEmpty) {
        targets.add(record['targetName'] as String);
      }
      final voices = record['voiceIds'];
      if (voices != null && voices is! List) {
        throw const FormatException('story_voice_ids');
      }
      final noWait = record['noWait'], ignore = record['ignoreData'];
      if (noWait is! bool || ignore is! bool) {
        throw const FormatException('story_command_flags');
      }
      commands.add(
        StoryDecodedCommand(
          index: index,
          opcode: _integer(record['command'], 'command'),
          opcodeName:
              haneokaStoryOpcodeNames[_integer(record['command'], 'command')],
          durationUs: (_number(record['duration'], 'duration') * 1000000)
              .round(),
          delayUs: (_number(record['delaySeconds'], 'delaySeconds') * 1000000)
              .round(),
          noWait: noWait,
          ignoreData: ignore,
          parameters: _strings(record['params'], 'params'),
          targets: List.unmodifiable(targets),
          resourceRefs: Map.unmodifiable(refs),
          voiceIds: List.unmodifiable(
            (voices as List? ?? const []).map((v) => _identity(v, 'voiceId')),
          ),
          voiceRefs: _strings(record['voiceRefs'], 'voiceRefs'),
          bgmId: _identity(record['bgmId'], 'bgmId'),
          seId: _identity(record['seId'], 'seId'),
          videoId: _identity(record['videoId'], 'videoId'),
          payload: _freeze(record) as Map<String, Object?>,
        ),
      );
    }
    final assets = _freeze(entity['assets']) as Map<String, Object?>;
    final metadata = Map<String, Object?>.from(entity)
      ..remove('commands')
      ..remove('assets');
    return StoryChapterDocument(
      sourceIdentity: sourceIdentity,
      commands: commands,
      assets: assets,
      document: Map.unmodifiable({
        ...(_freeze(metadata) as Map<String, Object?>),
        'assets': assets,
        'commands': List.unmodifiable(
          commands.map((command) => command.payload),
        ),
      }),
    );
  }
}
