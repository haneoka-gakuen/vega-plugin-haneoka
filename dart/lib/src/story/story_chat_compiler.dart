import 'dart:math' as math;
import 'dart:typed_data';

import 'package:haneoka_render_profile/core.dart';

import 'story_chat_presentation.dart';
import 'story_chat_runtime.dart';
import 'story_chat_transform.dart';
import 'story_glyph_layout.dart';
import 'story_source_ui_image.dart';
import 'story_measured_ui_layout.dart';
import 'story_retained_ui_layout_state.dart';
import 'story_ui_layout_data.dart';

final class StoryChatTextRequest {
  const StoryChatTextRequest({
    required this.key,
    required this.text,
    required this.component,
    required this.sourceHash,
    required this.width,
    required this.height,
    this.localizeComponent,
    this.visibleCharacters = 0x7fffffff,
  });
  final String key, text, sourceHash;
  final Map<String, Object?> component;
  final Map<String, Object?>? localizeComponent;
  final double width, height;
  final int visibleCharacters;
}

final class StoryChatTextBatch {
  const StoryChatTextBatch({
    required this.meshes,
    required this.materials,
    required this.textures,
    required this.draws,
  });
  final Map<String, ProjectedMesh> meshes;
  final Map<String, NativeMaterial> materials;
  final Map<String, Uri> textures;
  final List<NativeDraw> draws;
}

typedef StoryChatMeasureText = StoryGlyphLayout Function(
  StoryChatTextRequest request,
);
typedef StoryChatEmitText = StoryChatTextBatch Function(
  StoryChatTextRequest request,
  StoryGlyphLayout glyphs,
  StoryUiRect rect,
  double canvasWidth,
  double canvasHeight,
  double screenScale,
);

final class StoryChatExternalImage {
  const StoryChatExternalImage({
    required this.uri,
    required this.width,
    required this.height,
  });
  final Uri uri;
  final double width, height;
}

final class StoryChatCompiledFrame {
  const StoryChatCompiledFrame({
    required this.scene,
    required this.frame,
    required this.textures,
    required this.layout,
    required this.textMeasurements,
  });
  final NativeSceneResources scene;
  final NativeFrame frame;
  final Map<String, Uri> textures;
  final StoryMeasuredUiLayout layout;
  final Map<String, StoryGlyphLayout> textMeasurements;
}

Map<String, Object?> _map(Object? value) =>
    Map<String, Object?>.from(value as Map);
String _pointer(Object? value) =>
    ((value as Map?)?['m_PathID'] ?? '0').toString();
bool _on(Object? value) => value == 1 || value == true;
double _number(Object? value, [double fallback = 0]) =>
    (value as num?)?.toDouble() ?? fallback;
List<double> _vector(Object? value, List<String> fields) {
  final map = value as Map;
  return [for (final field in fields) _number(map[field])];
}

String _script(Map value) =>
    ((value['m_Script'] as Map?)?['reference'] as Map?)?['name'] as String? ??
    value['_sourceType'] as String? ??
    '';

final class _Node {
  _Node(
    this.id,
    this.domain,
    this.originalId,
    this.rect,
    this.go,
    this.components,
    this.sourceHash,
  );
  final String id, domain, originalId, sourceHash;
  final Map<String, Object?> rect, go;
  final List<Map<String, Object?>> components;
  String? parent;
  String path = '';
  final children = <String>[];
  bool? active;
  String? text, spriteKey, externalImage;
  int visibleCharacters = 0x7fffffff;
  Map<String, Object?>? component(String name) {
    for (final value in components) {
      if (_script(value) == name) return value;
    }
    return null;
  }

  Map<String, Object?>? get textComponent {
    for (final value in components) {
      if (value.containsKey('m_text') && value.containsKey('m_fontAsset'))
        return value;
    }
    return null;
  }
}

final class _RetainedChatLayout {
  _RetainedChatLayout(this.signature, this.state);
  final String signature;
  final StoryRetainedUiLayoutState state;
  int storyUs = 0, updateIndex = 0;
}

final _retainedChatLayouts = Expando<_RetainedChatLayout>();

final class _ChatGraphCache {
  const _ChatGraphCache(this.binding, this.graph);
  final Object binding;
  final _Graph graph;
}

final _chatGraphs = Expando<_ChatGraphCache>();

final class _Graph {
  _Graph(this.runtime) {
    _domain('widget', runtime.source.widgetDomain);
    _domain('window', runtime.source.windowDomain);
    final parent =
        'widget:${_pointer(runtime.source.viewController['_windowParentRect'])}';
    for (final node in nodes.values.where(
      (n) => n.domain == 'window' && n.parent == null,
    )) {
      node.parent = parent;
      nodes[parent]!.children.add(node.id);
      node.active = true;
    }
  }
  final StoryChatRuntime runtime;
  int typingPadding = 0;
  final nodes = <String, _Node>{};
  final byGo = <String, String>{};
  final records = <String, Map<String, Object?>>{};
  final componentToNode = <String, String>{};

