import 'dart:math' as math;

import 'story_emoji_data.dart';
import 'story_font_data.dart';
import 'story_glyph_layout.dart';
import 'story_text_markup.dart';
import 'story_ui_layout_data.dart';

// TMP's 0.0001f text-area bounds tolerance as its exact Single value.
const _sourceBoundsEpsilon = 0.00009999999747378752;

/// Per-component records are taken from the immutable original prefab.
final class StoryTextSourceBinding {
  StoryTextSourceBinding({
    required this.sourceHash,
    required this.componentClass,
    required this.richText,
    required this.parseControlCharacters,
    required this.wrappingMode,
    required this.uiRubyText,
    required this.ruby,
    required this.rubyMarginTop,
    required this.originMarginTop,
    this.localizeEnabled = false,
  }) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(sourceHash)) {
      throw const FormatException('story_text_binding_source');
    }
  }
  final String sourceHash, componentClass;
  final bool richText, parseControlCharacters, uiRubyText, localizeEnabled;
  final int wrappingMode;
  final StoryRubyConfig? ruby;
  final double rubyMarginTop, originMarginTop;
  factory StoryTextSourceBinding.fromRaw({
    required String sourceHash,
    required Map<String, Object?> component,
    Map<String, Object?>? uiRubyComponent,
    Map<String, Object?>? localizeComponent,
  }) {
    final script = component['m_Script'] as Map;
    final name = (script['reference'] as Map)['name'] as String;
    final margin = component['m_margin'] as Map;
    bool flag(String key) {
      final value = component[key];
      if (value != 0 && value != 1 && value != false && value != true) {
        throw FormatException('story_text_binding_$key');
      }
      return value == 1 || value == true;
    }

    final rubyClass =
        name == 'RubyTextMeshProUGUI' || name == 'RubyEmojiTextMeshProUGUI';
    return StoryTextSourceBinding(
      sourceHash: sourceHash,
      componentClass: name,
      richText: flag('m_isRichText'),
      parseControlCharacters: flag('m_parseCtrlCharacters'),
      wrappingMode: (component['m_TextWrappingMode'] as num).toInt(),
      uiRubyText: uiRubyComponent != null,
      ruby: rubyClass ? StoryRubyConfig.fromRaw(component) : null,
      rubyMarginTop: uiRubyComponent != null
          ? (uiRubyComponent['_rubyMarginTop'] as num).toDouble()
          : (margin['y'] as num).toDouble(),
      originMarginTop: (margin['y'] as num).toDouble(),
      localizeEnabled:
          localizeComponent?['_localizeEnabled'] == 1 ||
          localizeComponent?['_localizeEnabled'] == true,
    );
  }
  double marginTopFor(String source) {
    final firstLine = source.split('\n').first;
    return uiRubyText &&
            RegExp(r'<(?:ruby|r)\s*=\s*[^"\x27>]+>').hasMatch(firstLine)
        ? rubyMarginTop
        : originMarginTop;
  }
}

/// LocalizeManager.ApplyLanguageLineSpacing uses the global UI language mode.
int storyUiLanguageMode(String locale) => switch (locale) {
  'ja' => 0,
  'en' => 1,
  'zh-TW' => 2,
  'zh-CN' => 3,
  'ko' => 4,
  _ => throw UnsupportedError('story_ui_locale:$locale'),
};

double storyLocalizedLineSpacing(int uiLanguageMode) =>
    switch (uiLanguageMode) {
      0 => 0,
      1 => -100,
      2 || 3 || 4 => 5,
      _ => throw UnsupportedError('story_ui_language_mode:$uiLanguageMode'),
    };

