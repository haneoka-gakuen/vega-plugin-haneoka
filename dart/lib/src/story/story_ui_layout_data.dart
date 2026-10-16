List<double> _numbers(Object? value, int size) {
  if (value is! List ||
      value.length != size ||
      value.any((v) => v is! num || !v.isFinite)) {
    throw const FormatException('story_ui_tuple');
  }
  return List.unmodifiable(value.cast<num>().map((v) => v.toDouble()));
}

final class StoryUiRect {
  const StoryUiRect(this.x, this.y, this.width, this.height);
  final double x, y, width, height;
}

final class StoryUiTextData {
  StoryUiTextData._(this.raw);
  factory StoryUiTextData.fromJson(Map<String, Object?> raw) =>
      StoryUiTextData._(Map.unmodifiable(raw));
  final Map<String, Object?> raw;
  String get fontName => raw['font'] as String;
  String get materialName => raw['material'] as String;
  double get size => (raw['size'] as num).toDouble();
  double get characterSpacing => (raw['characterSpacing'] as num).toDouble();
  double get lineSpacing => (raw['lineSpacing'] as num).toDouble();
  int get horizontal => (raw['horizontal'] as num).toInt();
  int get vertical => (raw['vertical'] as num).toInt();
  int get style => (raw['style'] as num).toInt();
  List<double> get color => _numbers(raw['color'], 4);
}

final class StoryUiLayoutNode {
  StoryUiLayoutNode._({
    required this.path,
    required this.raw,
    required this.rect,
    required this.children,
    required this.text,
  });
  final String path;
  final Map<String, Object?> raw;

  /// anchorMin, anchorMax, anchoredPosition, sizeDelta, pivot (Unity y-up).
  final List<List<double>> rect;
  final List<StoryUiLayoutNode> children;
  final StoryUiTextData? text;
  Map<String, Object?>? get layoutGroup => raw['layout'] is Map
      ? Map<String, Object?>.from(raw['layout'] as Map)
      : null;
  List<double>? get contentSizeFit =>
      raw['fit'] is List ? _numbers(raw['fit'], 2) : null;

  /// Anchored rect before source LayoutGroup / ContentSizeFitter drives it.
  /// A driven zero-size Text rect is not interpreted as an empty layout.
  StoryUiRect anchoredRect(StoryUiRect parent) {
    final minimum = rect[0],
        maximum = rect[1],
        position = rect[2],
        size = rect[3],
        pivot = rect[4];
    final w = parent.width * (maximum[0] - minimum[0]) + size[0];
    final h = parent.height * (maximum[1] - minimum[1]) + size[1];
    final px =
        parent.x +
        parent.width * (minimum[0] + (maximum[0] - minimum[0]) * pivot[0]) +
        position[0];
    final py =
        parent.y +
        parent.height * (minimum[1] + (maximum[1] - minimum[1]) * pivot[1]) +
        position[1];
    return StoryUiRect(px - w * pivot[0], py - h * pivot[1], w, h);
  }
}

final class StoryUiSceneData {
  StoryUiSceneData._(this.sourceHash, this.scenes);
  final String sourceHash;
  final Map<String, List<StoryUiLayoutNode>> scenes;
  factory StoryUiSceneData.fromJson(
    Map<String, Object?> source,
    String sourceHash,
  ) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(sourceHash)) {
      throw const FormatException('story_ui_source');
    }
    StoryUiLayoutNode parse(Map<String, Object?> raw, String parent) {
      final name = raw['name'];
      if (name is! String ||
          raw['rect'] is! List ||
          (raw['rect'] as List).length != 5) {
        throw const FormatException('story_ui_node');
      }
      final path = '$parent/$name', value = raw['text'];
      return StoryUiLayoutNode._(
        path: path,
        raw: Map.unmodifiable(raw),
        rect: List.unmodifiable(
          (raw['rect'] as List).map((p) => _numbers(p, 2)),
        ),
        text: value is Map
            ? StoryUiTextData._(
                Map.unmodifiable(Map<String, Object?>.from(value)),
              )
            : null,
        children: List.unmodifiable(
          (raw['children'] as List? ?? const []).map(
            (child) => parse(Map<String, Object?>.from(child as Map), path),
          ),
        ),
      );
    }

    return StoryUiSceneData._(
      sourceHash,
      Map.unmodifiable(
        source.map(
          (key, value) => MapEntry(
            key,
            List<StoryUiLayoutNode>.unmodifiable(
              (value as List).map(
                (node) => parse(Map<String, Object?>.from(node as Map), ''),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