  void _domain(String domain, Map<String, Object?> packet) {
    final rows = (packet['records'] as List).cast<Map>();
    final local = {for (final row in rows) row['pathId'].toString(): row};
    for (final row in rows) {
      records['$domain:${row['pathId']}'] = _map(row['data']);
      if (row['type'] != 'RectTransform') continue;
      final raw = _map(row['data']);
      final go = _pointer(raw['m_GameObject']);
      final components = [
        for (final candidate in rows)
          if ((candidate['type'] == 'MonoBehaviour' ||
                  candidate['type'] == 'CanvasGroup' ||
                  candidate['type'] == 'Canvas') &&
              _pointer((candidate['data'] as Map)['m_GameObject']) == go)
            {
              ..._map(candidate['data']),
              if (candidate['type'] != 'MonoBehaviour')
                '_sourceType': candidate['type'],
            },
      ];
      final id = '$domain:${row['pathId']}';
      nodes[id] = _Node(
        id,
        domain,
        row['pathId'].toString(),
        raw,
        _map(local[go]!['data']),
        components,
        packet['sourceHash'] as String,
      );
      byGo['$domain:$go'] = id;
      for (final candidate in rows) {
        if (_pointer((candidate['data'] as Map)['m_GameObject']) == go) {
          componentToNode['$domain:${candidate['pathId']}'] = id;
        }
      }
    }
    for (final node in nodes.values.where((n) => n.domain == domain)) {
      final parent = '$domain:${_pointer(node.rect['m_Father'])}';
      node.parent = nodes.containsKey(parent) ? parent : null;
      for (final child in node.rect['m_Children'] as List? ?? const []) {
        final key = '$domain:${_pointer(child)}';
        if (nodes.containsKey(key)) node.children.add(key);
      }
    }
  }

  String? targetNode(
    Object? pointer, {
    String domain = 'window',
    String clone = '',
    bool followText = true,
  }) {
    final pid = _pointer(pointer);
    if (pid == '0') return null;
    final raw = records['$domain:$pid'];
    if (raw == null) return null;
    if (followText && raw['_targetText'] != null)
      return targetNode(raw['_targetText'], domain: domain, clone: clone);
    final key =
        componentToNode['$domain:$pid'] ??
        byGo['$domain:$pid'] ??
        '$domain:$pid';
    final result = '$clone$key';
    return nodes.containsKey(result) ? result : null;
  }

  void activate(Object? pointer, bool active, {String clone = ''}) {
    final key = targetNode(pointer, clone: clone);
    if (key != null) nodes[key]!.active = active;
  }

  void text(
    Object? pointer,
    String value, {
    String clone = '',
    int visible = 0x7fffffff,
  }) {
    final key = targetNode(pointer, clone: clone);
    if (key != null) {
      nodes[key]!.text = value;
      nodes[key]!.visibleCharacters = visible;
    }
  }

  void identityVisible(
    Map<String, Object?> template,
    bool visible,
    String clone,
  ) {
    final icon =
        targetNode(template['_chatIconRootObject'], clone: clone) ??
        targetNode(template['_chatIconImage'], clone: clone);
    if (icon != null) nodes[icon]!.active = visible;
    var name = targetNode(template['_senderNameRootObject'], clone: clone);
    if (name == null) {
      final text = targetNode(
        template['_senderNameText'],
        clone: clone,
        followText: false,
      );
      if (text != null) name = nodes[text]!.parent ?? text;
    }
    if (name != null) nodes[name]!.active = visible;
  }

  bool descendant(String id, String ancestor) {
    String? cursor = id;
    while (cursor != null) {
      if (cursor == ancestor) return true;
      cursor = nodes[cursor]?.parent;
    }
    return false;
  }

  String clone(String original, String parent, String prefix) {
    final source = nodes[original]!;
    final id = '$prefix$original';
    final node = _Node(
      id,
      source.domain,
      source.originalId,
      source.rect,
      source.go,
      source.components,
      source.sourceHash,
    )..parent = parent;
    nodes[id] = node;
    nodes[parent]!.children.add(id);
    for (final child in source.children.toList()) clone(child, id, prefix);
    return id;
  }