/// Uses actual source sizes and the parent-driven text area. The host measures
/// CenterTalk at its content width, then applies the source ContentSizeFitter.
StoryGlyphLayout compileMeasuredStoryUiText({
  required String source,
  required StoryUiTextData textData,
  required StoryTextSourceBinding binding,
  required StoryFontBank fonts,
  required double width,
  required double height,
  required StoryLineBreakRules? lineBreakRules,
  StoryEmojiData? emoji,
  StoryGlyphPaddingResolver? paddingResolver,
  double fontScale = 1,
  int? uiLanguageMode,
}) {
  if (!fontScale.isFinite || fontScale <= 0) {
    throw ArgumentError.value(fontScale, 'fontScale');
  }
  StoryGlyphLayout compile(double size) => compileStoryText(
    source: source,
    fonts: fonts,
    fontSize: size * fontScale,
    color: textData.color,
    bold: textData.style & 1 != 0,
    characterSpacing: textData.characterSpacing,
    lineSpacing: binding.localizeEnabled && uiLanguageMode != null
        ? storyLocalizedLineSpacing(uiLanguageMode)
        : textData.lineSpacing,
    maxWidth: width,
    lineBreakRules: lineBreakRules,
    wrappingMode: binding.wrappingMode,
    componentClass: binding.componentClass,
    uiRubyText: binding.uiRubyText,
    richText: binding.richText,
    parseControlCharacters: binding.parseControlCharacters,
    ruby: binding.ruby,
    emoji: emoji,
    horizontalAlignment: textData.horizontal,
    paddingResolver: paddingResolver,
  );
  if (textData.raw['autoSize'] != true) return compile(textData.size);
  var lower = (textData.raw['minSize'] as num).toDouble(),
      upper = (textData.raw['maxSize'] as num).toDouble();
  var best = compile(lower);
  for (var iteration = 0; iteration < 20 && upper - lower > .05; iteration++) {
    final size = (upper + lower) / 2, result = compile(size);
    if ((width <= 0 || result.width <= width) &&
        (height <= 0 || result.height <= height)) {
      lower = size;
      best = result;
    } else {
      upper = size;
    }
  }
  final maximum = compile(upper);
  return (width <= 0 || maximum.width <= width) &&
          (height <= 0 || maximum.height <= height)
      ? maximum
      : best;
}

final class StoryRubyConfig {
  const StoryRubyConfig({
    required this.scale,
    required this.showType,
    required this.margin,
    required this.verticalOffset,
  });
  final double scale, margin;
  final int showType;

  /// Actual source TMP unit string, e.g. "1em".
  final String verticalOffset;
  factory StoryRubyConfig.fromRaw(Map<String, Object?> raw) => StoryRubyConfig(
    scale: (raw['_rubyScale'] as num).toDouble(),
    showType: (raw['_rubyShowType'] as num).toInt(),
    margin: (raw['_rubyMargin'] as num).toDouble(),
    verticalOffset: raw['_rubyVerticalOffset'] as String,
  );
}

final class StoryLineBreakRules {
  StoryLineBreakRules({
    required String leading,
    required String following,
    required this.useModernHangulLineBreakingRules,
  }) : leading = Set.unmodifiable(leading.runes),
       following = Set.unmodifiable(following.runes);
  final Set<int> leading, following;
  final bool useModernHangulLineBreakingRules;
  bool after(int current, int next) {
    if ({0xa0, 0x2007, 0x2011, 0x202f, 0x2060}.contains(current)) return false;
    if (current == 32 || current == 9 || current == 0x200b || current == 45) {
      return true;
    }
    if (_cjk(current) ||
        (_hangul(current) && !useModernHangulLineBreakingRules)) {
      return !leading.contains(current) && !following.contains(next);
    }
    return _cjk(next) && !following.contains(next);
  }
}

bool _hangul(int c) =>
    c >= 0x1100 && c <= 0x11ff ||
    c >= 0x3130 && c <= 0x318f ||
    c >= 0xa960 && c <= 0xa97f ||
    c >= 0xac00 && c <= 0xd7ff ||
    c >= 0xffa0 && c <= 0xffdc;
