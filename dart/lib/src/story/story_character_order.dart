final class StoryCharacterOrder {
  static const _defaultSlots = [4, 0, 3, 1, 2];
  final List<int> _slots = [4, 0, 3, 1, 2];

  List<int> get slots => List.unmodifiable(_slots);

  void restore(List<int> snapshot) {
    if (snapshot.length != _defaultSlots.length ||
        snapshot.toSet().length != _defaultSlots.length ||
        !snapshot.every(_defaultSlots.contains)) {
      throw const FormatException('story_character_order_snapshot');
    }
    _slots
      ..clear()
      ..addAll(snapshot);
  }

  void reset() {
    _slots
      ..clear()
      ..addAll(_defaultSlots);
  }

  void move(int positionType, {required bool forward}) {
    reset();
    if (positionType < 1 || positionType > 9 || positionType.isEven) return;
    final slot = (positionType - 1) ~/ 2;
    _slots.remove(slot);
    if (forward) {
      _slots.add(slot);
    } else {
      _slots.insert(0, slot);
    }
  }

  List<T> orderByDepth<T>(
    Iterable<T> entries, {
    required int Function(T) slot,
    required double Function(T) worldDepth,
  }) => entries.toList()
    ..sort((a, b) {
      final depth = worldDepth(b).compareTo(worldDepth(a));
      return depth != 0
          ? depth
          : _slots.indexOf(slot(a)).compareTo(_slots.indexOf(slot(b)));
    });
}
