import 'story_scene_state.dart';
import 'story_text_presentation.dart';

enum StoryChatEntryKind { text, stamp }

enum StoryChatWindowAction { show, configure, close }

final class StoryChatEntry {
  StoryChatEntry({
    required this.sequence,
    required this.commandIndex,
    required this.kind,
    required this.senderId,
    required this.name,
    required this.text,
    required this.stampAsset,
    required List<String> voiceIds,
    required this.shouldAddLog,
  }) : voiceIds = List.unmodifiable(voiceIds);
  final int sequence, commandIndex;
  final StoryChatEntryKind kind;
  final String senderId, name, text, stampAsset;
  final List<String> voiceIds;
  final bool shouldAddLog;
  int? readCount;
  bool logged = false;

  Map<String, Object?> toJson() => {
    'sequence': sequence,
    'commandIndex': commandIndex,
    'kind': kind.name,
    'senderId': senderId,
    'name': name,
    'text': text,
    'stampAsset': stampAsset,
    'voiceIds': voiceIds,
    'shouldAddLog': shouldAddLog,
    'readCount': readCount,
    'logged': logged,
  };

  factory StoryChatEntry.fromJson(Map saved) {
    final entry = StoryChatEntry(
      sequence: saved['sequence'] as int,
      commandIndex: saved['commandIndex'] as int,
      kind: StoryChatEntryKind.values.byName(saved['kind'] as String),
      senderId: saved['senderId'] as String,
      name: saved['name'] as String,
      text: saved['text'] as String,
      stampAsset: saved['stampAsset'] as String,
      voiceIds: (saved['voiceIds'] as List).cast<String>(),
      shouldAddLog: saved['shouldAddLog'] as bool,
    );
    entry.readCount = saved['readCount'] as int?;
    entry.logged = saved['logged'] as bool;
    if (entry.sequence < 0 ||
        entry.commandIndex < 0 ||
        (entry.readCount != null && entry.readCount! < 0)) {
      throw const FormatException('story_chat_entry_snapshot');
    }
    return entry;
  }
}

final class _ReadApplication {
  int current = 0, appliedEntries = 0;
}

final class StoryChatMemory {
  final _entries = <StoryChatEntry>[];
  final _reads = <String, _ReadApplication>{};
  List<StoryChatEntry> get entries => List.unmodifiable(_entries);
  void add(StoryChatEntry entry, int readCount) {
    _entries.add(entry);
    if (readCount > 0) applyRead(entry.senderId, readCount);
  }

  void applyRead(String senderId, int readCount) {
    if ((int.tryParse(senderId) ?? 0) <= 0 || readCount <= 0) return;
    final previous = _reads.putIfAbsent(senderId, _ReadApplication.new);
    var count = 0;
    for (final entry in _entries) {
      if (entry.senderId != senderId) continue;
      final base =
          entry.readCount ??
          (count < previous.appliedEntries ? previous.current : 0);
      entry.readCount = base > readCount ? base : readCount;
      count++;
    }
    previous.current = readCount;
    previous.appliedEntries = count;
  }
}

final class StoryChatWindowRequest {
  StoryChatWindowRequest({
    required this.chatId,
    required this.windowInstanceKey,
    required this.memoryId,
    required this.mode,
    required this.actualWindowActive,
    required this.actualWindowChanged,
  }) {
    if ((int.tryParse(chatId) ?? 0) <= 0 ||
        windowInstanceKey.isEmpty ||
        (memoryId != null && memoryId! <= 0) ||
        mode < 0 ||
        mode > 2) {
      throw const FormatException('story_chat_window_request');
    }
  }
  final String chatId, windowInstanceKey;
  final int? memoryId;
  final int mode;
  final bool actualWindowActive, actualWindowChanged;
}

final class StoryChatWindowChange {
  const StoryChatWindowChange({
    required this.action,
    required this.restoreEntries,
    required this.pendingLogs,
    required this.lockScreenOnly,
    required this.skipFinalWait,
    required this.replaceVisibleEntries,
  });
  final StoryChatWindowAction action;
  final List<StoryChatEntry> restoreEntries, pendingLogs;
  final bool lockScreenOnly, skipFinalWait, replaceVisibleEntries;
}

final class StoryChatMutation {
  const StoryChatMutation({
    required this.entry,
    required this.visible,
    required this.applyToView,
    required this.isOther,
    required this.pendingLogs,
  });
  final StoryChatEntry entry;
  final bool visible, applyToView, isOther;
  final List<StoryChatEntry> pendingLogs;
}

