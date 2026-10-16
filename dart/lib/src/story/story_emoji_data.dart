import 'story_font_data.dart';

/// Actual TMP sprite character and glyph tables, with the source texture key.
final class StoryEmojiCharacter {
  const StoryEmojiCharacter(this.name, this.unicode, this.scale, this.glyph);
  final String name;
  final int unicode;
  final double scale;
  final StoryFontGlyph glyph;
}

final class StoryEmojiData {
  StoryEmojiData._(
    this.sourceHash,
    this.atlasAsset,
    this.atlasWidth,
    this.atlasHeight,
    this.byName,
    this.byUnicode,
    this.sequences,
  );
  final String sourceHash, atlasAsset;
  final double atlasWidth, atlasHeight;
  final Map<String, StoryEmojiCharacter> byName;
  final Map<int, StoryEmojiCharacter> byUnicode;
  final Map<String, StoryEmojiCharacter> sequences;

  /// [raw] is NATIVE-GLYPH-EMOJI-RAW-DATA.json. Dimensions come from the
  /// decoded source texture; no sprite-sheet size is inferred from entries.
  factory StoryEmojiData.fromRaw(
    Map<String, Object?> raw, {
    required String actualAtlasAsset,
    required double actualAtlasWidth,
    required double actualAtlasHeight,
  }) {
    final hash = raw['sourceHash'];
    if (hash is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash) ||
        actualAtlasAsset.isEmpty ||
        actualAtlasWidth <= 0 ||
        actualAtlasHeight <= 0) {
      throw const FormatException('story_emoji_source');
    }
    double number(Map m, String k) {
      final value = m[k];
      if (value is! num || !value.isFinite) {
        throw FormatException('story_emoji_$k');
      }
      return value.toDouble();
    }

    final glyphs = <int, StoryFontGlyph>{};
    for (final g in (raw['glyphs'] as List).cast<Map>()) {
      final metrics = g['m_Metrics'] as Map, rect = g['m_GlyphRect'] as Map;
      final index = number(g, 'm_Index').toInt();
      glyphs[index] = StoryFontGlyph(
        index: index,
        atlasPage: number(g, 'm_AtlasIndex').toInt(),
        rect: List.unmodifiable(
          ['m_X', 'm_Y', 'm_Width', 'm_Height'].map((k) => number(rect, k)),
        ),
        metrics: List.unmodifiable(
          [
            'm_Width',
            'm_Height',
            'm_HorizontalBearingX',
            'm_HorizontalBearingY',
            'm_HorizontalAdvance',
          ].map((k) => number(metrics, k)),
        ),
        scale: number(g, 'm_Scale'),
      );
    }
    final names = <String, StoryEmojiCharacter>{},
        codes = <int, StoryEmojiCharacter>{};
    final sequences = <String, StoryEmojiCharacter>{};
    for (final c in (raw['characters'] as List).cast<Map>()) {
      final name = c['m_Name'] as String,
          unicode = number(c, 'm_Unicode').toInt();
      final glyph = glyphs[number(c, 'm_GlyphIndex').toInt()];
      if (glyph == null || glyph.atlasPage != 0) {
        throw const FormatException('story_emoji_glyph');
      }
      final character = StoryEmojiCharacter(
        name,
        unicode,
        number(c, 'm_Scale'),
        glyph,
      );
      names.putIfAbsent(name, () => character);
      codes.putIfAbsent(unicode, () => character);
      if (name.contains('-')) {
        final sequence = String.fromCharCodes(
          name.split('-').map((p) => int.parse(p, radix: 16)),
        );
        sequences.putIfAbsent(sequence, () => character);
      }
    }
    return StoryEmojiData._(
      hash,
      actualAtlasAsset,
      actualAtlasWidth,
      actualAtlasHeight,
      Map.unmodifiable(names),
      Map.unmodifiable(codes),
      Map.unmodifiable(sequences),
    );
  }

  /// Longest source sequence at a UTF-16 cursor. Prefix scanning deliberately
  /// does not backtrack to a shorter complete sequence.
  (StoryEmojiCharacter, int)? sequenceAt(String text, int offset) {
    var end = offset;
    var prefix = '';
    while (end < text.length) {
      final candidate = prefix + text[end];
      if (!sequences.keys.any((s) => s.startsWith(candidate))) break;
      prefix = candidate;
      end++;
    }
    final result = sequences[prefix];
    return result == null ? null : (result, end);
  }
}
