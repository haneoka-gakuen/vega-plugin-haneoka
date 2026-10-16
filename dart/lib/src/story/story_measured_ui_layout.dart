import 'dart:math' as math;
import 'dart:typed_data';

import 'story_glyph_layout.dart';
import 'story_ui_layout_data.dart';
import 'story_retained_ui_layout_state.dart';

final class StoryMeasuredUiLayout {
  StoryMeasuredUiLayout(Map<String, StoryUiRect> rects)
    : rects = Map.unmodifiable(rects);

  /// Original canvas coordinates: x-right, Unity y-up.
  final Map<String, StoryUiRect> rects;
}

StoryUiRect topDownStoryUiRect(StoryUiRect r, double canvasHeight) =>
    StoryUiRect(r.x, canvasHeight - r.y - r.height, r.width, r.height);

/// Actual ILayoutElement contribution; priority is evaluated separately for
/// every property, and negative values do not participate in that property.
final class StoryLayoutElementData {
  const StoryLayoutElementData({
    required this.priority,
    required this.minimum,
    required this.preferred,
    required this.flexible,
    required this.ignoreLayout,
  });
  final int priority;
  final List<double> minimum, preferred, flexible;
  final bool ignoreLayout;
  factory StoryLayoutElementData.fromRaw(Map<String, Object?> raw) =>
      StoryLayoutElementData(
        priority: (raw['m_LayoutPriority'] as num).toInt(),
        minimum: [
          (raw['m_MinWidth'] as num).toDouble(),
          (raw['m_MinHeight'] as num).toDouble(),
        ],
        preferred: [
          (raw['m_PreferredWidth'] as num).toDouble(),
          (raw['m_PreferredHeight'] as num).toDouble(),
        ],
        flexible: [
          (raw['m_FlexibleWidth'] as num).toDouble(),
          (raw['m_FlexibleHeight'] as num).toDouble(),
        ],
        ignoreLayout:
            raw['m_IgnoreLayout'] == 1 || raw['m_IgnoreLayout'] == true,
      );

  /// TMP's ILayoutElement contract supplies zero minimum and negative
  /// flexibility; preferred height includes the source TMP vertical margins.
  factory StoryLayoutElementData.measuredTmp(
    StoryGlyphLayout layout, {
    double marginTop = 0,
    double marginBottom = 0,
  }) => StoryLayoutElementData(
    priority: 0,
    minimum: const [0, 0],
    preferred: [layout.width, layout.height + marginTop + marginBottom],
    flexible: const [-1, -1],
    ignoreLayout: false,
  );
}

final class StoryLayoutGroupData {
  StoryLayoutGroupData({
    required this.horizontal,
    required this.padding,
    required this.spacing,
    required this.alignment,
    required this.control,
    required this.expand,
    required this.reverse,
    required this.scale,
  }) {
    if (scale.any((v) => v)) throw UnsupportedError('story_layout_child_scale');
  }
  final bool horizontal, reverse;
  final List<double> padding;
  final double spacing;
  final int alignment;
  final List<bool> control, expand, scale;
  factory StoryLayoutGroupData.fromRaw(Map<String, Object?> raw) {
    final name = ((raw['m_Script'] as Map)['reference'] as Map)['name'];
    if (name != 'HorizontalLayoutGroup' && name != 'VerticalLayoutGroup') {
      throw UnsupportedError('story_layout_group:$name');
    }
    bool flag(String key) {
      final v = raw[key];
      if (v != 0 && v != 1 && v != false && v != true) {
        throw FormatException('story_layout_$key');
      }
      return v == 1 || v == true;
    }

    final p = raw['m_Padding'] as Map;
    return StoryLayoutGroupData(
      horizontal: name == 'HorizontalLayoutGroup',
      padding: [
        for (final k in ['m_Left', 'm_Right', 'm_Top', 'm_Bottom'])
          (p[k] as num).toDouble(),
      ],
      spacing: (raw['m_Spacing'] as num).toDouble(),
      alignment: (raw['m_ChildAlignment'] as num).toInt(),
      control: [flag('m_ChildControlWidth'), flag('m_ChildControlHeight')],
      expand: [
        flag('m_ChildForceExpandWidth'),
        flag('m_ChildForceExpandHeight'),
      ],
      scale: [flag('m_ChildScaleWidth'), flag('m_ChildScaleHeight')],
      reverse: flag('m_ReverseArrangement'),
    );
  }
}