/// Actual UI visibility is observed by the host; transitions and SEs stay in
/// the host. This model stores only source-owned chat state and log identity.
final class StoryChatPresentationController {
  StoryChatPresentationController({
    required this.sourceIdentity,
    required this.sourceEpoch,
  });
  final StorySourceIdentity sourceIdentity;
  final int sourceEpoch;
  final _memories = <int, StoryChatMemory>{};
  String? currentChatId, windowInstanceKey;
  int? memoryId;
  int mode = 0;
  bool visible = false, _closed = false;
  int _sequence = 0;

  void _requireCurrent(int epoch) {
    if (_closed || epoch != sourceEpoch) {
      throw const StoryPresentationCancelled('chat_source_epoch');
    }
  }

  void observeVisibility(
    int epoch,
    String actualWindowKey,
    bool actualVisible,
  ) {
    _requireCurrent(epoch);
    if (actualWindowKey != windowInstanceKey) return;
    visible = actualVisible;
  }

  bool isMemoryVisible(int id) => visible && memoryId == id;
  int? resolveMemoryId(int? requested) => requested != null && requested > 0
      ? requested
      : visible
      ? memoryId
      : null;

  StoryChatWindowChange selectWindow(
    int epoch,
    StoryChatWindowRequest request,
  ) {
    _requireCurrent(epoch);
    final same =
        !request.actualWindowChanged &&
        currentChatId == request.chatId &&
        memoryId == request.memoryId;
    if (request.actualWindowActive && same && mode == request.mode) {
      mode = 0;
      return const StoryChatWindowChange(
        action: StoryChatWindowAction.close,
        restoreEntries: [],
        pendingLogs: [],
        lockScreenOnly: false,
        skipFinalWait: true,
        replaceVisibleEntries:false,
      );
    }
    final restore =
        request.actualWindowChanged || !same || !request.actualWindowActive;
    currentChatId = request.chatId;
    windowInstanceKey = request.windowInstanceKey;
    memoryId = request.memoryId;
    mode = request.mode;
    final memory = memoryId == null ? null : _memories[memoryId];
    final entries = memory?.entries ?? const <StoryChatEntry>[];
    return StoryChatWindowChange(
      action: !request.actualWindowActive || request.actualWindowChanged
          ? StoryChatWindowAction.show
          : StoryChatWindowAction.configure,
      restoreEntries: restore ? entries : const [],
      pendingLogs: List.unmodifiable(
        entries.where((e) => e.shouldAddLog && !e.logged),
      ),
      lockScreenOnly: mode == 2,
      skipFinalWait: false,
      replaceVisibleEntries:restore,
    );
  }

  StoryChatMutation append({
    required int epoch,
    required int commandIndex,
    required StoryChatEntryKind kind,
    required String senderId,
    required String name,
    required String text,
    required String stampAsset,
    required List<String> voiceIds,
    required int readCount,
    required int? requestedMemoryId,
    required bool skipLog,
  }) {
    _requireCurrent(epoch);
    final entry = StoryChatEntry(
      sequence: _sequence++,
      commandIndex: commandIndex,
      kind: kind,
      senderId: senderId,
      name: name,
      text: text,
      stampAsset: stampAsset,
      voiceIds: voiceIds,
      shouldAddLog: !skipLog,
    );
    final id = resolveMemoryId(requestedMemoryId);
    if (id != null) {
      _memories.putIfAbsent(id, StoryChatMemory.new).add(entry, readCount);
    }
    final applyToView =
        currentChatId != null && (id == null || isMemoryVisible(id));
    if (id == null) entry.readCount = readCount;
    return StoryChatMutation(
      entry: entry,
      visible: applyToView && visible,
      applyToView: applyToView,
      isOther: senderId != currentChatId,
      pendingLogs: applyToView && entry.shouldAddLog ? [entry] : const [],
    );
  }

  void markLogAdded(int epoch, StoryChatEntry entry) {
    _requireCurrent(epoch);
    entry.logged = true;
  }

  void applyRead(
    int epoch,
    String senderId,
    int count,
    int? requestedMemoryId,
  ) {
    _requireCurrent(epoch);
    final id = resolveMemoryId(requestedMemoryId);
    if (id == null) return;
    final sender = (int.tryParse(senderId) ?? 0) > 0
        ? senderId
        : visible
        ? currentChatId
        : null;
    if (sender != null) {
      _memories.putIfAbsent(id, StoryChatMemory.new).applyRead(sender, count);
    }
  }

  List<StoryChatEntry> history(int id) => _memories[id]?.entries ?? const [];

