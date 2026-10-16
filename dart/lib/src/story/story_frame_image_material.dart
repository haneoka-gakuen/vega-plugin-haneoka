import 'dart:typed_data';

import 'story_frame_source.dart';

/// The selected v25 GLES3 pass was independently inspected as texture *
/// clamped vertex RGBA, with coefficient one and no material tint uniform.
/// This classification retains its source identity independently of the
/// existing handwritten coefficient-one GPU kernel.
final class StoryFrameSourceAlphaMaterial {
  const StoryFrameSourceAlphaMaterial._();
  static final _validated = Expando<StoryFrameSourceAlphaMaterial>();

  static StoryFrameSourceAlphaMaterial fromImage(
    StoryFrameImageData image, {
    required String sourceId,
  }) {
    if (sourceId != 'v25-c0b6a1541e45-3a5d2eec9935-n653c6392') {
      throw UnsupportedError('native_frame_material_semantics');
    }
    final cached = _validated[image];
    if (cached != null) return cached;
    Never unsupported() =>
        throw UnsupportedError('native_frame_material_semantics');
    Map map(Object? value) => value is Map ? value : unsupported();
    List list(Object? value) => value is List ? value : unsupported();
    void require(bool value) {
      if (!value) unsupported();
    }

    // Actual 256x256 Sprite bytes have alpha=255 at every pixel. Filtered
    // premultiplied recovery equals straight filtering in this bound domain.
    // Other alpha domains need their own decoded/upload contract.
    require(
      image.textureHash ==
          '90ca42f78ff5e3d6f1a99c9b24f2d719c2ba3fcf70142b6ee60d9a4ea3ee2284',
    );
    final material = map(image.materialRaw),
        shader = map(image.shaderMetadata),
        pointer = map(material['m_Shader']),
        reference = map(pointer['reference']);
    const owner = 'CAB-2c5356e79f69045d7bac8b91666d9255';
    const path = '2855819893914472268';
    require(
      reference['status'] == 'resolved' &&
          reference['type'] == 'Shader' &&
          pointer['m_FileID'] is num &&
          (pointer['m_FileID'] as num) > 0 &&
          reference['serializedFile'] == owner &&
          reference['externalPath'] == 'archive:/$owner/$owner' &&
          reference['pathId'].toString() == path &&
          pointer['m_PathID'].toString() == path &&
          shader['type'] == 'Shader' &&
          shader['serializedFile'] == owner &&
          shader['pathId'].toString() == path &&
          reference['name'] == 'Mobile/Particles/Additive' &&
          shader['name'] == 'Mobile/Particles/Additive',
    );
    require(
      list(material['m_ValidKeywords']).isEmpty &&
          list(material['m_InvalidKeywords']).isEmpty &&
          material['m_CustomRenderQueue'] == -1 &&
          material['m_EnableInstancingVariants'] == false,
    );
    require(
      list(material['disabledShaderPasses'])
          .every((pass) => pass == 'MOTIONVECTORS'),
    );
    final properties = list(map(shader['properties'])['m_Props']);
    require(properties.length == 1);
    final main = map(properties.single);
    require(
      main['m_Name'] == '_MainTex' &&
          main['m_Type'] == 4 &&
          map(main['m_DefTexture'])['m_DefaultName'] == 'white',
    );
    final saved = map(material['m_SavedProperties']);
    require(
      list(saved['m_Colors']).isEmpty &&
          list(saved['m_Floats']).isEmpty &&
          list(saved['m_Ints']).isEmpty,
    );
    final textures = list(saved['m_TexEnvs']);
    require(textures.length == 1);
    final entry = list(textures.single);
    require(entry.length == 2 && entry[0] == '_MainTex');
    final texture = map(entry[1]),
        scale = map(texture['m_Scale']),
        offset = map(texture['m_Offset']),
        assigned = map(texture['m_Texture']);
    // The actual Image supplies its Sprite texture. Other ST or assigned
    // textures require a separately admitted material input contract.
    require(
      scale['x'] == 1 &&
          scale['y'] == 1 &&
          offset['x'] == 0 &&
          offset['y'] == 0 &&
          assigned['m_FileID'] == 0 &&
          assigned['m_PathID'].toString() == '0',
    );
    final subShaders = list(shader['subShaders']);
    require(subShaders.length == 1);
    final passes = list(map(subShaders.single)['m_Passes']);
    require(passes.length == 1);
    final pass = map(passes.single);
    require(pass['m_Type'] == 0);
    final state = map(pass['m_State']);
    require(state['fogMode'] == 0 && state['lighting'] == false);
    void value(String field, num expected) {
      final v = map(state[field]);
      require(v['name'] == '<noninit>' && v['val'] == expected);
    }

    value('zTest', 4);
    value('zWrite', 0);
    value('zClip', 1);
    value('culling', 0);
    value('alphaToMask', 0);
    value('offsetFactor', 0);
    value('offsetUnits', 0);
    require(state['rtSeparateBlend'] == false);
    final blend = map(state['rtBlend0']);
    for (final entry in const {
      'srcBlend': 5,
      'destBlend': 1,
      'srcBlendAlpha': 5,
      'destBlendAlpha': 1,
      'blendOp': 0,
      'blendOpAlpha': 0,
      'colMask': 15,
    }.entries) {
      final v = map(blend[entry.key]);
      require(v['name'] == '<noninit>' && v['val'] == entry.value);
    }
    for (final field in ['stencilOp', 'stencilOpFront', 'stencilOpBack']) {
      final stencil = map(state[field]);
      for (final entry in const {
        'comp': 8,
        'pass': 0,
        'fail': 0,
        'zFail': 0,
      }.entries) {
        final v = map(stencil[entry.key]);
        require(v['name'] == '<noninit>' && v['val'] == entry.value);
      }
    }
    value('stencilRef', 0);
    value('stencilReadMask', 255);
    value('stencilWriteMask', 255);
    const result = StoryFrameSourceAlphaMaterial._();
    _validated[image] = result;
    return result;
  }
}

/// Reference Color32 conversion occurs before mesh interpolation and before
/// the inherited CanvasGroup alpha is applied by the canvas projection.
List<double> storyFrameColor32(List<double> authored) {
  if (authored.length != 4 || authored.any((v) => !v.isFinite)) {
    throw const FormatException('native_frame_color32');
  }
  final scratch = Float32List(1);
  return [
    for (final component in authored)
      (() {
        scratch[0] = component.clamp(0.0, 1.0) * 255;
        final value = scratch[0], lower = value.floor();
        final fraction = value - lower;
        final byte = fraction < 0.5
            ? lower
            : fraction > 0.5
            ? lower + 1
            : lower.isEven
            ? lower
            : lower + 1;
        scratch[0] = byte / 255;
        return scratch[0];
      })(),
  ];
}