  void applyRuntime() {
    final controller = runtime.source.windowController;
    final standardLayout = controller['_chatLayoutMode'] != 1;
    final showIdentity = standardLayout || _on(controller['_isGroupChat']);
    activate(controller['_normalScreenObject'], runtime.screenMode == 0);
    activate(controller['_lockScreenObject'], runtime.screenMode == 2);
    activate(controller['_incomingCallObject'], runtime.screenMode == 1);
    text(controller['_windowNameText'], runtime.windowName);
    text(controller['_incomingCallNameText'], runtime.windowName);
    text(controller['_lockScreenNameText'], runtime.windowName);
    text(
      controller['_batteryPercentageText'],
      '${runtime.battery}${_on(controller['_showBatteryPercentSymbol']) ? '%' : ''}',
    );
    text(
      controller['_typingContentText'],
      runtime.typingText,
      visible: runtime.visibleTyping,
    );
    final normalParent = targetNode(controller['_chatNodeParent'])!;
    final lockParent = targetNode(controller['_lockChatNodeParent']);
    final templates = <String, Map<String, Object?>>{};
    for (final node in nodes.values.toList()) {
      for (final component in node.components) {
        final name = _script(component);
        if (name != 'AdvMyChatNode' && name != 'AdvOtherChatNode') continue;
        templates[node.id] = component;
        node.active = false;
      }
    }
    for (final entry in runtime.entries) {
      final other = entry.senderId != runtime.source.selection.id;
      for (final parent in [normalParent, if (lockParent != null) lockParent]) {
        final expected = other ? 'AdvOtherChatNode' : 'AdvMyChatNode';
        final original = templates.keys.firstWhere(
          (id) => descendant(id, parent) && _script(templates[id]!) == expected,
          orElse: () => targetNode(
            controller[other ? '_otherChatNodePrefab' : '_myChatNodePrefab'],
          )!,
        );
        final prefix = 'entry:${entry.sequence}:$parent:';
        final root = nodes.containsKey('$prefix$original')
            ? '$prefix$original'
            : clone(original, parent, prefix);
        nodes[root]!.active = true;
        final template = templates[original]!;
        identityVisible(template, showIdentity, prefix);
        text(template['_talkText'], entry.text, clone: prefix);
        text(template['_senderNameText'], entry.name, clone: prefix);
        text(
          template['_readText'],
          standardLayout && (entry.readCount ?? 0) > 0
              ? '${runtime.readText}${(entry.readCount ?? 0) > 1 ? ' ${entry.readCount}' : ''}'
              : '',
          clone: prefix,
        );
        activate(
          template['_textBox'],
          entry.kind == StoryChatEntryKind.text,
          clone: prefix,
        );
        activate(
          template['_stampImage'],
          entry.kind == StoryChatEntryKind.stamp,
          clone: prefix,
        );
        final stampNode = targetNode(template['_stampImage'], clone: prefix);
        if (stampNode != null && entry.kind == StoryChatEntryKind.stamp)
          nodes[stampNode]!.externalImage = entry.stampAsset;
        final iconNode = targetNode(template['_chatIconImage'], clone: prefix);
        final masters =
            (runtime.source.packet['chatAssets'] as Map?)?['masters'] as Map?;
        final master = masters?[entry.senderId] as Map?;
        final icon = master?['chatIconAssetName'];
        final icons = runtime.source.packet['iconsByAsset'] as Map?;
        if (iconNode != null && icons?[icon] is String)
          nodes[iconNode]!.spriteKey = icons![icon] as String;
      }
    }
  }
}