bool _cjk(int c) => const <(int, int)>[
  (0x2e80, 0x2fdf),
  (0x2ff0, 0x30ff),
  (0x3100, 0x312f),
  (0x3190, 0x31bf),
  (0x31c0, 0x31ff),
  (0x3400, 0x4dbf),
  (0x4e00, 0x9fff),
  (0xf900, 0xfaff),
  (0xfe10, 0xfe1f),
  (0xfe30, 0xfe6f),
  (0xff65, 0xff9f),
  (0x16fe0, 0x16fff),
  (0x1aff0, 0x1afff),
  (0x1b000, 0x1b16f),
  (0x20000, 0x2ebe0),
  (0x2f800, 0x2fa1f),
  (0x30000, 0x323af),
].any((r) => c >= r.$1 && c <= r.$2);

final class _Style {
  const _Style(
    this.size,
    this.color,
    this.bold,
    this.offset,
    this.spacing,
    this.nobr,
  );
  final double size, offset, spacing;
  final List<double> color;
  final bool bold, nobr;
  _Style copy({
    double? size,
    List<double>? color,
    bool? bold,
    double? offset,
    double? spacing,
    bool? nobr,
  }) => _Style(
    size ?? this.size,
    color ?? this.color,
    bold ?? this.bold,
    offset ?? this.offset,
    spacing ?? this.spacing,
    nobr ?? this.nobr,
  );
}

final class _Element {
  _Element(
    this.code,
    this.index,
    this.style, {
    this.selected,
    this.sprite,
    this.rubyGroup,
    this.reading = false,
  });
  final int code, index;
  final _Style style;
  final StoryGlyphSelection? selected;
  final StoryEmojiCharacter? sprite;
  final int? rubyGroup;
  final bool reading;
  double x = 0, advance = 0, overflowAdvance = 0;
}

final class _Atom {
  _Atom(
    this.elements,
    this.width,
    this.first,
    this.last,
    this.nobr, {
    this.newline = false,
  });
  final List<_Element> elements;
  final double width;
  final int first, last;
  final bool nobr, newline;
  bool get hasVisibleGlyph => elements.any(
    (e) =>
        e.sprite != null ||
        e.selected != null &&
            e.selected!.glyph.metrics[0] > 0 &&
            e.selected!.glyph.metrics[1] > 0 &&
            e.code != 32 &&
            e.code != 9,
  );
  double get overflowAdvance => elements.fold<double>(
    0,
    (width, e) => math.max(width, e.x + e.overflowAdvance),
  );
}

double _unit(String value, double size) {
  final text = value.replaceAll('"', '').replaceAll("'", '').trim();
  final match = RegExp(r'^([+-]?(?:\d+(?:\.\d*)?|\.\d+))(em|px|%)?$')
      .firstMatch(text);
  if (match == null) throw FormatException('story_text_unit:$value');
  final n = double.parse(match.group(1)!);
  return switch (match.group(2)) {
    'em' => n * size,
    '%' => n * size / 100,
    _ => n,
  };
}

List<double> _color(String value) {
  final s = value.replaceAll('"', '').replaceAll("'", '').replaceFirst('#', '');
  if (s.length != 6 && s.length != 8) {
    throw FormatException('story_text_color:$value');
  }
  final n = int.parse(s, radix: 16);
  return s.length == 6
      ? [(n >> 16 & 255) / 255, (n >> 8 & 255) / 255, (n & 255) / 255, 1]
      : [
          (n >> 24 & 255) / 255,
          (n >> 16 & 255) / 255,
          (n >> 8 & 255) / 255,
          (n & 255) / 255,
        ];
}

