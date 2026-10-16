import 'package:haneoka_render_profile/core.dart';

import 'story_font_data.dart';

typedef StoryGlyphPadding = SourceGlyphPadding;
typedef StoryGlyphPaddingResolver = SourceGlyphPaddingResolver;
typedef StoryGlyphQuad = SourceGlyphQuad;
typedef StoryGlyphRun = SourceGlyphRun;
typedef StoryGlyphLayout = SourceGlyphLayout;

double storyGlyphF32(double value) => sourceGlyphF32(value);

double storyGlyphSourceScale({
  required double size,
  required StoryFontData font,
  required StoryGlyphSelection selection,
}) => sourceGlyphSourceScale(size: size, font: font, selection: selection);

({List<double> rect, List<double> uv}) storyGlyphPaddedGeometry({
  required StoryFontData font,
  required StoryFontGlyph glyph,
  required StoryGlyphPadding padding,
  required double scale,
  required double penX,
  required double baseline,
}) => sourceGlyphPaddedGeometry(
  font: font,
  glyph: glyph,
  padding: padding,
  scale: scale,
  penX: penX,
  baseline: baseline,
);

StoryGlyphLayout layoutStoryGlyphRuns({
  required StoryFontBank fonts,
  required List<StoryGlyphRun> runs,
  required String letterTestText,
  required double characterSpacing,
  required double lineSpacing,
  required double maxWidth,
  required Set<int> actualBreakBeforeIndices,
  required int actualRenderedGlyphCount,
  StoryGlyphPaddingResolver? paddingResolver,
}) => layoutSourceGlyphRuns(
  fonts: fonts,
  runs: runs,
  letterTestText: letterTestText,
  characterSpacing: characterSpacing,
  lineSpacing: lineSpacing,
  maxWidth: maxWidth,
  actualBreakBeforeIndices: actualBreakBeforeIndices,
  actualRenderedGlyphCount: actualRenderedGlyphCount,
  paddingResolver: paddingResolver,
);
