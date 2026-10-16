import 'story_font_data.dart';

enum StorySdfMaterialRecipe {
  face,
  faceOutline,
  faceUnderlay,
  faceOutlineUnderlay,
}

/// Immutable source parameters for the host's independently written SDF pass.
/// Floats and colors retain every exported material property. Required fields
/// follow the active face/outline/underlay recipe; absence never supplies a
/// material default. This packet contains no shader or coverage expressions.
final class StorySdfMaterialData {
  StorySdfMaterialData._({
    required this.sourceMaterialKey,
    required this.sourcePath,
    required this.sourceHash,
    required this.fontId,
    required this.fontSourceHash,
    required this.recipe,
    required this.floats,
    required this.colors,
    required this.keywords,
    required this.requiredFloats,
    required this.requiredColors,
    required this.unsupported,
  });

  final String sourceMaterialKey, sourcePath, sourceHash;
  final String fontId, fontSourceHash;
  final StorySdfMaterialRecipe recipe;
  final Map<String, double> floats;
  final Map<String, List<double>> colors;
  final List<String> keywords;
  final Set<String> requiredFloats, requiredColors;
  final List<String> unsupported;
  bool get usable => unsupported.isEmpty;
  bool get outlineEnabled => keywords.contains('OUTLINE_ON');
  bool get underlayEnabled => keywords.contains('UNDERLAY_ON');

  factory StorySdfMaterialData.fromRaw(
    Map<String, Object?> actualMaterial, {
    required StoryFontData actualFont,
    required String sourceMaterialKey,
    required String sourcePath,
    required String sourceHash,
  }) {
    if (sourceMaterialKey.isEmpty ||
        sourcePath.isEmpty ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(sourceHash) ||
        actualMaterial['floats'] is! Map ||
        actualMaterial['colors'] is! Map ||
        actualMaterial['keywords'] is! List) {
      throw const FormatException('story_sdf_material_source');
    }
    final floats = <String, double>{};
    for (final entry in (actualMaterial['floats'] as Map).entries) {
      if (entry.key is! String ||
          entry.value is! num ||
          !(entry.value as num).isFinite) {
        throw const FormatException('story_sdf_material_float');
      }
      floats[entry.key as String] = (entry.value as num).toDouble();
    }
    final colors = <String, List<double>>{};
    for (final entry in (actualMaterial['colors'] as Map).entries) {
      final value = entry.value;
      if (entry.key is! String ||
          value is! List ||
          value.length != 4 ||
          value.any((v) => v is! num || !v.isFinite)) {
        throw const FormatException('story_sdf_material_color');
      }
      colors[entry.key as String] = List.unmodifiable(
        value.cast<num>().map((v) => v.toDouble()),
      );
    }
    final rawKeywords = actualMaterial['keywords'] as List;
    if (rawKeywords.any((v) => v is! String || v.isEmpty)) {
      throw const FormatException('story_sdf_material_keywords');
    }
    final keywords = List<String>.unmodifiable(rawKeywords.cast<String>());
    final outline = keywords.contains('OUTLINE_ON');
    final underlay = keywords.contains('UNDERLAY_ON');
    final recipe = outline
        ? underlay
              ? StorySdfMaterialRecipe.faceOutlineUnderlay
              : StorySdfMaterialRecipe.faceOutline
        : underlay
        ? StorySdfMaterialRecipe.faceUnderlay
        : StorySdfMaterialRecipe.face;
    final unsupported = <String>[];
    for (final keyword in keywords) {
      if (keyword != 'OUTLINE_ON' && keyword != 'UNDERLAY_ON') {
        unsupported.add('source_material_keyword:$keyword');
      }
    }
    if (!sourceMaterialKey.startsWith('${actualFont.id}:') &&
        !sourceMaterialKey.startsWith('${actualFont.id}-')) {
      unsupported.add('source_material_font_identity');
    }
    final requiredFloats = <String>{
      '_FaceDilate',
      '_GradientScale',
      '_ScaleRatioA',
      '_WeightNormal',
      '_WeightBold',
      '_TextureWidth',
      '_TextureHeight',
      '_Sharpness',
      '_ScaleX',
      '_ScaleY',
      if (outline) ...{'_OutlineWidth', '_OutlineSoftness'},
      if (underlay) ...{
        '_ScaleRatioC',
        '_UnderlayDilate',
        '_UnderlayOffsetX',
        '_UnderlayOffsetY',
        '_UnderlaySoftness',
      },
    };
    final requiredColors = <String>{
      '_FaceColor',
      if (outline) '_OutlineColor',
      if (underlay) '_UnderlayColor',
    };
    for (final name in requiredFloats) {
      if (!floats.containsKey(name)) {
        unsupported.add('source_material_float_required:$name');
      }
    }
    for (final name in requiredColors) {
      if (!colors.containsKey(name)) {
        unsupported.add('source_material_color_required:$name');
      }
    }
    if (floats.containsKey('_TextureWidth') &&
            floats['_TextureWidth'] != actualFont.atlasWidth ||
        floats.containsKey('_TextureHeight') &&
            floats['_TextureHeight'] != actualFont.atlasHeight) {
      unsupported.add('source_material_atlas_dimensions');
    }
    if (floats.containsKey('_GradientScale') &&
        floats['_GradientScale']! <= 0) {
      unsupported.add('source_material_gradient_scale');
    }
    if (floats['_ScaleX'] == 0 || floats['_ScaleY'] == 0) {
      unsupported.add('source_material_zero_scale');
    }
    if (floats.containsKey('_ShaderFlags') && floats['_ShaderFlags'] != 0) {
      unsupported.add('source_material_shader_flags');
    }
    return StorySdfMaterialData._(
      sourceMaterialKey: sourceMaterialKey,
      sourcePath: sourcePath,
      sourceHash: sourceHash,
      fontId: actualFont.id,
      fontSourceHash: actualFont.sourceHash,
      recipe: recipe,
      floats: Map.unmodifiable(floats),
      colors: Map.unmodifiable(colors),
      keywords: keywords,
      requiredFloats: Set.unmodifiable(requiredFloats),
      requiredColors: Set.unmodifiable(requiredColors),
      unsupported: List.unmodifiable(unsupported),
    );
  }

