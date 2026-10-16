enum StoryTextTokenKind { text, ruby, sprite, newline, styleOpen, styleClose }

final class StoryTextToken {
  const StoryTextToken(this.kind, this.value, {this.reading, this.tag});
  final StoryTextTokenKind kind;
  final String value;
  final String? reading, tag;
}

final class StoryTextMarkup {
  const StoryTextMarkup(this.tokens, this.letterTestText, this.unsupported);
  final List<StoryTextToken> tokens;

  /// Original RemoveTagsWithRuby contract: ruby reading then base, UTF-16.
  final String letterTestText;
  final List<String> unsupported;
}

/// Produces typed source markup without assigning guessed glyph sizes. Ruby
/// geometry and Sprite names are resolved against the actual source banks.
StoryTextMarkup parseStoryTextMarkup(
  String source, {
  bool normalizeCrLf = true,
}) {
  if (normalizeCrLf) source = source.replaceAll('\r\n', '\n');
  final tokens = <StoryTextToken>[], unsupported = <String>[];
  final letters = StringBuffer();
  var offset = 0;
  void addText(String value) {
    if (value.isEmpty) return;
    tokens.add(StoryTextToken(StoryTextTokenKind.text, value));
    letters.write(value);
  }

  while (offset < source.length) {
    final start = source.indexOf('<', offset);
    if (start < 0) {
      addText(source.substring(offset));
      break;
    }
    addText(source.substring(offset, start));
    final end = source.indexOf('>', start + 1);
    if (end < 0) {
      addText(source.substring(start));
      break;
    }
    final body = source.substring(start + 1, end).trim();
    final ruby = RegExp(r'^(ruby|r)\s*=\s*["\x27]?([^"\x27>]+?)["\x27]?$')
        .firstMatch(body);
    if (ruby != null) {
      final close = '</${ruby.group(1)}>';
      final finish = source.indexOf(close, end + 1);
      if (finish >= 0) {
        final base = source.substring(end + 1, finish),
            reading = ruby.group(2)!;
        tokens.add(
          StoryTextToken(StoryTextTokenKind.ruby, base, reading: reading),
        );
        if (!base.contains('\n')) letters.write(reading);
        letters.write(base);
        offset = finish + close.length;
        continue;
      }
    }
    if (body == 'ruby' || body == 'r') {
      final finish = source.indexOf('</$body>', end + 1);
      final rt = source.indexOf('<rt>', end + 1);
      final rtEnd = rt < 0 ? -1 : source.indexOf('</rt>', rt + 4);
      if (finish >= 0 && rt >= 0 && rtEnd >= 0 && rtEnd < finish) {
        final base = source.substring(end + 1, rt),
            reading = source.substring(rt + 4, rtEnd);
        tokens.add(
          StoryTextToken(StoryTextTokenKind.ruby, base, reading: reading),
        );
        letters.write(base);
        letters.write(reading);
        offset = finish + body.length + 3;
        continue;
      }
    }
    if (body.toLowerCase() == 'br' || body.toLowerCase() == 'br/') {
      tokens.add(const StoryTextToken(StoryTextTokenKind.newline, '\n'));
      letters.write('\n');
    } else if (body.toLowerCase().startsWith('sprite')) {
      tokens.add(StoryTextToken(StoryTextTokenKind.sprite, body));
    } else {
      final closing = body.startsWith('/');
      final name = (closing ? body.substring(1) : body)
          .split(RegExp(r'[=\s]'))
          .first
          .toLowerCase();
      if (const {
        'b',
        'i',
        'u',
        's',
        'color',
        'size',
        'voffset',
        'space',
        'cspace',
        'nobr',
        'align',
        'pos',
        'mark',
        'line-height',
      }.contains(name)) {
        tokens.add(
          StoryTextToken(
            closing
                ? StoryTextTokenKind.styleClose
                : StoryTextTokenKind.styleOpen,
            body,
            tag: name,
          ),
        );
      } else {
        unsupported.add(body);
      }
    }
    offset = end + 1;
  }
  return StoryTextMarkup(
    List.unmodifiable(tokens),
    removeStoryTagsWithRuby(source),
    List.unmodifiable(unsupported),
  );
}

/// StringExtensions.RemoveTagsWithRuby indexes the result as UTF-16. Its
/// reading-first branch accepts unquoted attribute ruby with no line feed;
/// other ruby spellings pass through the ordinary tag-removal branch.
String removeStoryTagsWithRuby(String source) {
  final ruby = RegExp(r'<(ruby|r)\s*=\s*([^"\x27>]+)>([^\n]*?)</\1>');
  final out = StringBuffer();
  var inTag = false;
  for (var i = 0; i < source.length; i++) {
    final unit = source[i];
    if (unit == '<') {
      final match = ruby.matchAsPrefix(source, i);
      if (match != null) {
        out.write(match.group(2));
        out.write(match.group(3));
        i = match.end - 1;
        inTag = false;
      } else {
        inTag = true;
      }
    } else if (inTag) {
      inTag = unit != '>';
    } else {
      out.write(unit);
    }
  }
  return out.toString();
}
