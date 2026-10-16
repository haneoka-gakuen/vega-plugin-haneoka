/// Game UI action order and labels shared with the web theme.
final class StoryPlayerControls {
  StoryPlayerControls._(this.groups, this.labels);

  final List<({String id, List<String> actions})> groups;
  final Map<String, Map<String, String>> labels;

  factory StoryPlayerControls.fromJson(Map data) {
    if (data['version'] != 1)
      throw const FormatException('story_controls_version');
    final groups = <({String id, List<String> actions})>[];
    final used = <String>{};
    for (final group in data['groups'] as List) {
      final actions = (group['actions'] as List).cast<String>();
      for (final action in actions) {
        if (!used.add(action))
          throw const FormatException('story_controls_duplicate');
      }
      groups.add((
        id: group['id'] as String,
        actions: List.unmodifiable(actions),
      ));
    }
    final labels = <String, Map<String, String>>{};
    for (final locale in (data['labels'] as Map).entries) {
      labels[locale.key as String] = Map.unmodifiable(
        Map<String, String>.from(locale.value as Map),
      );
      if (used.any((action) => !labels[locale.key]!.containsKey(action))) {
        throw const FormatException('story_controls_label_missing');
      }
    }
    if (!labels.containsKey('en'))
      throw const FormatException('story_controls_fallback_missing');
    return StoryPlayerControls._(
      List.unmodifiable(groups),
      Map.unmodifiable(labels),
    );
  }

  Map<String, String> forLocale(String locale) {
    final tag = locale.toLowerCase().replaceAll('_', '-');
    final key = tag.startsWith('zh')
        ? (tag.contains('hant') || tag.contains('tw') || tag.contains('hk')
              ? 'zh-TW'
              : 'zh-CN')
        : tag.split('-').first;
    return labels[key] ?? labels['en']!;
  }
}
