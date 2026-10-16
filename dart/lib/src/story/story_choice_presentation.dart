import 'dart:async';

import 'story_command_decoder.dart';
import 'story_text_presentation.dart';

int _group(String? source) {
  final parsed = int.tryParse((source ?? '').trim());
  return parsed != null && parsed >= -2147483648 && parsed <= 2147483647
      ? parsed
      : 0;
}

final class StoryChoiceData {
  const StoryChoiceData({
    required this.group,
    required this.value,
    required this.commandIndex,
    required this.textId,
    required this.nextKey,
  });
  final int group, value, commandIndex;
  final String textId, nextKey;
}

final class StoryChoiceSelection {
  const StoryChoiceSelection(this.choice, this.targetCommandIndex);
  final StoryChoiceData choice;

  /// An unknown source key preserves the interpreter's normal fall-through.
  final int? targetCommandIndex;
}

final class StoryChoicePresentationSnapshot {
  StoryChoicePresentationSnapshot._(
    this.choices,
    this._keys,
    this.sourceEpoch,
    this.selectedValue,
    this.closed,
  );
  final List<StoryChoiceData> choices;
  final Map<String, int> _keys;
  final int sourceEpoch;
  final int? selectedValue;
  final bool closed;
}

final class StoryChoiceCatalog {
  StoryChoiceCatalog._(this.groups, this.keys);
  final Map<int, List<StoryChoiceData>> groups;
  final Map<String, int> keys;
  factory StoryChoiceCatalog.fromChapter(StoryChapterDocument chapter) {
    final groups = <int, List<StoryChoiceData>>{}, keys = <String, int>{};
    for (final command in chapter.commands) {
      final raw = command.payload['raw'];
      final key = command.payload['key'] ?? (raw is Map ? raw['_key'] : null);
      if (key is String && key.isNotEmpty) {
        keys.putIfAbsent(key, () => command.index);
      }
      if (command.opcode != 40 || command.ignoreData) continue;
      final group = _group(command.parameter(0));
      final choices = groups.putIfAbsent(group, () => []);
      final textId = command.payload['advTextId'];
      choices.add(
        StoryChoiceData(
          group: group,
          value: choices.length,
          commandIndex: command.index,
          textId: textId is String ? textId : '',
          nextKey: command.parameter(1) ?? '',
        ),
      );
    }
    return StoryChoiceCatalog._(
      Map.unmodifiable(
        groups.map((key, value) => MapEntry(key, List.unmodifiable(value))),
      ),
      Map.unmodifiable(keys),
    );
  }

  StoryChoicePresentation open(int group, int sourceEpoch) =>
      StoryChoicePresentation._(groups[group] ?? const [], keys, sourceEpoch);
}

/// Selection comes from the real native choices UI. Random-choice timing and
/// its actual RNG remain host inputs, never a fabricated acknowledgement.
final class StoryChoicePresentation {
  StoryChoicePresentation._(this.choices, this._keys, this.sourceEpoch) {
    unawaited(
      _selected.future.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
    unawaited(
      _finished.future.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
  }
  final List<StoryChoiceData> choices;
  final Map<String, int> _keys;
  final int sourceEpoch;
  final _selected = Completer<StoryChoiceSelection>();
  final _finished = Completer<StoryChoiceSelection>();
  StoryChoiceSelection? _selection;
  bool _closed = false;
  bool get nextButtonLocked => !_closed;
  Future<StoryChoiceSelection> get selected => _selected.future;
  Future<StoryChoiceSelection> get finished => _finished.future;

  StoryChoicePresentationSnapshot snapshot() =>
      StoryChoicePresentationSnapshot._(
        List.unmodifiable(choices),
        Map.unmodifiable(_keys),
        sourceEpoch,
        _selection?.choice.value,
        _closed,
      );

  Map<String, Object?> snapshotData() => {
    'version': 1,
    'choices': [
      for (final value in choices)
        {
          'group': value.group,
          'value': value.value,
          'commandIndex': value.commandIndex,
          'textId': value.textId,
          'nextKey': value.nextKey,
        },
    ],
    'keys': Map<String, int>.of(_keys),
    'selectedValue': _selection?.choice.value,
    'closed': _closed,
  };

  factory StoryChoicePresentation.fromData(
    Map data, {
    required int sourceEpoch,
  }) {
    if (data['version'] != 1)
      throw const FormatException('choice_data_version');
    final choices = [
      for (final raw in data['choices'] as List)
        StoryChoiceData(
          group: (raw as Map)['group'] as int,
          value: raw['value'] as int,
          commandIndex: raw['commandIndex'] as int,
          textId: raw['textId'] as String,
          nextKey: raw['nextKey'] as String,
        ),
    ];
    return StoryChoicePresentation.fromSnapshot(
      StoryChoicePresentationSnapshot._(
        List.unmodifiable(choices),
        Map<String, int>.unmodifiable(
          Map<String, int>.from(data['keys'] as Map),
        ),
        sourceEpoch,
        data['selectedValue'] as int?,
        data['closed'] as bool,
      ),
    );
  }

  factory StoryChoicePresentation.fromSnapshot(
    StoryChoicePresentationSnapshot snapshot,
  ) {
    final value = StoryChoicePresentation._(
      snapshot.choices,
      snapshot._keys,
      snapshot.sourceEpoch,
    );
    if (snapshot.selectedValue != null)
      value.select(snapshot.selectedValue!, snapshot.sourceEpoch);
    if (snapshot.closed) {
      if (snapshot.selectedValue != null) {
        value.actualHideCompleted(snapshot.sourceEpoch);
      } else {
        value.cancel('restored_closed');
      }
    }
    return value;
  }

  bool select(int actualValue, int epoch) {
    if (_closed ||
        epoch != sourceEpoch ||
        _selected.isCompleted ||
        actualValue < 0 ||
        actualValue >= choices.length) {
      return false;
    }
    final choice = choices[actualValue];
    _selection = StoryChoiceSelection(choice, _keys[choice.nextKey]);
    _selected.complete(_selection!);
    return true;
  }

  bool actualHideCompleted(int epoch) {
    if (_closed || epoch != sourceEpoch || _selection == null) return false;
    _closed = true;
    _finished.complete(_selection!);
    return true;
  }

  void cancel(String reason) {
    _closed = true;
    if (!_selected.isCompleted) {
      _selected.completeError(StoryPresentationCancelled(reason));
    }
    if (!_finished.isCompleted) {
      _finished.completeError(StoryPresentationCancelled(reason));
    }
  }
}
