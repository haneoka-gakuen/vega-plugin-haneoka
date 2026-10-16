/// AdvSession keeps named bindings across Out and cached-controller reuse.
final class StoryCharacterPlacement {
  final _byName = <String, int>{};
  final _byPosition = <int, String>{};
  final _positions = <int>[];

  int? positionOf(String name) => _byName[name];
  String? nameAt(int position) => _byPosition[position];
  List<int> get positions => List.unmodifiable(_positions);
  Map<String, Object?> snapshotData() => {
    'names': Map<String, int>.of(_byName),
    'positions': {
      for (final entry in _byPosition.entries) '${entry.key}': entry.value,
    },
    'order': List<int>.of(_positions),
  };
  void restoreData(Map data) {
    _byName
      ..clear()
      ..addAll(Map<String, int>.from(data['names'] as Map));
    _byPosition
      ..clear()
      ..addAll({
        for (final entry in (data['positions'] as Map).entries)
          int.parse(entry.key as String): entry.value as String,
      });
    _positions
      ..clear()
      ..addAll((data['order'] as List).cast<int>());
  }

  StoryCharacterPlacementSnapshot snapshot() =>
      StoryCharacterPlacementSnapshot._(
        Map.unmodifiable(_byName),
        Map.unmodifiable(_byPosition),
        positions,
      );

  void restore(StoryCharacterPlacementSnapshot snapshot) {
    _byName
      ..clear()
      ..addAll(snapshot._names);
    _byPosition
      ..clear()
      ..addAll(snapshot._positions);
    _positions
      ..clear()
      ..addAll(snapshot._order);
  }

  /// SetCharacterPositionInfo resets the incoming name and destination only.
  void place(String name, int position) {
    if (_positions.contains(position)) {
      _byName.remove(name);
      _byPosition.remove(position);
      _positions.remove(position);
    }
    _byName[name] = position;
    _byPosition[position] = name;
    _positions.add(position);
  }

  Map<String, Object?> get observation => {
    'names': Map.unmodifiable(_byName),
    'positions': Map.unmodifiable(_byPosition),
    'currentPositions': positions,
  };
}

final class StoryCharacterPlacementSnapshot {
  StoryCharacterPlacementSnapshot._(this._names, this._positions, this._order);
  final Map<String, int> _names;
  final Map<int, String> _positions;
  final List<int> _order;
}