/// Pure source layout and draw compilation. The host supplies glyph measurement,
/// SDF material construction and asset URIs; no clock or IO is advanced here.
StoryChatCompiledFrame compileStoryChat({
  required StoryChatRuntime runtime,
  required RenderSource source,
  required int epoch,
  required int storyUs,
  required int updateIndex,
  required int width,
  required int height,
  required StoryChatMeasureText measureText,
  required StoryChatEmitText emitText,
  required Uri Function(Map<String, Object?> output) resolveOutput,
  Map<String, StoryChatExternalImage> externalImages = const {},
  bool layoutOnly = false,
}) {
  final graphBinding = (
    runtime.source.packet['sourceId'],
    runtime.source.selection.instanceKey,
    runtime.source.widgetDomain['sourceHash'],
    runtime.source.windowDomain['sourceHash'],
  );
  var cachedGraph = _chatGraphs[runtime];
  if (cachedGraph == null || cachedGraph.binding != graphBinding) {
    cachedGraph = _ChatGraphCache(graphBinding, _Graph(runtime));
    _chatGraphs[runtime] = cachedGraph;
    _retainedChatLayouts[runtime] = null;
  }
  final graph = cachedGraph.graph;
  graph.applyRuntime();
  final mainContentId = graph.targetNode(
    runtime.source.windowController['_chatNodeParent'],
  );
  final packet = runtime.source.packet;
  final sprites = packet['sprites'] as Map;
  Map? spriteFor(_Node node, Map image) {
    final ref = ((image['m_Sprite'] as Map?)?['reference'] as Map?);
    final key =
        node.spriteKey ??
        (ref == null ? null : '${ref['serializedFile']}:${ref['pathId']}');
    return sprites[key] as Map?;
  }

  final scaler = graph.nodes.values
      .expand((n) => n.components)
      .firstWhere((c) => _script(c) == 'CanvasScaler');
  if (scaler['m_UiScaleMode'] != 1 || scaler['m_ScreenMatchMode'] != 1) {
    throw UnsupportedError('story_chat_canvas_scaler');
  }
  final reference = scaler['m_ReferenceResolution'] as Map;
  final scale = math.min(
    width / _number(reference['x']),
    height / _number(reference['y']),
  );
  final canvasWidth = width / scale, canvasHeight = height / scale;
  final viewportCanvases = graph.nodes.values.where(
    (node) =>
        node.component('Canvas') != null &&
        node.component('CanvasScaler') != null,
  );
  for (final node in viewportCanvases) {
    final canvas = node.component('Canvas')!;
    if (!_on(canvas['m_Enabled']) ||
        canvas['m_RenderMode'] != 0 && canvas['m_RenderMode'] != 1) {
      throw UnsupportedError('story_chat_viewport_canvas_mode');
    }
    // The screen-space Canvas drives this boundary at runtime; its serialized
    // zero-size/zero-scale RectTransform is an authoring placeholder.
    node.rect.addAll({
      'm_AnchorMin': {'x': 0.0, 'y': 0.0},
      'm_AnchorMax': {'x': 1.0, 'y': 1.0},
      'm_AnchoredPosition': {'x': 0.0, 'y': 0.0},
      'm_SizeDelta': {'x': 0.0, 'y': 0.0},
      'm_Pivot': {'x': .5, 'y': .5},
      'm_LocalPosition': {'x': 0.0, 'y': 0.0, 'z': 0.0},
      'm_LocalRotation': {'x': 0.0, 'y': 0.0, 'z': 0.0, 'w': 1.0},
      'm_LocalScale': {'x': 1.0, 'y': 1.0, 'z': 1.0},
    });
  }
  final scope = (
    source.server,
    source.release,
    source.document,
    epoch,
    runtime.instanceKey,
  );
  final groups = <String, StoryLayoutGroupData>{}, fits = <String, List<int>>{};
  final elements = <String, List<StoryLayoutElementData>>{};
  Map<String, Object?> sceneNode(String id, String parent) {
    final n = graph.nodes[id]!, r = n.rect;
    n.path = '$parent/$id';
    for (final component in n.components) {
      if (!_on(component['m_Enabled'])) continue;
      switch (_script(component)) {
        case 'HorizontalLayoutGroup' || 'VerticalLayoutGroup':
          final group = StoryLayoutGroupData.fromRaw(component);
          if (n.id == mainContentId) group.padding[3] += graph.typingPadding;
          groups[n.path] = group;
        case 'ContentSizeFitter':
          fits[n.path] = [
            (component['m_HorizontalFit'] as num).toInt(),
            (component['m_VerticalFit'] as num).toInt(),
          ];
        case 'LayoutElement':
          elements
              .putIfAbsent(n.path, () => [])
              .add(StoryLayoutElementData.fromRaw(component));
      }
    }
    final image = n.component('Image');
    if (image != null && _on(image['m_Enabled'])) {
      final sprite = spriteFor(n, image);
      final external = externalImages[n.externalImage];
      if (sprite != null || external != null) {
        elements
            .putIfAbsent(n.path, () => [])
            .add(
              sourceUiImageLayoutElement(
                image: image,
                sprite: sprite == null
                    ? const {}
                    : _map((sprite['record'] as Map)['data']),
                referencePixelsPerUnit: _number(
                  scaler['m_ReferencePixelsPerUnit'],
                ),
                externalSpriteSize: external == null
                    ? null
                    : [external.width, external.height],
              ),
            );
      }
    }
    return {
      'name': id,
      'rect': [
        _vector(r['m_AnchorMin'], ['x', 'y']),
        _vector(r['m_AnchorMax'], ['x', 'y']),
        _vector(r['m_AnchoredPosition'], ['x', 'y']),
        _vector(r['m_SizeDelta'], ['x', 'y']),
        _vector(r['m_Pivot'], ['x', 'y']),
      ],
      'children': [for (final child in n.children) sceneNode(child, n.path)],
    };
  }

  final rawRoots = [
    for (final node in graph.nodes.values.where((n) => n.parent == null))
      sceneNode(node.id, ''),
  ];
  final roots = StoryUiSceneData.fromJson({
    'Chat': rawRoots,
  }, runtime.source.widgetDomain['sourceHash'] as String).scenes['Chat']!;
  final signature = graph.nodes.keys.join('|');
  var retainedCache = _retainedChatLayouts[runtime];
  if (retainedCache == null ||
      retainedCache.signature != signature ||
      storyUs < retainedCache.storyUs ||
      updateIndex < retainedCache.updateIndex) {
    retainedCache = _RetainedChatLayout(
      signature,
      StoryRetainedUiLayoutState(
        sourceScope: scope,
        nodes: [
          for (final n in graph.nodes.values)
            StoryRetainedUiNode(
              id: n.id,
              parentId: n.parent,
              anchorMin: _vector(n.rect['m_AnchorMin'], ['x', 'y']),
              anchorMax: _vector(n.rect['m_AnchorMax'], ['x', 'y']),
              anchoredPosition: _vector(n.rect['m_AnchoredPosition'], [
                'x',
                'y',
              ]),
              sizeDelta: _vector(n.rect['m_SizeDelta'], ['x', 'y']),
              pivot: _vector(n.rect['m_Pivot'], ['x', 'y']),
              localZ: _number((n.rect['m_LocalPosition'] as Map)['z']),
              quaternion: _vector(n.rect['m_LocalRotation'], [
                'x',
                'y',
                'z',
                'w',
              ]),
              scale: _vector(n.rect['m_LocalScale'], ['x', 'y', 'z']),
              active: n.active ?? _on(n.go['m_IsActive']),
              layoutGroup: groups.containsKey(n.path),
              contentSizeFitter: fits.containsKey(n.path),
            ),
        ],
      ),
    );
    _retainedChatLayouts[runtime] = retainedCache;
  }
  final retained = retainedCache.state;
  retainedCache.storyUs = storyUs;
  retainedCache.updateIndex = updateIndex;
  final windowParent =
      'widget:${_pointer(runtime.source.viewController['_windowParentRect'])}';
  void beginRetainedLayout() {
    retained.beginLayout(
      sourceScope: scope,
      actualUs: storyUs,
      actualUpdateIndex: updateIndex,
      canvas: StoryUiRect(
        -canvasWidth / 2,
        -canvasHeight / 2,
        canvasWidth,
        canvasHeight,
      ),
      activeOverrides: {
        for (final n in graph.nodes.values)
          n.id: n.active ?? _on(n.go['m_IsActive']),
      },
      poses: {
        windowParent: StoryRetainedUiPose(
          anchoredX: runtime.targetX,
          anchoredY: runtime.targetY,
        ),
        for (final entry in [
          (runtime.source.windowController['_chatNodeParent'], runtime.scroll),
          (
            runtime.source.windowController['_lockChatNodeParent'],
            runtime.lockScroll,
          ),
        ])
          if (graph.targetNode(entry.$1) case final id?)
            id: StoryRetainedUiPose(
              anchoredY:
                  _number(
                    (graph.nodes[id]!.rect['m_AnchoredPosition'] as Map)['y'],
                  ) +
                  entry.$2,
            ),
      },
    );
  }

  beginRetainedLayout();
  final paths = {for (final n in graph.nodes.values) n.path: n.id};
  final measured = <String, StoryGlyphLayout>{};
  StoryChatTextRequest request(_Node n, double w, double h) =>
      StoryChatTextRequest(
        key: n.id,
        text: n.text ?? n.textComponent!['m_text'] as String,
        component: n.textComponent!,
        localizeComponent: n.component('LocalizeText'),
        sourceHash: n.sourceHash,
        width: w,
        height: h,
        visibleCharacters: n.visibleCharacters,
      );
  for (final n in graph.nodes.values) {
    if (n.textComponent != null)
      measured[n.path] = measureText(request(n, 0, 0));
  }
  layoutRetainedMeasuredStoryUi(
    roots: roots,
    state: retained,
    pathToId: paths,
    measuredText: measured,
    actualGroups: groups,
    actualFits: fits,
    actualElements: elements,
  );
  for (final n in graph.nodes.values) {
    final rect = retained.basePlacements[n.id]!.localRect;
    if (n.textComponent != null)
      measured[n.path] = measureText(request(n, rect.width, rect.height));
  }
  var layout = layoutRetainedMeasuredStoryUi(
    roots: roots,
    state: retained,
    pathToId: paths,
    measuredText: measured,
    actualGroups: groups,
    actualFits: fits,
    actualElements: elements,
  );
  final typingRootId = graph.targetNode(
        runtime.source.windowController['_typingIndicatorBottomRect'],
      ),
      contentId = graph.targetNode(
        runtime.source.windowController['_chatNodeParent'],
      );
  if (typingRootId != null &&
      contentId != null &&
      retained.basePlacements[typingRootId]!.activeInHierarchy) {
    final path = graph.nodes[contentId]!.path, group = groups[path];
    final nextPadding = retained.basePlacements[typingRootId]!.localRect.height
        .ceil();
    if (group != null && nextPadding != graph.typingPadding) {
      final padding = List<double>.of(group.padding);
      padding[3] += nextPadding - graph.typingPadding;
      graph.typingPadding = nextPadding;
      groups[path] = StoryLayoutGroupData(
        horizontal: group.horizontal,
        padding: padding,
        spacing: group.spacing,
        alignment: group.alignment,
        control: group.control,
        expand: group.expand,
        reverse: group.reverse,
        scale: group.scale,
      );
      layout = layoutRetainedMeasuredStoryUi(
        roots: roots,
        state: retained,
        pathToId: paths,
        measuredText: measured,
        actualGroups: groups,
        actualFits: fits,
        actualElements: elements,
      );
    }
  }
  final scrollPlacements = retained.basePlacements,
      scrollMatrices = resolveRetainedStoryUiAffine(retained);
  var scrollChanged = false;
  for (final lock in [false, true]) {
    final nodeId = graph.targetNode(
      runtime.source.windowController[lock ? '_lockScrollRect' : '_scrollRect'],
    );
    if (nodeId == null) continue;
    final node = graph.nodes[nodeId]!, component = node.component('ScrollRect');
    if (component == null) continue;
    final contentId = graph.targetNode(component['m_Content']),
        viewportId = graph.targetNode(component['m_Viewport']) ?? nodeId;
    if (contentId == null) continue;
    final content = graph.nodes[contentId]!,
        contentRect = scrollPlacements[contentId]!.localRect,
        viewport = scrollPlacements[viewportId]!.localRect,
        cm = scrollMatrices[contentId]!,
        vm = scrollMatrices[viewportId]!;
    final determinant = vm[0] * vm[3] - vm[1] * vm[2];
    if (determinant == 0)
      throw const FormatException('story_chat_scroll_inverse');
    var minimum = double.infinity, maximum = double.negativeInfinity;
    for (final point in [
      (contentRect.x, contentRect.y),
      (contentRect.x + contentRect.width, contentRect.y),
      (contentRect.x, contentRect.y + contentRect.height),
      (contentRect.x + contentRect.width, contentRect.y + contentRect.height),
    ]) {
      final x = cm[0] * point.$1 + cm[2] * point.$2 + cm[4] - vm[4],
          y = cm[1] * point.$1 + cm[3] * point.$2 + cm[5] - vm[5],
          localY = (-vm[1] * x + vm[0] * y) / determinant;
      minimum = math.min(minimum, localY);
      maximum = math.max(maximum, localY);
    }
    final contentHeight = maximum - minimum,
        excess = math.max(0.0, viewport.height - contentHeight),
        pivotY = _number((content.rect['m_Pivot'] as Map)['y']),
        adjustedMinimum = minimum - excess * pivotY,
        hidden = math.max(0.0, contentHeight - viewport.height);
    final pm = scrollMatrices[content.parent!]!,
        parentDeterminant = pm[0] * pm[3] - pm[1] * pm[2],
        parentY = (-pm[1] * vm[2] + pm[0] * vm[3]) / parentDeterminant,
        position = lock ? runtime.lockScroll : runtime.scroll;
    scrollChanged =
        runtime.resolveScrollLayout(
          lock: lock,
          activeInHierarchy:
              runtime.active && scrollPlacements[nodeId]!.activeInHierarchy,
          bottomOffset: position + (viewport.y - adjustedMinimum) * parentY,
          hiddenLength: hidden * parentY,
        ) ||
        scrollChanged;
  }
  if (scrollChanged) {
    beginRetainedLayout();
    layout = layoutRetainedMeasuredStoryUi(
      roots: roots,
      state: retained,
      pathToId: paths,
      measuredText: measured,
      actualGroups: groups,
      actualFits: fits,
      actualElements: elements,
    );
  }
  if (layoutOnly) {
    return StoryChatCompiledFrame(
      scene: NativeSceneResources(
        epoch: epoch,
        source: source,
        meshes: const {},
        materials: const {},
        targets: {
          'story-chat': NativeTarget(
            width: width,
            height: height,
            presentable: true,
          ),
        },
      ),
      frame: NativeFrame(
        epoch: epoch,
        mediaMicroseconds: storyUs,
        outputTarget: 'story-chat',
        passes: [NativePass(target: 'story-chat', draws: const [])],
      ),
      textures: const {},
      layout: layout,
      textMeasurements: Map.unmodifiable(measured),
    );
  }
  final affine = scrollChanged
          ? resolveRetainedStoryUiAffine(retained)
          : scrollMatrices,
      placed = retained.basePlacements;
  final rootId = graph
      .byGo['window:${_pointer(runtime.source.windowController['m_GameObject'])}']!;
  final rootMatrix = affine[rootId]!, rootRect = placed[rootId]!.localRect;
  final determinant =
      rootMatrix[0] * rootMatrix[3] - rootMatrix[1] * rootMatrix[2];
  if (determinant == 0)
    throw const FormatException('story_chat_window_inverse');
  var minX = double.infinity, minY = double.infinity;
  var maxX = double.negativeInfinity, maxY = double.negativeInfinity;
  for (final node in graph.nodes.values) {
    final placement = placed[node.id]!;
    if (!placement.activeInHierarchy || !graph.descendant(node.id, rootId))
      continue;
    final r = placement.localRect, m = affine[node.id]!;
    for (final point in [
      (r.x, r.y),
      (r.x + r.width, r.y),
      (r.x, r.y + r.height),
      (r.x + r.width, r.y + r.height),
    ]) {
      final x = m[0] * point.$1 + m[2] * point.$2 + m[4] - rootMatrix[4];
      final y = m[1] * point.$1 + m[3] * point.$2 + m[5] - rootMatrix[5];
      final localX = (rootMatrix[3] * x - rootMatrix[2] * y) / determinant;
      final localY = (-rootMatrix[1] * x + rootMatrix[0] * y) / determinant;
      minX = math.min(minX, localX);
      maxX = math.max(maxX, localX);
      minY = math.min(minY, localY);
      maxY = math.max(maxY, localY);
    }
  }
  final windowPosition =
      runtime.source.windowController['_windowPosition'] as Map;
  final windowRotation =
      runtime.source.windowController['_windowRotation'] as Map;
  final offset =
      runtime.source.viewController['_incomingCallPositionOffset'] as Map;
  final defaultPosition =
      graph.nodes[windowParent]!.rect['m_AnchoredPosition'] as Map;
  final transform = resolveStoryChatWindowTransform(
    viewWidth: canvasWidth,
    viewHeight: canvasHeight,
    windowHeight: rootRect.height,
    visibleWidth: maxX > minX ? maxX - minX : rootRect.width,
    visibleHeight: maxY > minY ? maxY - minY : rootRect.height,
    mode: runtime.screenMode,
    defaultX: _number(defaultPosition['x']),
    windowX: _number(windowPosition['x']),
    windowY: _number(windowPosition['y']),
    incomingX: _number(offset['x']),
    incomingY: _number(offset['y']),
    rotationZ: _number(windowRotation['z']),
  );
  final parentMatrix = affine[windowParent]!;
  final rawTargetX =
      _number(defaultPosition['x']) +
      _number(windowPosition['x']) +
      (runtime.screenMode == 1 ? _number(offset['x']) : 0);
  final rawTargetY =
      _number(windowPosition['y']) +
      (runtime.screenMode == 1 ? _number(offset['y']) : 0);

  final meshes = <String, ProjectedMesh>{},
      materials = <String, NativeMaterial>{};
  final textures = <String, Uri>{},
      targets = <String, NativeTarget>{
        'story-chat': NativeTarget(
          width: width,
          height: height,
          presentable: true,
        ),
      };
  final maskPasses = <NativePass>[], draws = <NativeDraw>[];
  final masks = <String, CoverageMask>{};
  double opacity(String id) {
    final n = graph.nodes[id]!;
    final group = n.component('CanvasGroup');
    final own = _number(group?['m_Alpha'], 1);
    return own *
        (n.parent == null || _on(group?['m_IgnoreParentGroups'])
            ? 1
            : opacity(n.parent!));
  }

  ProjectedMesh project(
    ProjectedMesh mesh,
    String id, {
    bool applyOpacity = true,
  }) {
    final m = affine[id]!, vertices = Float32List.fromList(mesh.vertices);
    for (var i = 0; i < vertices.length; i += 10) {
      final x = (vertices[i] + 1) * canvasWidth / 2,
          y = (vertices[i + 1] - 1) * canvasHeight / 2;
      var px = m[0] * x + m[2] * y + m[4], py = m[1] * x + m[3] * y + m[5];
      if (graph.descendant(id, windowParent)) {
        px =
            parentMatrix[4] +
            transform.scale * (px - parentMatrix[4]) +
            transform.x -
            rawTargetX;
        py =
            parentMatrix[5] +
            transform.scale * (py - parentMatrix[5]) +
            transform.y -
            rawTargetY;
      }
      vertices[i] = 2 * px / canvasWidth - 1;
      vertices[i + 1] = 2 * py / canvasHeight - 1;
      if (applyOpacity) vertices[i + 9] *= opacity(id);
    }
    return ProjectedMesh(vertices, mesh.indices);
  }

  NativeMaterial masked(NativeMaterial value, CoverageMask? mask) =>
      NativeMaterial(
        texture: value.texture,
        recipe: value.recipe,
        blend: value.blend,
        textureAlpha: value.textureAlpha,
        uniformFloats: value.uniformFloats,
        additionalTextures: value.additionalTextures,
        depthTest: value.depthTest,
        depthWrite: value.depthWrite,
        cull: value.cull,
        widthAddressMode: value.widthAddressMode,
        heightAddressMode: value.heightAddressMode,
        minFilter: value.minFilter,
        magFilter: value.magFilter,
        coverageMask: mask,
      );
  CoverageMask? inherited(_Node n) => n.parent == null ? null : masks[n.parent];
  final matrix = Float32List.fromList([
    .5,
    0,
    0,
    0,
    0,
    -.5,
    0,
    0,
    0,
    0,
    1,
    0,
    .5,
    .5,
    0,
    1,
  ]);
  void visit(String id) {
    final n = graph.nodes[id]!;
    if (!placed[id]!.activeInHierarchy || !runtime.active) return;
    final parentMask = inherited(n);
    if (parentMask != null) masks[id] = parentMask;
    final image = n.component('Image');
    if (image != null && _on(image['m_Enabled'])) {
      final pointer = image['m_Sprite'] as Map?;
      final ref = pointer?['reference'] as Map?;
      final spriteKey =
          n.spriteKey ??
          (ref == null ? null : '${ref['serializedFile']}:${ref['pathId']}');
      final sprite = sprites[spriteKey] as Map?;
      final external = externalImages[n.externalImage];
      final solid =
          sprite == null && external == null && n.externalImage == null;
      if (sprite != null || external != null || solid) {
        final r = placed[id]!.localRect;
        final rawSprite = sprite == null
            ? null
            : ((sprite['record'] as Map)['data'] as Map);
        final directTexture = sprite?['textureReference'] is String;
        final key =
            'chat-image:${sprite?['textureReference'] ?? spriteKey ?? n.externalImage}';
        final output = sprite == null
            ? null
            : (sprite[directTexture ? 'textureOutputs' : 'outputs'] as List)
                  .cast<Map>()
                  .firstWhere(
                    (o) =>
                        o['type'] == (directTexture ? 'Texture2D' : 'Sprite'),
                  );
        if (!solid)
          textures[key] = external?.uri ?? resolveOutput(_map(output));
        final texturePacket = !directTexture
            ? null
            : (packet['textures'] as Map)[sprite!['textureReference']] as Map;
        final batteryNode = graph.targetNode(
          runtime.source.windowController['_batteryFillImage'],
        );
        final mappedMesh = buildSourceUiImageMesh(
          image: image,
          sprite: rawSprite == null ? null : _map(rawSprite),
          texture: texturePacket == null
              ? null
              : _map((texturePacket['record'] as Map)['data']),
          localRect: r,
          canvasWidth: canvasWidth,
          canvasHeight: canvasHeight,
          referencePixelsPerUnit: _number(scaler['m_ReferencePixelsPerUnit']),
          pivot: _vector(n.rect['m_Pivot'], ['x', 'y']),
          externalSpriteSize: external == null
              ? null
              : [external.width, external.height],
          fillAmount: id == batteryNode ? runtime.battery / 100 : null,
          wholeTextureCoordinates: directTexture,
        );
        final mesh = project(mappedMesh, id);
        final hard = n.component('Mask'), soft = n.component('SoftMask');
        if (hard != null && _on(hard['m_Enabled']) ||
            soft != null && _on(soft['m_Enabled'])) {
          final target = 'chat-mask:$id', writer = 'chat-mask-write:$id';
          if (solid)
            throw UnsupportedError('story_chat_mask_without_graphic_texture');
          final isSoft = soft != null && _on(soft['m_Enabled']);
          targets[target] = NativeTarget(width: width, height: height);
          meshes[writer] = project(mappedMesh, id, applyOpacity: false);
          materials[writer] = NativeMaterial(
            texture: key,
            recipe: NativeMaterialRecipe.coverageMask,
            textureAlpha: NativeTextureAlpha.premultiplied,
            blend: NativeBlend.opaque,
            uniformFloats: Float32List.fromList([
              isSoft ? 1 : 0,
              isSoft ? 0 : .001,
              0,
              0,
            ]),
            coverageMask: parentMask,
          );
          maskPasses.add(
            NativePass(
              target: target,
              draws: [NativeDraw(mesh: writer, material: writer)],
            ),
          );
          masks[id] = CoverageMask(
            texture: target,
            clipToMaskUv: matrix,
            mode: CoverageMaskMode.soft,
            threshold: 0,
          );
        }
        if (hard == null ||
            !_on(hard['m_Enabled']) ||
            _on(hard['m_ShowMaskGraphic'])) {
          meshes[id] = mesh;
          materials[id] = NativeMaterial(
            texture: key,
            recipe: solid
                ? NativeMaterialRecipe.solidColor
                : NativeMaterialRecipe.textured,
            textureAlpha: NativeTextureAlpha.premultiplied,
            coverageMask: parentMask,
          );
          draws.add(NativeDraw(mesh: id, material: id));
        }
      }
    }
    if (n.textComponent != null && measured[n.path] != null) {
      final r = placed[id]!.localRect;
      final batch = emitText(
        request(n, r.width, r.height),
        measured[n.path]!,
        StoryUiRect(r.x, -r.y - r.height, r.width, r.height),
        canvasWidth,
        canvasHeight,
        scale * (graph.descendant(id, windowParent) ? transform.scale : 1),
      );
      meshes.addAll({
        for (final e in batch.meshes.entries) e.key: project(e.value, id),
      });
      materials.addAll({
        for (final e in batch.materials.entries)
          e.key: masked(e.value, masks[id]),
      });
      textures.addAll(batch.textures);
      draws.addAll(batch.draws);
    }
    for (final child in n.children) visit(child);
  }

  for (final node in graph.nodes.values.where((n) => n.parent == null))
    visit(node.id);
  final filteredMasks = [
    for (final pass in maskPasses)
      NativePass(
        target: pass.target,
        clear: pass.clear,
        clearColor: pass.clearColor,
        draws: [
          for (final draw in pass.draws)
            if (meshes[draw.mesh]!.indices.isNotEmpty) draw,
        ],
      ),
  ];
  draws.removeWhere((draw) => meshes[draw.mesh]!.indices.isEmpty);
  return StoryChatCompiledFrame(
    scene: NativeSceneResources(
      epoch: epoch,
      source: source,
      meshes: meshes,
      materials: materials,
      targets: targets,
    ),
    frame: NativeFrame(
      epoch: epoch,
      mediaMicroseconds: storyUs,
      outputTarget: 'story-chat',
      passes: [
        ...filteredMasks,
        NativePass(target: 'story-chat', draws: draws),
      ],
    ),
    textures: Map.unmodifiable(textures),
    layout: layout,
    textMeasurements: Map.unmodifiable(measured),
  );
}