/// Compiles source text into actual atlas geometry. The host chooses the
/// source component/font chain and supplies TMP_Settings line-breaking data.
/// Typing length follows CountRenderedCharacters on RemoveTagsWithRuby;
/// quad indices follow the component's actual base-then-annotation stream.
StoryGlyphLayout compileStoryText({
  required String source,
  required StoryFontBank fonts,
  required double fontSize,
  required List<double> color,
  required bool bold,
  required double characterSpacing,
  required double lineSpacing,
  required double maxWidth,
  required StoryLineBreakRules? lineBreakRules,
  required int wrappingMode,
  required String componentClass,
  required bool uiRubyText,
  required bool richText,
  required bool parseControlCharacters,
  StoryRubyConfig? ruby,
  StoryEmojiData? emoji,
  int horizontalAlignment = 1,
  StoryGlyphPaddingResolver? paddingResolver,
}) {
  if (fontSize <= 0 ||
      !fontSize.isFinite ||
      maxWidth < 0 ||
      !maxWidth.isFinite ||
      color.length != 4) {
    throw const FormatException('story_text_compile_input');
  }
  final rubyComponent =
      componentClass == 'RubyTextMeshProUGUI' ||
      componentClass == 'RubyEmojiTextMeshProUGUI';
  final emojiComponent = componentClass == 'RubyEmojiTextMeshProUGUI';
  if (rubyComponent && uiRubyText && ruby == null) {
    throw const FormatException('story_text_ruby_config');
  }
  source = source.replaceAll('\r\n', '\n');
  final letterTestText = richText ? removeStoryTagsWithRuby(source) : source;
  if (emojiComponent && parseControlCharacters) {
    source = source.replaceAll(r'\n', '\n').replaceAll(r'\t', '\t');
  }
  final markup = richText
      ? parseStoryTextMarkup(source, normalizeCrLf: false)
      : StoryTextMarkup(
          [StoryTextToken(StoryTextTokenKind.text, source)],
          source,
          const [],
        );
  final unsupported = <String>[...markup.unsupported], missing = <int>{};
  final primary = fonts.fonts.first;
  final atoms = <_Atom>[];
  var index = 0, group = 0;
  var sourceCursor = 0.0, rubyCursor = 0.0;
  var style = _Style(fontSize, color, bold, 0, characterSpacing, false);
  final styles = <String, List<_Style>>{};
  final emojiSequences =
      richText &&
      (emojiComponent ||
          !rubyComponent &&
              (source.contains('\ufe0e') ||
                  source.contains('\ufe0f') ||
                  source.contains('\u200d')));
  if (![0, 1].contains(wrappingMode)) {
    unsupported.add('source_wrapping_mode:$wrappingMode');
  }
  bool breakAfter(int current, int next) {
    if (lineBreakRules != null) return lineBreakRules.after(current, next);
    if (_cjk(current) || _cjk(next) || _hangul(current)) {
      if (!unsupported.contains('source_line_break_rules')) {
        unsupported.add('source_line_break_rules');
      }
      return false;
    }
    return current == 32 || current == 9 || current == 45 || current == 0x200b;
  }

  _Element element(
    int code,
    _Style s, {
    StoryEmojiCharacter? sprite,
    int? group,
    bool reading = false,
  }) {
    final selected = sprite == null ? fonts.select(code) : null;
    // TMP font lookup precedes sprite unicode lookup.
    sprite ??= selected == null && richText ? emoji?.byUnicode[code] : null;
    final e = _Element(
      code,
      index++,
      s,
      selected: selected,
      sprite: sprite,
      rubyGroup: group,
      reading: reading,
    );
    if (sprite != null) {
      final g = sprite.glyph;
      final scale =
          s.size /
          primary.size *
          primary.scale *
          primary.ascent /
          g.metrics[1] *
          sprite.scale *
          g.scale;
      e.advance = g.metrics[4] * scale + s.spacing * s.size / 100;
      e.overflowAdvance = g.metrics[4] * scale;
    } else if (selected != null) {
      final f = selected.font, g = selected.glyph;
      final scale =
          s.size / f.size * f.scale * g.scale * selected.characterScale;
      e.advance =
          g.metrics[4] * scale +
          (s.spacing + (s.bold ? f.boldSpacing : 0)) * s.size / 100;
      e.overflowAdvance = g.metrics[4] * scale;
    } else if (code != 10 && code != 13 && code != 0x200b) {
      missing.add(code);
    }
    return e;
  }

  List<_Element> textElements(
    String text,
    _Style s, {
    int? group,
    bool reading = false,
  }) {
    final result = <_Element>[];
    for (var offset = 0; offset < text.length;) {
      final sequence = emojiSequences ? emoji?.sequenceAt(text, offset) : null;
      if (sequence != null) {
        result.add(
          element(
            sequence.$1.unicode,
            s,
            sprite: sequence.$1,
            group: group,
            reading: reading,
          ),
        );
        offset = sequence.$2;
      } else {
        final code = text.substring(offset).runes.first;
        result.add(element(code, s, group: group, reading: reading));
        offset += code > 0xffff ? 2 : 1;
      }
    }
    return result;
  }

  void addText(String text) {
    for (final e in textElements(text, style)) {
      atoms.add(
        _Atom(
          [e],
          e.advance,
          e.code,
          e.code,
          style.nobr,
          newline:
              e.code == 10 ||
              e.code == 11 ||
              e.code == 0x2028 ||
              e.code == 0x2029,
        ),
      );
      sourceCursor += e.advance;
    }
  }

  for (final token in markup.tokens) {
    switch (token.kind) {
      case StoryTextTokenKind.text:
        addText(token.value);
      case StoryTextTokenKind.newline:
        addText('\n');
      case StoryTextTokenKind.sprite:
        final name = RegExp(r'name\s*=\s*["\x27]([^"\x27]+)["\x27]')
            .firstMatch(token.value)
            ?.group(1);
        final sprite = emoji?.byName[name];
        if (sprite == null) {
          unsupported.add('source_sprite:${token.value}');
          index++;
        } else {
          final e = element(sprite.unicode, style, sprite: sprite);
          atoms.add(_Atom([e], e.advance, e.code, e.code, style.nobr));
        }
      case StoryTextTokenKind.ruby:
        if (!rubyComponent || !uiRubyText) {
          addText(token.value);
          addText(token.reading ?? '');
          break;
        }
        final r = ruby!;
        if (r.scale <= 0 || ![0, 1, 2].contains(r.showType)) {
          throw const FormatException('story_text_ruby_parameters');
        }
        final base = textElements(token.value, style, group: group);
        final reading = textElements(
          token.reading ?? '',
          style.copy(
            size: style.size * r.scale,
            offset: style.offset - _unit(r.verticalOffset, style.size),
          ),
          group: group,
          reading: true,
        );
        final bw = base.fold<double>(0, (n, e) => n + e.advance),
            rw = reading.fold<double>(0, (n, e) => n + e.advance);
        final centeredReading = (bw - rw) / 2;
        var pre = r.showType == 0 && rw > bw ? (rw - bw) / 2 : 0.0;
        if (r.showType == 2) {
          final start = sourceCursor + centeredReading;
          if (start < rubyCursor) pre = rubyCursor - start;
          rubyCursor =
              math.max(start, rubyCursor) + rw + (pre > 0 ? r.margin : 0);
        }
        final width = bw + pre;
        var x = pre;
        for (final e in base) {
          e.x = x;
          x += e.advance;
        }
        x = pre + centeredReading;
        for (final e in reading) {
          e.x = x;
          x += e.advance;
        }
        if (base.any((e) => e.code == 10) || reading.any((e) => e.code == 10)) {
          unsupported.add('ruby_multiline');
        }
        atoms.add(
          _Atom(
            [...base, ...reading],
            width,
            base.isEmpty ? 0 : base.first.code,
            reading.isNotEmpty
                ? reading.last.code
                : base.isEmpty
                ? 0
                : base.last.code,
            style.nobr,
          ),
        );
        sourceCursor += r.showType == 0 ? (rw > bw ? bw : rw) : width;
        group++;
      case StoryTextTokenKind.styleOpen:
        final tag = token.tag!;
        styles.putIfAbsent(tag, () => []).add(style);
        final eq = token.value.indexOf('='),
            value = eq < 0 ? '' : token.value.substring(eq + 1);
        switch (tag) {
          case 'b':
            style = style.copy(bold: true);
          case 'size':
            style = style.copy(size: _unit(value, fontSize));
          case 'color':
            style = style.copy(color: _color(value));
          case 'voffset':
            style = style.copy(offset: -_unit(value, style.size));
          case 'cspace':
            style = style.copy(
              spacing: _unit(value, style.size) * 100 / style.size,
            );
          case 'nobr':
            style = style.copy(nobr: true);
          case 'space':
            atoms.add(_Atom([], _unit(value, style.size), 0, 0, true));
          default:
            unsupported.add('source_style:$tag');
        }
      case StoryTextTokenKind.styleClose:
        final stack = styles[token.tag];
        if (stack != null && stack.isNotEmpty) style = stack.removeLast();
    }
  }
  final lines = <List<_Atom>>[[]];
  var lineWidth = 0.0, lastBreak = -1;
  for (var i = 0; i < atoms.length; i++) {
    final a = atoms[i];
    if (a.newline) {
      lines.last.add(a);
      lines.add([]);
      lineWidth = 0;
      lastBreak = -1;
      continue;
    }
    if (wrappingMode == 1 &&
        maxWidth > 0 &&
        a.hasVisibleGlyph &&
        lineWidth + a.overflowAdvance > maxWidth + _sourceBoundsEpsilon &&
        lines.last.isNotEmpty) {
      final split = lastBreak >= 0 ? lastBreak + 1 : lines.last.length;
      final tail = lines.last.sublist(split);
      lines.last.removeRange(split, lines.last.length);
      lines.add(tail);
      lineWidth = tail.fold<double>(0, (n, v) => n + v.width);
      lastBreak = -1;
      for (var j = 0; j + 1 < tail.length; j++) {
        if (!tail[j].nobr && breakAfter(tail[j].last, tail[j + 1].first)) {
          lastBreak = j;
        }
      }
    }
    lines.last.add(a);
    lineWidth += a.width;
    if (wrappingMode == 1 &&
        i + 1 < atoms.length &&
        !a.nobr &&
        breakAfter(a.last, atoms[i + 1].first)) {
      lastBreak = lines.last.length - 1;
    }
  }
  final quads = <StoryGlyphQuad>[], baselines = <double>[];
  final baseScale = fontSize / primary.size * primary.scale;
  final lineGap =
      (primary.lineHeight - primary.ascent + primary.descent) * baseScale;
  final lineMetrics = <(double, double)>[];
  for (final line in lines) {
    var ascent = double.negativeInfinity, descent = double.infinity;
    for (final atom in line) {
      for (final e in atom.elements) {
        final f = e.selected?.font ?? primary;
        final scale = e.sprite != null
            ? e.style.size / primary.size * primary.scale
            : e.style.size /
                  f.size *
                  f.scale *
                  (e.selected?.glyph.scale ?? 1) *
                  (e.selected?.characterScale ?? 1);
        final asc = f.ascent * scale, desc = f.descent * scale;
        ascent = math.max(ascent, math.max(asc, asc - e.style.offset));
        descent = math.min(descent, math.min(desc, desc - e.style.offset));
      }
    }
    lineMetrics.add((
      ascent.isFinite ? ascent : primary.ascent * baseScale,
      descent.isFinite ? descent : primary.descent * baseScale,
    ));
  }
  var width = 0.0;
  for (var row = 0; row < lines.length; row++) {
    final line = lines[row], w = line.fold<double>(0, (n, a) => n + a.width);
    width = math.max(width, w);
    final baseline = row == 0
        ? lineMetrics[row].$1
        : baselines.last -
              lineMetrics[row - 1].$2 +
              lineMetrics[row].$1 +
              lineGap +
              lineSpacing * fontSize / 100;
    baselines.add(baseline);
    var x = horizontalAlignment == 2 && maxWidth > 0
        ? (maxWidth - w) / 2
        : horizontalAlignment == 4 && maxWidth > 0
        ? maxWidth - w
        : 0.0;
    for (final atom in line) {
      for (final e in atom.elements) {
        if (e.code == 10 ||
            e.code == 13 ||
            e.code == 32 ||
            e.code == 9 ||
            e.code == 0x200b) {
          continue;
        }
        final sprite = e.sprite, selection = e.selected;
        if (sprite == null && selection == null) continue;
        final g = sprite?.glyph ?? selection!.glyph;
        if (g.metrics[0] <= 0 || g.metrics[1] <= 0) continue;
        final f = selection?.font;
        final scale = sprite == null && paddingResolver != null
            ? storyGlyphSourceScale(
                size: e.style.size,
                font: f!,
                selection: selection!,
              )
            : sprite != null
            ? e.style.size /
                  primary.size *
                  primary.scale *
                  primary.ascent /
                  g.metrics[1] *
                  sprite.scale *
                  g.scale
            : e.style.size /
                  f!.size *
                  f.scale *
                  g.scale *
                  selection!.characterScale;
        final p = sprite != null ? 0.0 : f!.padding;
        final aw = sprite != null ? emoji!.atlasWidth : f!.atlasWidth,
            ah = sprite != null ? emoji!.atlasHeight : f!.atlasHeight;
        final y = baseline + e.style.offset;
        final geometry = sprite != null || paddingResolver == null
            ? null
            : storyGlyphPaddedGeometry(
                font: f!,
                glyph: g,
                padding: paddingResolver(f, e.style.bold),
                scale: scale,
                penX: x + e.x,
                baseline: y,
              );
        quads.add(
          StoryGlyphQuad(
            unicode: e.code,
            glyphIndex: g.index,
            fontId: sprite != null ? 'sprite' : f!.id,
            atlasAsset: sprite != null
                ? emoji!.atlasAsset
                : f!.atlasAssets[g.atlasPage],
            atlasPage: g.atlasPage,
            renderedIndex: e.index,
            rect: List.unmodifiable(
              geometry?.rect ??
                  [
                    x + e.x + (g.metrics[2] - p) * scale,
                    y - (g.metrics[3] + p) * scale,
                    (g.metrics[0] + p * 2) * scale,
                    (g.metrics[1] + p * 2) * scale,
                  ],
            ),
            uvTopLeft: List.unmodifiable(
              geometry?.uv ??
                  [
                    (g.rect[0] - p) / aw,
                    1 - (g.rect[1] + g.rect[3] + p) / ah,
                    (g.rect[2] + p * 2) / aw,
                    (g.rect[3] + p * 2) / ah,
                  ],
            ),
            baseline: y,
            color: List.unmodifiable(
              sprite != null ? [1.0, 1.0, 1.0, color[3]] : e.style.color,
            ),
            bold: e.style.bold,
            glyphScale: scale,
            rubyGroup: e.rubyGroup,
            isRuby: e.reading,
          ),
        );
      }
      x += atom.width;
    }
  }
  // Count from the typing helper's input, distinct from the geometry stream.
  var countText = letterTestText;
  if (emojiComponent && parseControlCharacters) {
    countText = countText.replaceAll(r'\n', '\n').replaceAll(r'\t', '\t');
  }
  var count = 0;
  for (var offset = 0; offset < countText.length;) {
    final sequence = emojiSequences
        ? emoji?.sequenceAt(countText, offset)
        : null;
    if (sequence != null) {
      count++;
      offset = sequence.$2;
      continue;
    }
    final code = countText.substring(offset).runes.first;
    count++;
    offset += code > 0xffff ? 2 : 1;
  }
  return StoryGlyphLayout(
    quads: List.unmodifiable(quads),
    renderedGlyphCount: count,
    meshCharacterCount: index,
    letterTestText: letterTestText,
    width: width,
    height: atoms.isEmpty ? 0 : baselines.last - lineMetrics.last.$2,
    lineBaselines: List.unmodifiable(atoms.isEmpty ? <double>[] : baselines),
    missingGlyphs: Set.unmodifiable(missing),
    unsupported: List.unmodifiable(unsupported.toSet()),
  );
}
