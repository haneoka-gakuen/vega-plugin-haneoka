import 'dart:typed_data';

import 'package:vega_plugin_cubism/model_frame.dart' show NativeCubismDrawable;
import 'package:vega_plugin_cubism/masking.dart';

import 'package:haneoka_render_profile/core.dart';

/// Evaluated Native Core drawable data. No model is represented by a picture.
export 'package:vega_plugin_cubism/model_frame.dart' show NativeCubismDrawable;

final _topologySnapshots = Expando<TriangleTopology>(
  'cubism triangle topology',
);

TriangleTopology _topologySnapshot(Uint16List source) {
  final cached = _topologySnapshots[source];
  if (cached != null && cached.matches(source)) return cached;
  return _topologySnapshots[source] = TriangleTopology(source);
}

final class NativeCubismGpuPasses {
  NativeCubismGpuPasses(this.maskPasses, this.draws, this.targets);
  final List<NativePass> maskPasses;
  final List<NativeDraw> draws;
  final Map<String, NativeTarget> targets;
}

/// Geometry comes directly from evaluated MOC drawables. The host supplies its
/// actual story projection/transform and configured mask resolution.
NativeCubismGpuPasses buildNativeCubismMeshes({
  required String modelKey,
  required List<NativeCubismDrawable> evaluated,
  required Float32List clipTransform,
  required Map<int, String> textureKeys,
  required int maskTextureSize,
  required Map<String, ProjectedMesh> meshes,
  required Map<String, NativeMaterial> materials,
  double modelOpacity = 1,
  double brightness = 1,
  List<double> lightingRgb = const [1, 1, 1],
}) {
  if (modelOpacity <= 0) return NativeCubismGpuPasses([], [], {});
  if (lightingRgb.length != 3 || lightingRgb.any((v) => !v.isFinite)) {
    throw ArgumentError('native_cubism_lighting');
  }
  final byIndex = {
    for (final drawable in evaluated) drawable.sourceIndex: drawable,
  };
  final ordered = [...evaluated]
    ..sort((a, b) {
      final order = a.renderOrder.compareTo(b.renderOrder);
      return order == 0 ? a.sourceIndex.compareTo(b.sourceIndex) : order;
    });
  final maskPasses = <NativePass>[], draws = <NativeDraw>[];
  final targets = <String, NativeTarget>{};
  final layout = buildCubismMaskAtlas(evaluated);
  final inverse = layout.contexts.isEmpty
      ? Float32List(16)
      : inverseCubismProjection(clipTransform);
  final topologies = Map<Uint16List, TriangleTopology>.identity();
  if (clipTransform.length != 16 || clipTransform.any((v) => !v.isFinite)) {
    throw ArgumentError('native_invalid_projection');
  }
  ProjectedMesh geometry(
    NativeCubismDrawable drawable,
    double opacity, {
    CubismMaskContext? maskContext,
  }) {
    final count = drawable.positions.length ~/ 2;
    final output = SpriteGeometryBuilder(
      vertexCount: count,
      topology: topologies.putIfAbsent(
        drawable.indices,
        () => _topologySnapshot(drawable.indices),
      ),
    );
    if (maskContext != null) {
      final color = maskContext.channelColor;
      for (var index = 0; index < count; index++) {
        output.setVertex(
          index,
          maskContext.clipX(drawable.positions[index * 2]),
          maskContext.clipY(drawable.positions[index * 2 + 1]),
          0,
          1,
          drawable.uvs[index * 2],
          1 - drawable.uvs[index * 2 + 1],
          color[0],
          color[1],
          color[2],
          color[3],
        );
      }
      return output.build();
    }
    for (var index = 0; index < count; index++) {
      final x = drawable.positions[index * 2];
      final y = drawable.positions[index * 2 + 1];
      output.setVertex(
        index,
        clipTransform[0] * x +
            clipTransform[4] * y +
            clipTransform[8] * 0.0 +
            clipTransform[12],
        clipTransform[1] * x +
            clipTransform[5] * y +
            clipTransform[9] * 0.0 +
            clipTransform[13],
        clipTransform[2] * x +
            clipTransform[6] * y +
            clipTransform[10] * 0.0 +
            clipTransform[14],
        clipTransform[3] * x +
            clipTransform[7] * y +
            clipTransform[11] * 0.0 +
            clipTransform[15],
        drawable.uvs[index * 2],
        1 - drawable.uvs[index * 2 + 1],
        brightness,
        brightness,
        brightness,
        opacity,
      );
    }
    return output.build();
  }

  final atlasDraws = <int, List<NativeDraw>>{};
  for (final context in layout.contexts) {
    final mask = 'cubism-mask:$modelKey:${context.atlas}';
    targets.putIfAbsent(
      mask,
      () => NativeTarget(
        width: maskTextureSize,
        height: maskTextureSize,
        alpha: NativeTextureAlpha.independent,
      ),
    );
    final maskDraws = atlasDraws.putIfAbsent(context.atlas, () => []);
    for (final index in context.sources) {
      final source = byIndex[index]!;
      if (source.indices.isEmpty) continue;
      final texture = textureKeys[source.textureIndex];
      if (texture == null) throw StateError('native_cubism_mask_texture');
      final key = '$mask:${context.key}:$index';
      meshes[key] = geometry(source, 1, maskContext: context);
      materials[key] = NativeMaterial(
        texture: texture,
        recipe: NativeMaterialRecipe.cubismMask,
        textureAlpha: NativeTextureAlpha.premultiplied,
        blend: NativeBlend.coverageUnion,
        cull: (source.flags & 4) != 0 ? NativeCull.none : NativeCull.back,
      );
      maskDraws.add(NativeDraw(mesh: key, material: key));
    }
  }
  for (final entry in atlasDraws.entries) {
    maskPasses.add(
      NativePass(
        target: 'cubism-mask:$modelKey:${entry.key}',
        draws: entry.value,
      ),
    );
  }

  for (final drawable in ordered) {
    if (!drawable.visible ||
        drawable.indices.isEmpty ||
        drawable.opacity <= 0) {
      continue;
    }
    final key = 'cubism:$modelKey:${drawable.sourceIndex}';
    final context = layout.consumerContexts[drawable.sourceIndex];
    final mask = context == null
        ? null
        : 'cubism-mask:$modelKey:${context.atlas}';
    final texture = textureKeys[drawable.textureIndex];
    if (texture == null) {
      throw StateError('native_cubism_texture:${drawable.textureIndex}');
    }
    meshes[key] = geometry(drawable, drawable.opacity * modelOpacity);
    materials[key] = NativeMaterial(
      texture: texture,
      recipe: NativeMaterialRecipe.cubism,
      textureAlpha: NativeTextureAlpha.premultiplied,
      blend: (drawable.flags & 1) != 0
          ? NativeBlend.additivePreserveAlpha
          : (drawable.flags & 2) != 0
          ? NativeBlend.multiply
          : NativeBlend.premultipliedAlpha,
      cull: (drawable.flags & 4) != 0 ? NativeCull.none : NativeCull.back,
      additionalTextures: {'maskImage': ?mask},
      uniformFloats: Float32List.fromList([
        ...drawable.multiplyColor,
        ...drawable.screenColor,
        mask != null ? 1 : 0,
        (drawable.flags & 8) != 0 ? 1 : 0,
        0,
        0,
        ...?context?.samplingRows(inverse),
        if (context == null) ...Float32List(12),
        ...?context?.channelColor,
        if (context == null) ...Float32List(4),
        ...?context?.tileBounds,
        if (context == null) ...Float32List(4),
        if ((drawable.flags & 2) != 0) ...const [1.0, 1.0, 1.0] else
          ...lightingRgb,
        0,
      ]),
    );
    draws.add(NativeDraw(mesh: key, material: key));
  }
  return NativeCubismGpuPasses(maskPasses, draws, targets);
}