  /// Visible rows and memory rows share one entry registry. Read/log mutations
  /// therefore retain the same ownership after a portable restore.
  Map<String, Object?> snapshotData({
    Iterable<StoryChatEntry> visibleEntries = const [],
  }) {
    _requireCurrent(sourceEpoch);
    final entries = <int, StoryChatEntry>{};
    int retain(StoryChatEntry entry) {
      final previous = entries.putIfAbsent(entry.sequence, () => entry);
      if (!identical(previous, entry)) {
        throw const FormatException('story_chat_entry_alias');
      }
      return entry.sequence;
    }

    final memories = [
      for (final item in _memories.entries)
        {
          'id': item.key,
          'entries': item.value._entries.map(retain).toList(),
          'reads': [
            for (final read in item.value._reads.entries)
              {
                'senderId': read.key,
                'current': read.value.current,
                'appliedEntries': read.value.appliedEntries,
              },
          ],
        },
    ];
    final visibleRows = visibleEntries.map(retain).toList();
    return {
      'version': 1,
      'source': sourceIdentity.toJson(),
      'capturedEpoch': sourceEpoch,
      'sequence': _sequence,
      'currentChatId': currentChatId,
      'windowInstanceKey': windowInstanceKey,
      'memoryId': memoryId,
      'mode': mode,
      'visible': visible,
      'entries': [for (final entry in entries.values) entry.toJson()],
      'memories': memories,
      'visibleEntries': visibleRows,
    };
  }

  /// Resource identity stays exact while the caller owns the new runtime epoch.
  List<StoryChatEntry> restoreData(Map saved) {
    _requireCurrent(sourceEpoch);
    if (saved['version'] != 1 ||
        StorySourceIdentity.fromJson(saved['source'] as Map) !=
            sourceIdentity) {
      throw const FormatException('story_chat_snapshot_source');
    }
    final entries = <int, StoryChatEntry>{};
    for (final raw in (saved['entries'] as List).cast<Map>()) {
      final entry = StoryChatEntry.fromJson(raw);
      if (entries.containsKey(entry.sequence)) {
        throw const FormatException('story_chat_snapshot_duplicate_entry');
      }
      entries[entry.sequence] = entry;
    }
    List<StoryChatEntry> rows(Object? raw) {
      final ids = (raw as List).cast<int>();
      if (ids.toSet().length != ids.length) {
        throw const FormatException('story_chat_snapshot_duplicate_row');
      }
      return [
        for (final id in ids)
          entries[id] ??
              (throw const FormatException('story_chat_snapshot_entry')),
      ];
    }

    final memories = <int, StoryChatMemory>{};
    for (final raw in (saved['memories'] as List).cast<Map>()) {
      final id = raw['id'] as int;
      if (id <= 0 || memories.containsKey(id)) {
        throw const FormatException('story_chat_snapshot_memory');
      }
      final memory = StoryChatMemory().._entries.addAll(rows(raw['entries']));
      for (final rawRead in (raw['reads'] as List).cast<Map>()) {
        final sender = rawRead['senderId'] as String;
        final read = _ReadApplication()
          ..current = rawRead['current'] as int
          ..appliedEntries = rawRead['appliedEntries'] as int;
        final available = memory._entries
            .where((entry) => entry.senderId == sender)
            .length;
        if (memory._reads.containsKey(sender) ||
            read.current < 0 ||
            read.appliedEntries < 0 ||
            read.appliedEntries > available) {
          throw const FormatException('story_chat_snapshot_read');
        }
        memory._reads[sender] = read;
      }
      memories[id] = memory;
    }
    final visibleRows = rows(saved['visibleEntries']);
    final sequence = saved['sequence'] as int;
    final chatId = saved['currentChatId'] as String?;
    final windowKey = saved['windowInstanceKey'] as String?;
    final memoryId = saved['memoryId'] as int?;
    final mode = saved['mode'] as int;
    final visible = saved['visible'] as bool;
    if (sequence < 0 ||
        entries.keys.any((id) => id >= sequence) ||
        (memoryId != null && memoryId <= 0) ||
        mode < 0 ||
        mode > 2 ||
        (visible && (chatId == null || windowKey == null))) {
      throw const FormatException('story_chat_snapshot_state');
    }
    _memories
      ..clear()
      ..addAll(memories);
    _sequence = sequence;
    currentChatId = chatId;
    windowInstanceKey = windowKey;
    this.memoryId = memoryId;
    this.mode = mode;
    this.visible = visible;
    return List.unmodifiable(visibleRows);
  }

  void close() {
    _closed = true;
    visible = false;
    _memories.clear();
  }
}
