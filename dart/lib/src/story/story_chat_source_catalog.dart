import 'story_scene_state.dart';

/// Release-scoped master bindings; native UI data is selected by the authored
/// window asset, independently of which chapter requested that window.
final class StoryChatSourceCatalog {
  StoryChatSourceCatalog({
    required this.identity,
    required Map<String, Object?> runtime,
  }) : _source = Map<String, Object?>.unmodifiable(
         Map<String, Object?>.from(runtime['chatAssets'] as Map),
       );

  final StorySourceIdentity identity;
  final Map<String, Object?> _source;
  final _resolved = <String, StoryChatSourceSelection>{};

  /// Named stamps are shared Adv assets. The authored placeholder keeps the
  /// release's default chat data root; explicit paths retain their location.
  String stampPath(String asset) {
    final source = asset.trim();
    if (source.isEmpty) throw const FormatException('story_chat_stamp_asset');
    if (source.startsWith('/') || Uri.parse(source).hasScheme) return source;
    final file = source.endsWith('.png') ? source : '$source.png';
    if (source.startsWith('Assets/') || source.startsWith('runtime/')) {
      return file;
    }
    if (!RegExp(r'^stamp(?:\.png)?$', caseSensitive: false).hasMatch(source)) {
      return 'Assets/AddressableResources/Adv/Chat/Stamp/$file';
    }
    final root = _source['defaultDataRoot'] as String;
    return '$root/$file';
  }

  StoryChatSourceSelection resolve(String authoredId) =>
      _resolved.putIfAbsent(authoredId, () {
        final raw = (_source['masters'] as Map)[authoredId];
        if (raw is! Map || '${raw['id']}' != authoredId) {
          throw FormatException('story_chat_master:$authoredId');
        }
        final window = raw['chatWindowAssetName'];
        final icon = raw['chatIconAssetName'];
        final inOut = raw['inOutSoundId'], sound = raw['chatSoundId'];
        if (window is! String ||
            icon is! String ||
            inOut is! int ||
            sound is! int ||
            inOut < 0 ||
            sound < 0) {
          throw FormatException('story_chat_master_fields:$authoredId');
        }
        final root =
            (_source['dataRootsByWindowAsset'] as Map)[window] ??
            _source['defaultDataRoot'];
        if (root is! String || !root.startsWith('Assets/')) {
          throw FormatException('story_chat_window_binding:$window');
        }
        final iconPath = icon.isEmpty
            ? null
            : (_source['iconImagesByAsset'] as Map)[icon];
        if (icon.isNotEmpty && (iconPath is! String || iconPath.isEmpty)) {
          throw FormatException('story_chat_icon_binding:$icon');
        }
        return StoryChatSourceSelection(
          id: authoredId,
          windowAssetName: window,
          iconAssetName: icon,
          dataRoot: root,
          iconPath: iconPath as String?,
          inOutSoundId: inOut,
          chatSoundId: sound,
          master: Map<String, Object?>.unmodifiable(
            Map<String, Object?>.from(raw),
          ),
        );
      });
}

final class StoryChatSourceSelection {
  const StoryChatSourceSelection({
    required this.id,
    required this.windowAssetName,
    required this.iconAssetName,
    required this.dataRoot,
    required this.iconPath,
    required this.inOutSoundId,
    required this.chatSoundId,
    required this.master,
  });
  final String id, windowAssetName, iconAssetName, dataRoot;
  final String? iconPath;
  final int inOutSoundId, chatSoundId;
  final Map<String, Object?> master;
  String get instanceKey => windowAssetName;
}
