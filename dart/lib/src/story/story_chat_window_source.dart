import 'story_chat_source_catalog.dart';
import 'story_text_compiler.dart';
import 'story_ui_layout_data.dart';

/// Exact prefab domains selected by the release master, with local PPtr access
/// kept in the source adapter. Hosts provide verified packet bytes.
final class StoryChatWindowSource {
  StoryChatWindowSource({required this.packet, required this.selection}) {
    widgetDomain = Map<String, Object?>.from(packet['widget'] as Map);
    final windows = packet['windows'] as Map;
    final rawWindow = windows[selection.windowAssetName];
    if (rawWindow is! Map) {
      throw FormatException(
        'story_chat_window_prefab:${selection.windowAssetName}',
      );
    }
    windowDomain = Map<String, Object?>.from(rawWindow);
    Map<String, Map<String, Object?>> rows(Map domain) => {
      for (final row in (domain['records'] as List).cast<Map>())
        row['pathId'].toString(): Map<String, Object?>.from(row),
    };
    widgetRecords = rows(widgetDomain);
    windowRecords = rows(windowDomain);
    Map<String, Object?> script(
      Map<String, Map<String, Object?>> records,
      String name,
    ) => Map<String, Object?>.from(
      records.values.singleWhere((row) {
            final data = row['data'] as Map;
            return row['type'] == 'MonoBehaviour' &&
                ((data['m_Script'] as Map?)?['reference'] as Map?)?['name'] ==
                    name;
          })['data']
          as Map,
    );
    final widget = script(widgetRecords, 'UIAdvChatWidget');
    viewController = component('widget', pointer(widget['_chatView']));
    windowController = script(windowRecords, 'AdvChatWindow');
  }
  final Map<String, Object?> packet;
  final StoryChatSourceSelection selection;
  late final Map<String, Object?> widgetDomain, windowDomain;
  late final Map<String, Map<String, Object?>> widgetRecords, windowRecords;
  late final Map<String, Object?> windowController, viewController;
  Map<String, Object?> component(String domain, String id) {
    final row = (domain == 'widget' ? widgetRecords : windowRecords)[id];
    if (row == null) throw FormatException('story_chat_component:$domain:$id');
    return Map<String, Object?>.from(row['data'] as Map);
  }

  String pointer(Object? value) {
    final p = value as Map;
    if (p['m_FileID'] != 0 || p['m_PathID'] == null) {
      throw const FormatException('story_chat_local_pointer');
    }
    return p['m_PathID'].toString();
  }

  Map<String, Object?> bubbleTemplate(bool other) => component(
    'window',
    pointer(
      windowController[other ? '_otherChatNodePrefab' : '_myChatNodePrefab'],
    ),
  );
  Map<String, Object?> textComponent(String id) =>
      component('window', pointer(component('window', id)['_targetText']));
  StoryTextSourceBinding textBinding(String id) =>
      StoryTextSourceBinding.fromRaw(
        sourceHash: windowDomain['sourceHash'] as String,
        component: textComponent(id),
      );
}

/// Localized font selection is supplied by the host font bank. All size,
/// alignment and style fields remain the selected TMP component's authored data.
StoryUiTextData storyChatTextData(Map<String, Object?> component) {
  final color = component['m_fontColor'] as Map;
  return StoryUiTextData.fromJson({
    'font': ((component['m_fontAsset'] as Map)['reference'] as Map)['name'],
    'material':
        ((component['m_sharedMaterial'] as Map)['reference'] as Map)['name'],
    'size': component['m_fontSize'],
    'characterSpacing': component['m_characterSpacing'],
    'lineSpacing': component['m_lineSpacing'],
    'horizontal': component['m_HorizontalAlignment'],
    'vertical': component['m_VerticalAlignment'],
    'style': component['m_fontStyle'],
    'color': [
      for (final key in ['r', 'g', 'b', 'a']) color[key],
    ],
    'autoSize':
        component['m_enableAutoSizing'] == true ||
        component['m_enableAutoSizing'] == 1,
    'minSize': component['m_fontSizeMin'],
    'maxSize': component['m_fontSizeMax'],
  });
}
