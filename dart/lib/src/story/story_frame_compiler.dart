import 'dart:math' as math;
import 'dart:typed_data';

import 'package:haneoka_render_profile/core.dart';

import 'story_frame_geometry.dart';
import 'story_frame_image_material.dart';
import 'story_frame_playback.dart';
import 'story_frame_particles.dart';
import 'story_frame_source.dart';
import 'story_ui_layout_data.dart';

import 'story_image_mesh.dart';

final class StoryFrameRenderSnapshot {
  const StoryFrameRenderSnapshot(this.scene, this.frame, this.textures);
  final NativeSceneResources scene;
  final NativeFrame frame;
  final Map<String, Uri> textures;
}

/// Planar ordinary-alpha images can use an independent transparent surface.
/// The bound source-alpha material is emitted only for shared colour; masks
/// and off-plane drawing retain their separate unsupported boundary.
StoryFrameRenderSnapshot compileStoryFrame({
  required StoryFramePlaybackFrame playback,
  required StoryFrameCanvasMetrics metrics,
  required List<double> actualViewPivot,
  required Float32List actualPlanarClip,
  required int width,
  required int height,
  required RenderSource source,
  required String sourceId,
  bool sharedColour = false,
  StoryFrameParticleProjector? particleProjector,
  required Uri Function(String) resolveTexture,
  required StoryTiledImageSource Function(StoryFrameImageData)
  resolveTiledSource,
}) {
  final meshes = <String, ProjectedMesh>{},
      materials = <String, NativeMaterial>{},
      textures = <String, Uri>{},
      draws = <NativeDraw>[];
  final identity = Float32List.fromList([
    1,
    0,
    0,
    0,
    0,
    1,
    0,
    0,
    0,
    0,
    1,
    0,
    0,
    0,
    0,
    1,
  ]);
  particleProjector?.retain({
    for (final instance in playback.visibleInstances) instance.ref,
  });
  for (var index = 0; index < playback.visibleInstances.length; index++) {
    final instance = playback.visibleInstances[index];
    if (instance.source.unsupported.isNotEmpty) {
      throw UnsupportedError(
        'native_frame_source:${instance.source.unsupported}',
      );
    }
    final layout = {
      for (final raw in (instance.layout['nodes'] as List).cast<Map>())
        raw['id'] as String: raw,
    };
    final nodes = <NativeCanvasNode>[];
    for (final node in instance.source.nodes) {
      final current = layout[node.id]!;
      final groups = node.components.where(
        (record) => record['type'] == 'CanvasGroup',
      );
      final ignore = groups.any((group) {
        final v = (group['data'] as Map)['m_IgnoreParentGroups'];
        return v == 1 || v == true;
      });
      List<double> vector(String name) =>
          (current[name] as List).cast<num>().map((v) => v.toDouble()).toList();
      final position = vector('position'), scale = vector('scale');
      final override = current['localPositionOverride'];
      nodes.add(
        NativeCanvasNode(
          id: node.id,
          parent: node.parent,
          active: current['active'] as bool,
          anchorMin: vector('anchorMin'),
          anchorMax: vector('anchorMax'),
          pivot: vector('pivot'),
          size: vector('size'),
          position: Float32List.fromList([
            ...position,
            (current['positionZ'] as num).toDouble(),
          ]),
          localPositionOverride: override is List
              ? Float32List.fromList(
                  override.cast<num>().map((v) => v.toDouble()).toList(),
                )
              : null,
          rotationQuaternion: Float32List.fromList(
            vector('rotationQuaternion'),
          ),
          scale: Float32List.fromList([
            ...scale,
            (current['scaleZ'] as num).toDouble(),
          ]),
          opacity: (current['opacity'] as num).toDouble(),
          ignoreParentGroups: ignore,
        ),
      );
    }
    final placed = placeNativeCanvas(
      nodes: nodes,
      canvasWidth: metrics.width,
      canvasHeight: metrics.height,
      canvasPivot: actualViewPivot,
      canvasWorld: identity,
    );
    final prefix = 'frame:$index:${instance.ref}:';
    final instanceDraws = <String, List<NativeDraw>>{};
    StoryFrameParticleProjection? particles;
    if (instance.source.particleSource != null) {
      if (!sharedColour)
        throw UnsupportedError('native_frame_particle_shared_colour_required');
      if (particleProjector == null)
        throw StateError('native_frame_particle_projector_required');
      particles = particleProjector.project(
        instance: instance,
        epoch: playback.sourceEpoch,
        prefix: prefix,
        nodes: nodes,
        metrics: metrics,
        canvasPivot: actualViewPivot,
      );
      meshes.addAll(particles.meshes);
      materials.addAll(particles.materials);
      final particleSource = instance.source.particleSource!;
      for (final entry in particleSource.texturePaths.entries) {
        textures[entry.key] = resolveTexture(entry.value);
      }
    }
    for (final node in instance.source.nodes) {
      final image = node.image, placement = placed[node.id]!;
      if (image == null ||
          !image.enabled ||
          placement.opacity == 0 ||
          placement.width <= 0 ||
          placement.height <= 0) {
        continue;
      }
      StoryFrameSourceAlphaMaterial? sourceAlphaMaterial;
      if (image.materialRaw != null && !sharedColour) {
        throw UnsupportedError(
          'native_frame_shared_material_required:${node.path}',
        );
      }
      if (image.materialRaw != null) {
        sourceAlphaMaterial = StoryFrameSourceAlphaMaterial.fromImage(
          image,
          sourceId: sourceId,
        );
      }
      if (node.components.any((component) {
        final script =
            ((component['data'] as Map)['m_Script'] as Map?)?['reference']
                as Map?;
        return script?['name'] == 'Mask' || script?['name'] == 'RectMask2D';
      })) {
        throw UnsupportedError('native_frame_mask:${node.path}');
      }
      // Test the resulting plane, including 180-degree in-plane mirrors.
      // Quaternion x/y components alone do not characterize planarity.
      if (placement.matrix[2] != 0 ||
          placement.matrix[6] != 0 ||
          placement.matrix[14] != 0) {
        throw UnsupportedError('native_frame_offplane:${node.path}');
      }
      final current = layout[node.id]!, rawImage = current['image'] as Map;
      final authoredColor = (rawImage['color'] as List)
          .cast<num>()
          .map((v) => v.toDouble())
          .toList();
      final color = storyFrameColor32(authoredColor);
      final pivot = node.pivot;
      var rect = StoryUiRect(
        -pivot[0] * placement.width,
        -(1 - pivot[1]) * placement.height,
        placement.width,
        placement.height,
      );
      final sprite = image.spriteRaw;
      final tile = image.type == 2 ? resolveTiledSource(image) : null;
      ProjectedMesh primitive;
      final texture = image.texture;
      if (sprite == null) {
        if (texture != null) {
          throw StateError('native_frame_texture_without_sprite');
        }
        primitive = _solidQuad(rect, color, metrics.width, metrics.height);
      } else {
        final full = sprite['m_Rect'] as Map,
            atlas = sprite['m_RD'] as Map,
            trim = atlas['textureRect'] as Map,
            offset = atlas['textureRectOffset'] as Map,
            border = sprite['m_Border'] as Map;
        final sw = (full['width'] as num).toDouble(),
            sh = (full['height'] as num).toDouble();
        if (image.type == 0 && image.preserveAspect) {
          final fit = math.min(rect.width / sw, rect.height / sh);
          final w = sw * fit, h = sh * fit;
          rect = StoryUiRect(-pivot[0] * w, -(1 - pivot[1]) * h, w, h);
        }
        if (texture == null) {
          throw StateError('native_frame_sprite_output_missing');
        }
        primitive = buildStoryImageMesh(
          rect: rect,
          canvasWidth: metrics.width,
          canvasHeight: metrics.height,
          color: color,
          imageType: image.type,
          spriteSize: [sw, sh],
          trimmedPixels: StoryUiRect(
            (offset['x'] as num).toDouble(),
            (offset['y'] as num).toDouble(),
            (trim['width'] as num).toDouble(),
            (trim['height'] as num).toDouble(),
          ),
          border: StoryImageBorders(
            left: (border['x'] as num).toDouble(),
            bottom: (border['y'] as num).toDouble(),
            right: (border['z'] as num).toDouble(),
            top: (border['w'] as num).toDouble(),
          ),
          pixelsPerUnit:
              image.spritePixelsPerUnit! /
              metrics.referencePixelsPerUnit *
              image.pixelsPerUnitMultiplier,
          fillCenter: image.fillCenter,
          tiledSource: tile,
        );
      }
      final key = '$prefix${node.id}';
      meshes[key] = projectNativeCanvasImage(
        image: primitive,
        canvasWidth: metrics.width,
        canvasHeight: metrics.height,
        localClip: NativeAuthoredEffectGraph.multiply(
          actualPlanarClip,
          placement.matrix,
        ),
        inheritedOpacity: placement.opacity,
      );
      materials[key] = NativeMaterial(
        texture: texture ?? 'native-solid-white',
        recipe: sourceAlphaMaterial != null
            ? NativeMaterialRecipe.uiSourceAlphaAdditive
            : texture == null
            ? NativeMaterialRecipe.solidColor
            : NativeMaterialRecipe.textured,
        blend: sourceAlphaMaterial != null
            ? NativeBlend.sourceAlphaAdditive
            : NativeBlend.premultipliedAlpha,
        textureAlpha: NativeTextureAlpha.premultiplied,
        widthAddressMode: tile?.wrapU ?? NativeSamplerAddress.clampToEdge,
        heightAddressMode: tile?.wrapV ?? NativeSamplerAddress.clampToEdge,
      );
      if (texture != null) textures[texture] = resolveTexture(texture);
      instanceDraws[node.id] = [NativeDraw(mesh: key, material: key)];
    }
    for (final node in instance.source.nodes) {
      draws.addAll(instanceDraws[node.id] ?? const []);
      draws.addAll(particles?.drawsAfterNode[node.id] ?? const []);
    }
  }
  meshes['frame:copy'] = _solidQuad(
    StoryUiRect(0, 0, metrics.width, metrics.height),
    const [1, 1, 1, 1],
    metrics.width,
    metrics.height,
  );
  materials['frame:copy'] = const NativeMaterial(
    texture: 'frame:main',
    textureAlpha: NativeTextureAlpha.premultiplied,
    blend: NativeBlend.opaque,
  );
  return StoryFrameRenderSnapshot(
    NativeSceneResources(
      epoch: playback.sourceEpoch,
      source: source,
      meshes: meshes,
      materials: materials,
      targets: {
        'frame:main': NativeTarget(
          width: width,
          height: height,
          format: NativeTargetFormat.rgba16f,
        ),
        'frame:output': NativeTarget(
          width: width,
          height: height,
          presentable: true,
        ),
      },
    ),
    NativeFrame(
      epoch: playback.sourceEpoch,
      mediaMicroseconds: playback.actualStoryUs,
      outputTarget: 'frame:output',
      passes: [
        NativePass(target: 'frame:main', draws: draws),
        NativePass(
          target: 'frame:output',
          draws: [const NativeDraw(mesh: 'frame:copy', material: 'frame:copy')],
        ),
      ],
    ),
    textures,
  );
}

ProjectedMesh _solidQuad(
  StoryUiRect r,
  List<double> color,
  double w,
  double h,
) {
  final vertices = <double>[];
  for (final point in const [(0.0, 0.0), (0.0, 1.0), (1.0, 1.0), (1.0, 0.0)]) {
    vertices.addAll([
      2 * (r.x + r.width * point.$1) / w - 1,
      1 - 2 * (r.y + r.height * point.$2) / h,
      0,
      1,
      point.$1,
      point.$2,
      ...color,
    ]);
  }
  return ProjectedMesh(
    Float32List.fromList(vertices),
    Uint16List.fromList([0, 1, 2, 0, 2, 3]),
  );
}