typedef _Size = (double, double, double); // minimum, preferred, flexible

/// Source group bindings carry the flags omitted by the compact UI JSON.
/// Controlled non-text children require their actual ILayoutElement data.
StoryMeasuredUiLayout layoutMeasuredStoryUi({
  required List<StoryUiLayoutNode> roots,
  required StoryUiRect canvas,
  required Map<String, StoryGlyphLayout> measuredText,
  required Map<String, StoryLayoutGroupData> actualGroups,
  Map<String, List<StoryLayoutElementData>> actualElements = const {},
  Set<String> inactivePaths = const {},
}) {
  final rects = <String, StoryUiRect>{}, sizes = <String, List<_Size>>{};
  List<StoryUiLayoutNode> children(StoryUiLayoutNode n) => n.children
      .where(
        (c) =>
            !inactivePaths.contains(c.path) &&
            !(actualElements[c.path] ?? const []).any((e) => e.ignoreLayout),
      )
      .toList();
  double property(
    List<StoryLayoutElementData> elements,
    int axis,
    List<double> Function(StoryLayoutElementData) get,
  ) {
    var priority = -2147483648, value = 0.0;
    for (final e in elements) {
      final v = get(e)[axis];
      if (v < 0 || e.priority < priority) continue;
      if (e.priority > priority) {
        priority = e.priority;
        value = v;
      } else {
        value = math.max(value, v);
      }
    }
    return value;
  }

  StoryLayoutGroupData? group(StoryUiLayoutNode n) {
    final g = actualGroups[n.path];
    if (n.layoutGroup != null && g == null) {
      throw FormatException('story_layout_source_group:${n.path}');
    }
    return g;
  }

  _Size childSize(StoryUiLayoutNode child, StoryLayoutGroupData g, int axis) {
    if (!g.control[axis]) {
      final fixed = child.rect[3][axis];
      return (fixed, fixed, g.expand[axis] ? 1 : 0);
    }
    if (!sizes.containsKey(child.path)) {
      throw FormatException('story_layout_source_element:${child.path}');
    }
    final s = sizes[child.path]![axis];
    return (s.$1, s.$2, g.expand[axis] ? math.max(1, s.$3) : s.$3);
  }

  List<_Size> measure(StoryUiLayoutNode n, StoryUiRect parent) {
    final rect = n.anchoredRect(parent), g = group(n);
    final cs = children(n);
    for (final c in cs) {
      measure(c, rect);
    }
    final elements = <StoryLayoutElementData>[
      ...actualElements[n.path] ?? const [],
    ];
    final text = measuredText[n.path];
    if (text != null) elements.add(StoryLayoutElementData.measuredTmp(text));
    if (g != null) {
      final total = <_Size>[];
      for (var axis = 0; axis < 2; axis++) {
        final pad = axis == 0
            ? g.padding[0] + g.padding[1]
            : g.padding[2] + g.padding[3];
        final main = (axis == 0) == g.horizontal;
        var min = pad, pref = pad, flex = 0.0;
        for (final c in cs) {
          final s = childSize(c, g, axis);
          if (main) {
            min += s.$1;
            pref += s.$2;
            flex += s.$3;
          } else {
            min = math.max(min, pad + s.$1);
            pref = math.max(pref, pad + s.$2);
            flex = math.max(flex, s.$3);
          }
        }
        if (main && cs.isNotEmpty) {
          min += g.spacing * (cs.length - 1);
          pref += g.spacing * (cs.length - 1);
        }
        total.add((min, math.max(min, pref), flex));
      }
      elements.add(
        StoryLayoutElementData(
          priority: 0,
          minimum: [total[0].$1, total[1].$1],
          preferred: [total[0].$2, total[1].$2],
          flexible: [total[0].$3, total[1].$3],
          ignoreLayout: false,
        ),
      );
    }
    if (elements.isEmpty) return const [];
    return sizes[n.path] = [
      for (var a = 0; a < 2; a++)
        (
          property(elements, a, (e) => e.minimum),
          math.max(
            property(elements, a, (e) => e.minimum),
            property(elements, a, (e) => e.preferred),
          ),
          property(elements, a, (e) => e.flexible),
        ),
    ];
  }

  void place(StoryUiLayoutNode n, StoryUiRect parent, {StoryUiRect? driven}) {
    var rect = driven ?? n.anchoredRect(parent);
    final fit = n.contentSizeFit, own = sizes[n.path];
    if (fit != null) {
      double fitted(int a, double size) {
        if (fit[a] == 0) return size;
        if (own == null) {
          throw FormatException('story_layout_fit_element:${n.path}');
        }
        return fit[a] == 1
            ? own[a].$1
            : fit[a] == 2
            ? own[a].$2
            : throw FormatException('story_layout_fit_mode:${fit[a]}');
      }

      final w = fitted(0, rect.width), h = fitted(1, rect.height);
      rect = StoryUiRect(
        rect.x + (rect.width - w) * n.rect[4][0],
        rect.y + (rect.height - h) * n.rect[4][1],
        w,
        h,
      );
    }
    rects[n.path] = rect;
    final g = group(n);
    if (g == null) {
      for (final c in children(n)) {
        place(c, rect);
      }
      return;
    }
    final cs = g.reverse ? children(n).reversed.toList() : children(n);
    final positions = [<double>[], <double>[]],
        dimensions = [<double>[], <double>[]];
    for (var a = 0; a < 2; a++) {
      final main = (a == 0) == g.horizontal,
          padStart = g.padding[a == 0 ? 0 : 2],
          padEnd = g.padding[a == 0 ? 1 : 3];
      final extent = a == 0 ? rect.width : rect.height,
          inner = extent - padStart - padEnd;
      final align = a == 0 ? (g.alignment % 3) / 2 : (g.alignment ~/ 3) / 2;
      final axisSizes = [for (final c in cs) childSize(c, g, a)];
      final gap = main ? g.spacing * math.max(0, cs.length - 1) : 0.0;
      final min = axisSizes.fold<double>(
        gap,
        (v, s) => main ? v + s.$1 : math.max(v, s.$1),
      );
      final pref = axisSizes.fold<double>(
        gap,
        (v, s) => main ? v + s.$2 : math.max(v, s.$2),
      );
      final flex = axisSizes.fold<double>(
        0,
        (v, s) => main ? v + s.$3 : math.max(v, s.$3),
      );
      final interpolation = (pref > min ? (inner - min) / (pref - min) : 0.0)
          .clamp(0.0, 1.0);
      final extra = inner > pref && flex > 0 ? (inner - pref) / flex : 0.0;
      var cursor =
          padStart +
          (main && inner > pref && flex == 0 ? (inner - pref) * align : 0);
      for (var i = 0; i < cs.length; i++) {
        final s = axisSizes[i], fixed = cs[i].rect[3][a];
        final allocated = main
            ? s.$1 + (s.$2 - s.$1) * interpolation + s.$3 * extra
            : math.max(s.$1, math.min(inner, s.$3 > 0 ? extent : s.$2));
        final drawn = g.control[a] ? allocated : fixed;
        positions[a].add(
          main
              ? cursor + (g.control[a] ? 0 : (allocated - fixed) * align)
              : padStart +
                    (inner - allocated) * align +
                    (g.control[a] ? 0 : (allocated - fixed) * align),
        );
        dimensions[a].add(drawn);
        if (main) cursor += allocated + g.spacing;
      }
    }
    for (var i = 0; i < cs.length; i++) {
      place(
        cs[i],
        rect,
        driven: StoryUiRect(
          rect.x + positions[0][i],
          rect.y + rect.height - positions[1][i] - dimensions[1][i],
          dimensions[0][i],
          dimensions[1][i],
        ),
      );
    }
  }

  for (final root in roots) {
    if (!inactivePaths.contains(root.path)) {
      measure(root, canvas);
      place(root, canvas);
    }
  }
  return StoryMeasuredUiLayout(rects);
}

