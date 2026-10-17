import 'dart:collection';
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
  final bodyMaterials = <Record, NativeMaterial>{};
  final maskMaterials = <Record, NativeMaterial>{};
  final layout = buildCubismMaskAtlas(evaluated);
  final inverse = layout.contexts.isEmpty
      ? Float32List(16)
      : inverseCubismProjection(clipTransform);
  final topologies = Map<Uint16List, TriangleTopology>.identity();
  if (clipTransform.length != 16 || clipTransform.any((v) => !v.isFinite)) {
    throw ArgumentError('native_invalid_projection');
  }
  final geometrySources = <String, _CubismGeometryPart>{};
  _CubismGeometryPart part(
    NativeCubismDrawable drawable,
    double opacity,
    CubismMaskContext? context,
  ) => _CubismGeometryPart(
    drawable,
    opacity,
    context,
    topologies.putIfAbsent(
      drawable.indices,
      () => _topologySnapshot(drawable.indices),
    ),
  );
  void writeGeometry(
    SpriteGeometryBuilder output,
    int vertexOffset,
    NativeCubismDrawable drawable,
    double opacity,
    CubismMaskContext? maskContext,
  ) {
    final count = drawable.positions.length ~/ 2;
    if (maskContext != null) {
      final color = maskContext.channelColor;
      for (var index = 0; index < count; index++) {
        output.setVertex(
          index + vertexOffset,
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
      return;
    }
    for (var index = 0; index < count; index++) {
      final x = drawable.positions[index * 2];
      final y = drawable.positions[index * 2 + 1];
      output.setVertex(
        index + vertexOffset,
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
  }

  ProjectedMesh geometry(String key, List<_CubismGeometryPart> pieces) {
    final count = pieces.fold(0, (length, part) => length + part.vertexCount);
    final topology = pieces.length == 1
        ? pieces.first.topology
        : _cubismBatchTopology(key, pieces);
    final output = SpriteGeometryBuilder(
      vertexCount: count,
      topology: topology,
    );
    var offset = 0;
    for (final part in pieces) {
      writeGeometry(
        output,
        offset,
        part.drawable,
        part.opacity,
        part.maskContext,
      );
      offset += part.vertexCount;
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
      geometrySources[key] = part(source, 1, context);
      materials[key] = maskMaterials.putIfAbsent(
        (texture, source.flags & 4),
        () => NativeMaterial(
          texture: texture,
          recipe: NativeMaterialRecipe.cubismMask,
          textureAlpha: NativeTextureAlpha.premultiplied,
          blend: NativeBlend.coverageUnion,
          cull: (source.flags & 4) != 0 ? NativeCull.none : NativeCull.back,
        ),
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
    geometrySources[key] = part(
      drawable,
      drawable.opacity * modelOpacity,
      null,
    );
    final multiply = _cubismColourWords(drawable.multiplyColor);
    final screen = _cubismColourWords(drawable.screenColor);
    final materialKey = (
      texture,
      drawable.flags & 15,
      mask,
      context?.key,
      multiply[0],
      multiply[1],
      multiply[2],
      multiply[3],
      screen[0],
      screen[1],
      screen[2],
      screen[3],
    );
    materials[key] = bodyMaterials.putIfAbsent(
      materialKey,
      () => NativeMaterial(
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
      ),
    );
    draws.add(NativeDraw(mesh: key, material: key));
  }
  return NativeCubismGpuPasses(
    [
      for (final pass in maskPasses)
        NativePass(
          target: pass.target,
          clear: pass.clear,
          clearColor: pass.clearColor,
          draws: _batchAdjacentCubismDraws(
            pass.draws,
            meshes,
            materials,
            geometrySources,
            geometry,
          ),
        ),
    ],
    _batchAdjacentCubismDraws(
      draws,
      meshes,
      materials,
      geometrySources,
      geometry,
    ),
    targets,
  );
}

final _cubismColourViews = Expando<Uint32List>('cubism colour bits');

Uint32List _cubismColourWords(Float32List colour) {
  if (colour.length != 4) throw ArgumentError('native_cubism_colour');
  return _cubismColourViews[colour] ??= colour.buffer.asUint32List(
    colour.offsetInBytes,
    colour.length,
  );
}

bool _sameCubismFloats(Float32List? left, Float32List? right) {
  if (identical(left, right)) return true;
  if (left == null || right == null || left.length != right.length) {
    return false;
  }
  final a = left.buffer.asUint32List(left.offsetInBytes, left.length);
  final b = right.buffer.asUint32List(right.offsetInBytes, right.length);
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _sameCubismMaterial(NativeMaterial left, NativeMaterial right) {
  if (identical(left, right)) return true;
  if (left.texture != right.texture ||
      left.recipe != right.recipe ||
      left.blend != right.blend ||
      left.depthTest != right.depthTest ||
      left.depthWrite != right.depthWrite ||
      left.textureAlpha != right.textureAlpha ||
      left.cull != right.cull ||
      left.widthAddressMode != right.widthAddressMode ||
      left.heightAddressMode != right.heightAddressMode ||
      left.minFilter != right.minFilter ||
      left.magFilter != right.magFilter ||
      !identical(left.coverageMask, right.coverageMask) ||
      left.coverageChannel != right.coverageChannel ||
      left.additionalTextures.length != right.additionalTextures.length ||
      !_sameCubismFloats(left.uniformFloats, right.uniformFloats)) {
    return false;
  }
  for (final entry in left.additionalTextures.entries) {
    if (right.additionalTextures[entry.key] != entry.value) return false;
  }
  return true;
}

final class _CubismGeometryPart {
  const _CubismGeometryPart(
    this.drawable,
    this.opacity,
    this.maskContext,
    this.topology,
  );
  final NativeCubismDrawable drawable;
  final TriangleTopology topology;
  final double opacity;
  final CubismMaskContext? maskContext;
  int get vertexCount => drawable.positions.length ~/ 2;
}

final _cubismBatchTopologies = LinkedHashMap<String, _CubismBatchTopology>();
var _cubismBatchTopologyBytes = 0;

final class _CubismBatchTopology {
  _CubismBatchTopology(List<_CubismGeometryPart> meshes)
    : sources = [for (final mesh in meshes) mesh.topology.indices],
      vertexCounts = [for (final mesh in meshes) mesh.vertexCount] {
    final merged = Uint16List(
      meshes.fold(0, (length, mesh) => length + mesh.topology.indices.length),
    );
    var offset = 0, vertexOffset = 0;
    for (final (i, mesh) in meshes.indexed) {
      if (mesh.topology.maximumIndex >= mesh.vertexCount) {
        throw ArgumentError('Invalid projected triangle mesh');
      }
      for (final index in mesh.topology.indices) {
        merged[offset++] = index + vertexOffset;
      }
      vertexOffset += vertexCounts[i];
    }
    topology = TriangleTopology(merged);
  }
  final List<Uint16List> sources;
  final List<int> vertexCounts;
  late final TriangleTopology topology;
  int get retainedBytes =>
      topology.indices.lengthInBytes +
      sources.fold(0, (bytes, source) => bytes + source.lengthInBytes);

  bool matches(List<_CubismGeometryPart> meshes) {
    if (sources.length != meshes.length) return false;
    for (var i = 0; i < sources.length; i++) {
      final source = sources[i], mesh = meshes[i];
      if (vertexCounts[i] != mesh.vertexCount ||
          source.length != mesh.topology.indices.length) {
        return false;
      }
      if (!identical(source, mesh.topology.indices)) {
        for (var j = 0; j < source.length; j++) {
          if (source[j] != mesh.topology.indices[j]) return false;
        }
      }
    }
    return true;
  }
}

TriangleTopology _cubismBatchTopology(
  String key,
  List<_CubismGeometryPart> meshes,
) {
  final previous = _cubismBatchTopologies.remove(key);
  if (previous != null) _cubismBatchTopologyBytes -= previous.retainedBytes;
  final value = previous != null && previous.matches(meshes)
      ? previous
      : _CubismBatchTopology(meshes);
  _cubismBatchTopologies[key] = value;
  _cubismBatchTopologyBytes += value.retainedBytes;
  while (_cubismBatchTopologies.length > 512 ||
      _cubismBatchTopologyBytes > 8 * 1024 * 1024) {
    final oldest = _cubismBatchTopologies.remove(
      _cubismBatchTopologies.keys.first,
    )!;
    _cubismBatchTopologyBytes -= oldest.retainedBytes;
  }
  return value.topology;
}

/// Form compatible adjacent batches before projecting vertices. Each vertex is
/// written and validated once; triangle order and all material state are kept.
List<NativeDraw> _batchAdjacentCubismDraws(
  List<NativeDraw> draws,
  Map<String, ProjectedMesh> meshes,
  Map<String, NativeMaterial> materials,
  Map<String, _CubismGeometryPart> sources,
  ProjectedMesh Function(String key, List<_CubismGeometryPart> parts) geometry,
) {
  final output = <NativeDraw>[];
  final run = <NativeDraw>[];
  var vertexCount = 0;
  void flush() {
    if (run.isEmpty) return;
    final pieces = [for (final draw in run) sources[draw.mesh]!];
    if (run.length == 1) {
      final draw = run.single;
      meshes[draw.mesh] = geometry(draw.mesh, pieces);
      output.add(draw);
    } else {
      final key = 'cubism-batch:${run.first.mesh}:${run.last.mesh}';
      final material = materials[run.first.material]!;
      for (final draw in run) {
        materials.remove(draw.material);
      }
      meshes[key] = geometry(key, pieces);
      materials[key] = material;
      output.add(NativeDraw(mesh: key, material: key));
    }
    run.clear();
    vertexCount = 0;
  }

  for (final draw in draws) {
    final count = sources[draw.mesh]!.vertexCount;
    if (run.isNotEmpty &&
        (vertexCount + count > 65536 ||
            !_sameCubismMaterial(
              materials[run.first.material]!,
              materials[draw.material]!,
            ))) {
      flush();
    }
    if (count > 65536) {
      meshes[draw.mesh] = geometry(draw.mesh, [sources[draw.mesh]!]);
      output.add(draw);
      continue;
    }
    run.add(draw);
    vertexCount += count;
  }
  flush();
  return output;
}