  double requireFloat(String name) =>
      floats[name] ??
      (throw UnsupportedError('source_material_float_required:$name'));
  List<double> requireColor(String name) =>
      colors[name] ??
      (throw UnsupportedError('source_material_color_required:$name'));

  double get faceDilate => requireFloat('_FaceDilate');
  double get gradientScale => requireFloat('_GradientScale');
  double get scaleRatioA => requireFloat('_ScaleRatioA');
  double get weightNormal => requireFloat('_WeightNormal');
  double get weightBold => requireFloat('_WeightBold');
  double get textureWidth => requireFloat('_TextureWidth');
  double get textureHeight => requireFloat('_TextureHeight');
  double get sharpness => requireFloat('_Sharpness');
  double get scaleX => requireFloat('_ScaleX');
  double get scaleY => requireFloat('_ScaleY');
  List<double> get faceColor => requireColor('_FaceColor');

  /// Optional inactive-recipe fields retain their actual value when present.
  double? get outlineWidth => floats['_OutlineWidth'];
  double? get outlineSoftness => floats['_OutlineSoftness'];
  List<double>? get outlineColor => colors['_OutlineColor'];
  double? get scaleRatioC => floats['_ScaleRatioC'];
  double? get underlayDilate => floats['_UnderlayDilate'];
  double? get underlayOffsetX => floats['_UnderlayOffsetX'];
  double? get underlayOffsetY => floats['_UnderlayOffsetY'];
  double? get underlaySoftness => floats['_UnderlaySoftness'];
  List<double>? get underlayColor => colors['_UnderlayColor'];
}