/// Source four-pass active layout over retained RectTransform channels.
/// Inactive base geometry remains available without participating as elements.
StoryMeasuredUiLayout layoutRetainedMeasuredStoryUi({
  required List<StoryUiLayoutNode> roots,
  required StoryRetainedUiLayoutState state,
  required Map<String, String> pathToId,
  required Map<String, StoryGlyphLayout> measuredText,
  required Map<String, StoryLayoutGroupData> actualGroups,
  required Map<String, List<int>> actualFits,
  Map<String, List<StoryLayoutElementData>> actualElements = const {},
}) {
  final nodes = <String, StoryUiLayoutNode>{}, parents = <String, String?>{};
  void collect(StoryUiLayoutNode n, String? parent) {
    nodes[n.path] = n;
    parents[n.path] = parent;
    for (final c in n.children) {
      collect(c, n.path);
    }
  }

  for (final root in roots) {
    collect(root, null);
  }
  final rounding = Float32List(1);
  double f(double v) {
    rounding[0] = v;
    return rounding[0];
  }

  bool active(StoryUiLayoutNode n) =>
      state.basePlacements[pathToId[n.path]]!.activeInHierarchy;
  List<StoryUiLayoutNode> children(StoryUiLayoutNode n) => n.children
      .where(
        (c) =>
            active(c) &&
            !(actualElements[c.path] ?? const []).any((e) => e.ignoreLayout),
      )
      .toList();
  final totals = <String, List<_Size?>>{};
  double property(StoryUiLayoutNode n, int axis, int which) {
    if (!active(n)) return 0;
    var priority = -2147483648, value = 0.0;
    void consider(int p, double v) {
      if (v < 0 || p < priority) return;
      if (p > priority) {
        priority = p;
        value = v;
      } else {
        value = math.max(value, v);
      }
    }

    for (final e
        in actualElements[n.path] ?? const <StoryLayoutElementData>[]) {
      consider(
        e.priority,
        which == 0
            ? e.minimum[axis]
            : which == 1
            ? e.preferred[axis]
            : e.flexible[axis],
      );
    }
    final text = measuredText[n.path];
    if (text != null) {
      consider(
        0,
        which == 0
            ? 0
            : which == 1
            ? (axis == 0 ? text.width : text.height)
            : -1,
      );
    }
    final t = totals[n.path]?[axis];
    if (t != null) {
      consider(
        0,
        which == 0
            ? t.$1
            : which == 1
            ? t.$2
            : t.$3,
      );
    }
    return value;
  }

  double minimum(StoryUiLayoutNode n, int a) => property(n, a, 0);
  double preferred(StoryUiLayoutNode n, int a) =>
      math.max(minimum(n, a), property(n, a, 1));
  _Size childSize(StoryUiLayoutNode n, StoryLayoutGroupData g, int a) {
    var min = 0.0, pref = 0.0, flex = 0.0;
    if (!g.control[a]) {
      min = state.sizeDeltaOf(pathToId[n.path]!, StoryRetainedUiAxis.values[a]);
      pref = min;
    } else {
      min = minimum(n, a);
      pref = preferred(n, a);
      flex = property(n, a, 2);
    }
    if (g.expand[a]) flex = math.max(1, flex);
    return (min, pref, flex);
  }

  void calc(StoryUiLayoutNode n, int a) {
    final g = actualGroups[n.path];
    if (!(active(n) &&
        (measuredText.containsKey(n.path) ||
            (actualElements[n.path]?.isNotEmpty ?? false) ||
            g != null))) {
      return;
    }
    for (final child in n.children) {
      calc(child, a);
    }
    if (g == null) return;
    final pad = f(
      a == 0 ? g.padding[0] + g.padding[1] : g.padding[2] + g.padding[3],
    );
    final other = g.horizontal != (a == 0);
    var min = pad, pref = pad, flex = 0.0;
    final cs = children(n);
    for (final child in cs) {
      final s = childSize(child, g, a);
      if (other) {
        min = math.max(min, f(s.$1 + pad));
        pref = math.max(pref, f(s.$2 + pad));
        flex = math.max(flex, s.$3);
      } else {
        min = f(min + f(s.$1 + g.spacing));
        pref = f(pref + f(s.$2 + g.spacing));
        flex = f(flex + s.$3);
      }
    }
    if (!other && cs.isNotEmpty) {
      min = f(min - g.spacing);
      pref = f(pref - g.spacing);
    }
    totals.putIfAbsent(n.path, () => [null, null])[a] = (
      min,
      math.max(min, pref),
      flex,
    );
  }

  double extent(StoryUiLayoutNode n, int a) {
    final r = state.basePlacements[pathToId[n.path]]!.localRect;
    return a == 0 ? r.width : r.height;
  }

  void control(StoryUiLayoutNode n, int a) {
    if (!active(n)) return;
    final g = actualGroups[n.path], fit = actualFits[n.path];
    if (g == null && fit == null) return;
    if (fit != null && fit[a] != 0) {
      if (fit[a] != 1 && fit[a] != 2) {
        throw const FormatException('story_layout_fit_mode');
      }
      state.fitSelfAxis(
        nodeId: pathToId[n.path]!,
        axis: StoryRetainedUiAxis.values[a],
        fittedSize: fit[a] == 1 ? minimum(n, a) : preferred(n, a),
      );
    }
    if (g != null) {
      final size = extent(n, a),
          padStart = g.padding[a == 0 ? 0 : 2],
          padSum = f(
            a == 0 ? g.padding[0] + g.padding[1] : g.padding[2] + g.padding[3],
          );
      final align = f(
            a == 0 ? (g.alignment % 3) * 0.5 : (g.alignment ~/ 3) * 0.5,
          ),
          other = g.horizontal != (a == 0);
      double startOffset(double required) =>
          f(padStart + f(f(size - f(required + padSum)) * align));
      final cs = children(n);
      final t = totals[n.path]![a]!;
      if (other) {
        final inner = f(size - padSum);
        for (final child in cs) {
          final s = childSize(child, g, a);
          final required = math.max(
            s.$1,
            math.min(inner, s.$3 > 0 ? size : s.$2),
          );
          final start = startOffset(required),
              fixed = state.sizeDeltaOf(
                pathToId[child.path]!,
                StoryRetainedUiAxis.values[a],
              );
          state.driveChildAlongAxis(
            groupId: pathToId[n.path]!,
            childId: pathToId[child.path]!,
            axis: StoryRetainedUiAxis.values[a],
            position: g.control[a]
                ? start
                : f(start + f(f(required - fixed) * align)),
            controlledSize: g.control[a] ? required : null,
          );
        }
      } else {
        var pos = padStart, flexMul = 0.0;
        final surplus = f(size - t.$2);
        if (surplus > 0) {
          if (t.$3 == 0) {
            pos = startOffset(f(t.$2 - padSum));
          } else {
            flexMul = f(surplus / t.$3);
          }
        }
        final lerp = t.$1 != t.$2
            ? f(f(size - t.$1) / f(t.$2 - t.$1)).clamp(0.0, 1.0)
            : 0.0;
        for (final child in cs) {
          final s = childSize(child, g, a),
              allocated = f(
                f(s.$1 + f(f(s.$2 - s.$1) * lerp)) + f(s.$3 * flexMul),
              );
          final fixed = state.sizeDeltaOf(
            pathToId[child.path]!,
            StoryRetainedUiAxis.values[a],
          );
          state.driveChildAlongAxis(
            groupId: pathToId[n.path]!,
            childId: pathToId[child.path]!,
            axis: StoryRetainedUiAxis.values[a],
            position: g.control[a]
                ? pos
                : f(pos + f(f(allocated - fixed) * align)),
            controlledSize: g.control[a] ? allocated : null,
          );
          pos = f(pos + f(allocated + g.spacing));
        }
      }
    }
    for (final child in n.children) {
      control(child, a);
    }
  }

  final layoutRoots = <StoryUiLayoutNode>[];
  for (final n in nodes.values) {
    if (!active(n) ||
        (!actualGroups.containsKey(n.path) &&
            !actualFits.containsKey(n.path))) {
      continue;
    }
    var root = n;
    while (parents[root.path] != null &&
        actualGroups.containsKey(parents[root.path]) &&
        active(nodes[parents[root.path]]!)) {
      root = nodes[parents[root.path]]!;
    }
    if (!layoutRoots.contains(root)) layoutRoots.add(root);
  }
  int depth(StoryUiLayoutNode n) {
    var d = 0;
    String? p = parents[n.path];
    while (p != null) {
      d++;
      p = parents[p];
    }
    return d;
  }

  layoutRoots.sort((a, b) => depth(a).compareTo(depth(b)));
  for (final root in layoutRoots) {
    for (var axis = 0; axis < 2; axis++) {
      calc(root, axis);
      control(root, axis);
    }
  }
  final placed = state.basePlacements,
      matrices = resolveRetainedStoryUiAffine(state);
  final rects = <String, StoryUiRect>{};
  for (final entry in pathToId.entries) {
    final r = placed[entry.value]!.localRect, m = matrices[entry.value]!;
    final x = m[0] * r.x + m[2] * r.y + m[4],
        y = m[1] * r.x + m[3] * r.y + m[5];
    rects[entry.key] = StoryUiRect(x, y, r.width, r.height);
  }
  return StoryMeasuredUiLayout(rects);
}

