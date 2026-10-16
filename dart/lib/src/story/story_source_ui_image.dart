import 'dart:math' as math;
import 'dart:typed_data';

import 'package:haneoka_render_profile/core.dart';

import 'story_image_mesh.dart';
import 'story_ui_layout_data.dart';
import 'story_measured_ui_layout.dart';

double _n(Object? value, [double fallback = 0]) =>
    (value as num?)?.toDouble() ?? fallback;
bool _on(Object? value) => value == true || value == 1;

StoryLayoutElementData sourceUiImageLayoutElement({
  required Map<String, Object?> image,
  required Map<String, Object?> sprite,
  required double referencePixelsPerUnit,
  List<double>? externalSpriteSize,
}) {
  if (externalSpriteSize != null) {
    return StoryLayoutElementData(
      priority: 0,
      minimum: const [0, 0],
      preferred: externalSpriteSize,
      flexible: const [-1, -1],
      ignoreLayout: false,
    );
  }
  final rect = sprite['m_Rect'] as Map, border = sprite['m_Border'] as Map;
  final ppu =
      _n(sprite['m_PixelsToUnits']) /
      referencePixelsPerUnit *
      _n(image['m_PixelsPerUnitMultiplier']);
  final sliced = image['m_Type'] == 1 || image['m_Type'] == 2;
  return StoryLayoutElementData(
    priority: 0,
    minimum: const [0, 0],
    preferred: [
      (sliced ? _n(border['x']) + _n(border['z']) : _n(rect['width'])) / ppu,
      (sliced ? _n(border['y']) + _n(border['w']) : _n(rect['height'])) / ppu,
    ],
    flexible: const [-1, -1],
    ignoreLayout: false,
  );
}

/// Source component-to-geometry bridge shared by retained UI consumers.
/// Image/Sprite/Texture records remain separate; output UVs address the complete
/// Texture2D, including the exact packed trim. Geometry subdivision is delegated
/// to the common Image mesh builder.
ProjectedMesh buildSourceUiImageMesh({
  required Map<String, Object?> image,
  required Map<String, Object?>? sprite,
  required Map<String, Object?>? texture,
  required StoryUiRect localRect,
  required double canvasWidth,
  required double canvasHeight,
  required double referencePixelsPerUnit,
  required List<double> pivot,
  List<double>? externalSpriteSize,
  double? fillAmount,
  bool wholeTextureCoordinates = true,
}) {
  final rect = sprite?['m_Rect'] as Map?;
  final render = sprite?['m_RD'] as Map?;
  final trim = render?['textureRect'] as Map?;
  final offset = render?['textureRectOffset'] as Map?;
  final border = sprite?['m_Border'] as Map?;
  final color = image['m_Color'] as Map;
  final external = externalSpriteSize != null;
  final size =
      externalSpriteSize ?? [_n(rect?['width'], 1), _n(rect?['height'], 1)];
  final sourceType = external ? 0 : (image['m_Type'] as num).toInt();
  var target = StoryUiRect(
    localRect.x,
    -localRect.y - localRect.height,
    localRect.width,
    localRect.height,
  );
  if (sourceType == 0 &&
      _on(image['m_PreserveAspect']) &&
      (sprite != null || external)) {
    final scale = math.min(target.width / size[0], target.height / size[1]);
    final width = size[0] * scale, height = size[1] * scale;
    target = StoryUiRect(
      target.x + (target.width - width) * pivot[0],
      target.y + (target.height - height) * (1 - pivot[1]),
      width,
      height,
    );
  }
  var amount = 1.0, axis = -1, origin = 0;
  if (sourceType == 3) {
    axis = (image['m_FillMethod'] as num).toInt();
    origin = (image['m_FillOrigin'] as num).toInt();
    if (axis != 0 && axis != 1) throw UnsupportedError('source_ui_radial_fill');
    amount = (fillAmount ?? _n(image['m_FillAmount'])).clamp(0.0, 1.0);
    target = axis == 0
        ? StoryUiRect(
            target.x + (origin == 1 ? target.width * (1 - amount) : 0),
            target.y,
            target.width * amount,
            target.height,
          )
        : StoryUiRect(
            target.x,
            target.y + (origin == 0 ? target.height * (1 - amount) : 0),
            target.width,
            target.height * amount,
          );
  }
  final mesh = buildStoryImageMesh(
    rect: target,
    canvasWidth: canvasWidth,
    canvasHeight: canvasHeight,
    color: [
      for (final channel in ['r', 'g', 'b', 'a']) _n(color[channel]),
    ],
    imageType: sourceType == 3 ? 0 : sourceType,
    spriteSize: size,
    trimmedPixels: StoryUiRect(
      external ? 0 : _n(offset?['x']),
      external ? 0 : _n(offset?['y']),
      external ? size[0] : _n(trim?['width'], size[0]),
      external ? size[1] : _n(trim?['height'], size[1]),
    ),
    border: StoryImageBorders(
      left: _n(border?['x']),
      bottom: _n(border?['y']),
      right: _n(border?['z']),
      top: _n(border?['w']),
    ),
    pixelsPerUnit: sprite == null || external
        ? 1
        : _n(sprite['m_PixelsToUnits']) /
              referencePixelsPerUnit *
              _n(image['m_PixelsPerUnitMultiplier']),
    fillCenter: _on(image['m_FillCenter']),
  );
  if (sprite == null || external || !wholeTextureCoordinates) return mesh;
  if ((render!['settingsRaw'] as num).toInt() != 64) {
    throw UnsupportedError('source_ui_packed_sprite_rotation');
  }
  if (texture == null) throw const FormatException('source_ui_texture_record');
  final width = _n(texture['m_Width']), height = _n(texture['m_Height']);
  final vertices = Float32List.fromList(mesh.vertices);
  for (var i = 0; i < vertices.length; i += 10) {
    if (axis == 0)
      vertices[i + 4] =
          (origin == 1 ? 1 - amount : 0) + vertices[i + 4] * amount;
    if (axis == 1)
      vertices[i + 5] =
          (origin == 0 ? 1 - amount : 0) + vertices[i + 5] * amount;
    vertices[i + 4] =
        (_n(trim!['x']) + vertices[i + 4] * _n(trim['width'])) / width;
    vertices[i + 5] =
        1 -
        (_n(trim['y']) + (1 - vertices[i + 5]) * _n(trim['height'])) / height;
  }
  return ProjectedMesh(vertices, mesh.indices);
}