/// In-plane source quaternion/scale -> reference double UIAffine composition.
/// Full quaternion is checked; an unsupported tilt is never silently flattened.
Map<String, List<double>> resolveRetainedStoryUiAffine(
  StoryRetainedUiLayoutState state,
) {
  final placed = state.basePlacements, out = <String, List<double>>{};
  final root = state.canvasRect;
  List<double> resolve(String id) {
    if (out[id] case final known?) return known;
    final p = placed[id]!, q = p.quaternion, s = p.scale;
    if (q[0].abs() > 1e-7 || q[1].abs() > 1e-7 || p.localPosition[2] != 0) {
      throw UnsupportedError('story_ui_affine_offplane:$id');
    }
    final degrees =
        p.eulerDegrees?[2] ?? 2 * math.atan2(q[2], q[3]) * 180 / math.pi;
    if (p.eulerDegrees case final e?) {
      if (e[0].abs() > 1e-6 || e[1].abs() > 1e-6) {
        throw UnsupportedError('story_ui_affine_euler_offplane:$id');
      }
    }
    final angle = degrees * math.pi / 180,
        c = math.cos(angle),
        sn = math.sin(angle);
    final local = [
      c * s[0],
      sn * s[0],
      -sn * s[1],
      c * s[1],
      p.localPosition[0],
      p.localPosition[1],
    ];
    final parent = p.node.parentId == null
        ? [1.0, 0.0, 0.0, 1.0, -root.x, -root.y]
        : resolve(p.node.parentId!);
    return out[id] = List.unmodifiable([
      parent[0] * local[0] + parent[2] * local[1],
      parent[1] * local[0] + parent[3] * local[1],
      parent[0] * local[2] + parent[2] * local[3],
      parent[1] * local[2] + parent[3] * local[3],
      parent[0] * local[4] + parent[2] * local[5] + parent[4],
      parent[1] * local[4] + parent[3] * local[5] + parent[5],
    ]);
  }

  for (final id in placed.keys) {
    resolve(id);
  }
  return Map.unmodifiable(out);
}
