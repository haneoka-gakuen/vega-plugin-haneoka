import 'dart:math' as math;
import 'dart:typed_data';

import 'package:haneoka_render_profile/core.dart';
import 'package:vector_math/vector_math_64.dart' as vm;

import 'story_frame_geometry.dart';
import 'story_frame_particle_source.dart';
import 'story_frame_playback.dart';

Float32List _affine(List<double> scale, List<double> translation) =>
    Float32List.fromList([
      scale[0],
      0,
      0,
      0,
      0,
      scale[1],
      0,
      0,
      0,
      0,
      scale[2],
      0,
      ...translation,
      1,
    ]);
Float32List _mul(Float32List a, Float32List b) =>
    NativeAuthoredEffectGraph.multiply(a, b);
List<double> _lossy(Float32List m, List<double> q) {
  final rotation = NativeLocalTransform(
    position: Float32List(3),
    quaternion: Float32List.fromList(q),
    scale: Float32List.fromList([1, 1, 1]),
  ).matrix();
  return [
    for (var c = 0; c < 3; c++)
      m[c * 4] * rotation[c * 4] +
          m[c * 4 + 1] * rotation[c * 4 + 1] +
          m[c * 4 + 2] * rotation[c * 4 + 2],
  ];
}

final class StoryFrameParticleProjection {
  const StoryFrameParticleProjection(
    this.meshes,
    this.materials,
    this.drawsAfterNode,
  );
  final Map<String, ProjectedMesh> meshes;
  final Map<String, NativeMaterial> materials;
  final Map<String, List<NativeDraw>> drawsAfterNode;
}

final class _Run {
  _Run(this.source, this.runId, this.epoch)
    : systems = source.createSystems(seed: 0x55495053 ^ runId);
  final StoryFrameParticleSource source;
  final int runId, epoch;
  final List<AuthoredParticleSystem> systems;
  double seconds = 0;
}

/// Coffee's active UI-particle systems use an isolated simulation stream.
/// Game state supplies unscaled active time; projection/resize never advances it.
final class StoryFrameParticleProjector {
  final _runs = <String, _Run>{};
  final _emptyFrame = NativeEffectAnimationFrame.empty();
  Map<String, Object?> get diagnostic => {
    for (final entry in _runs.entries)
      entry.key: {
        'seconds': entry.value.seconds,
        'runId': entry.value.runId,
        'systems': [
          for (final system in entry.value.systems) system.diagnostic,
        ],
      },
  };
  void clear() => _runs.clear();
  void retain(Set<String> refs) =>
      _runs.removeWhere((key, _) => !refs.contains(key));

  StoryFrameParticleProjection project({
    required StoryFrameInstanceFrame instance,
    required int epoch,
    required String prefix,
    required List<NativeCanvasNode> nodes,
    required StoryFrameCanvasMetrics metrics,
    required List<double> canvasPivot,
  }) {
    final source = instance.source.particleSource!;
    final requested = instance.particleSeconds;
    var run = _runs[instance.ref];
    final rebuild =
        run == null ||
        !identical(run.source, source) ||
        run.runId != instance.particleRunId ||
        run.epoch != epoch ||
        requested < run.seconds;
    if (rebuild) {
      run = _Run(source, instance.particleRunId, epoch);
      _runs[instance.ref] = run;
    }
    final current = run;
    final canvasScale = 2 * source.orthographicSize / metrics.height;
    final cameraWorld = source.graph.worldMatrix(source.cameraTransform);
    // The generic billboard camera currently accepts an X-axis camera rotation.
    // The formal story UI camera is identity-oriented; retain this capability boundary.
    if ([1, 2, 4, 6, 8, 9].any((i) => cameraWorld[i] != 0) ||
        [0, 5, 10].any((i) => cameraWorld[i] != 1)) {
      throw UnsupportedError('frame_particle_camera_orientation');
    }
    final physicalCanvas = _mul(
      cameraWorld,
      _affine(
        [canvasScale, canvasScale, canvasScale],
        [0, 0, source.planeDistance],
      ),
    );
    final driven = {for (final node in nodes) node.id: node};
    Map<String, NativeCanvasPlacement> place() => placeNativeCanvas(
      nodes: driven.values,
      canvasWidth: metrics.width,
      canvasHeight: metrics.height,
      canvasPivot: canvasPivot,
      canvasWorld: physicalCanvas,
    );
    var placed = place();
    final groupScales = <String, List<double>>{};
    final groupsBySystem = <String, StoryFrameUiParticleGroup>{};
    for (final group in source.groups) {
      final node = driven[group.transform.id]!;
      final parentMatrix = node.parent == null
          ? physicalCanvas
          : placed[node.parent]!.matrix;
      final parentQuaternion = node.parent == null
          ? Float32List.fromList([0, 0, 0, 1])
          : source.graph.worldRotation(
              source
                  .graph
                  .objects['${group.transform.serializedFile}:${node.parent}']!,
            );
      final parentScale = _lossy(parentMatrix, parentQuaternion);
      if (group.autoScalingMode == 2) {
        driven[node.id] = NativeCanvasNode(
          id: node.id,
          parent: node.parent,
          active: node.active,
          anchorMin: node.anchorMin,
          anchorMax: node.anchorMax,
          pivot: node.pivot,
          size: node.size,
          position: node.position,
          localPositionOverride: node.localPositionOverride,
          rotationQuaternion: node.rotationQuaternion,
          scale: Float32List.fromList([
            for (final s in parentScale) s == 0 ? 1 : 1 / s,
          ]),
          opacity: node.opacity,
          ignoreParentGroups: node.ignoreParentGroups,
        );
        placed = place();
      }
      final s3 = group.scale;
      final baseScale = [
        for (var i = 0; i < 3; i++)
          s3[i] *
              parentScale[i] *
              (group.autoScalingMode == 2 ? 1 : node.scale[i] / canvasScale),
      ];
      for (final system in group.systems) {
        groupsBySystem[system.key] = group;
        groupScales[system.key] = [
          for (final value in baseScale)
            value *
                (group.autoScalingMode == 1 && system.data['scalingMode'] == 1
                    ? canvasScale
                    : 1),
        ];
      }
    }
    void simulate(double at, double dt) {
      for (final system in current.systems) {
        final group = groupsBySystem[system.object.key]!;
        final placement = placed[system.transform.id]!;
        final parent = placed[group.transform.id]!;
        if (parent.opacity < .01) continue;
        system.simulateFrame(
          at,
          frameDelta: dt * group.timeScaleMultiplier,
          pathHash: 0,
          nativeWidth: 1,
          activeAt: (_) => placement.active,
          frameAt: (_) => _emptyFrame,
          matrixAt: (_) => placement.matrix,
        );
      }
    }

    if (rebuild) {
      // Seek restoration uses the same Source 60 Hz reconstruction as other effects.
      while (current.seconds + 1 / 60 < requested - 1e-9) {
        current.seconds += 1 / 60;
        simulate(current.seconds, 1 / 60);
      }
    }
    if (requested > current.seconds)
      simulate(requested, requested - current.seconds);
    current.seconds = requested;

    final inverseCamera = vm.Matrix4.fromList(cameraWorld)..invert();
    final near = (source.camera['near clip plane'] as num).toDouble(),
        far = (source.camera['far clip plane'] as num).toDouble(),
        ortho = source.orthographicSize;
    final projection = Float32List.fromList([
      metrics.height / (ortho * metrics.width),
      0,
      0,
      0,
      0,
      1 / ortho,
      0,
      0,
      0,
      0,
      1 / (far - near),
      0,
      0,
      0,
      -near / (far - near),
      1,
    ]);
    final cameraClip = _mul(
      projection,
      Float32List.fromList(inverseCamera.storage),
    );
    final meshes = <String, ProjectedMesh>{},
        materials = <String, NativeMaterial>{};
    final draws = <String, List<NativeDraw>>{};
    for (var i = 0; i < current.systems.length; i++) {
      final system = current.systems[i],
          group = groupsBySystem[system.object.key]!;
      final groupPlacement = placed[group.transform.id]!,
          ps = placed[system.transform.id]!;
      if (!ps.active || groupPlacement.opacity < .01) continue;
      final scale = groupScales[system.object.key]!;
      // BakeRotationAndScale has no translation. The neutral mesh has world
      // translation, so remove it before Coffee's GetWorldMatrix/Relative shift.
      final offset = [
        for (var axis = 0; axis < 3; axis++)
          group.positionMode == 1
              ? 0.0
              : (ps.matrix[12 + axis] - groupPlacement.matrix[12 + axis]) *
                    (scale[axis] - 1),
      ];
      final coffee = _affine(scale, [
        for (var axis = 0; axis < 3; axis++)
          ps.matrix[12 + axis] * (1 - scale[axis]) + offset[axis],
      ]);
      final mesh = system.buildMesh(
        matrix: ps.matrix,
        nativeWidth: 1,
        clipFromWorld: _mul(cameraClip, coffee),
        fieldOfViewRadians: math.pi / 2,
        cameraPosition: cameraWorld.sublist(12, 15),
        cameraXDegrees: 0,
        bakeEnabled: true,
        orthographicSize: ortho,
      );
      if (mesh == null) continue;
      final vertices = Float32List.fromList(mesh.vertices);
      final colour = group.data['m_Color'] as Map;
      for (var v = 0; v < vertices.length; v += 10) {
        for (var c = 0; c < 4; c++) {
          vertices[v + 6 + c] *= (colour[['r', 'g', 'b', 'a'][c]] as num)
              .toDouble();
        }
        vertices[v + 9] *= groupPlacement.opacity;
      }
      final key = '${prefix}particle:$i';
      meshes[key] = ProjectedMesh(vertices, mesh.indices);
      materials[key] = system.materialProperties.materialFor(system.texture);
      // Coffee appends each generated renderer after the UIParticle's authored children.
      final rootPath = instance.source.nodes
          .firstWhere((n) => n.id == group.transform.id)
          .path;
      final after = instance.source.nodes
          .lastWhere(
            (n) =>
                n.id == group.transform.id || n.path.startsWith('$rootPath/'),
          )
          .id;
      (draws[after] ??= []).add(NativeDraw(mesh: key, material: key));
    }
    return StoryFrameParticleProjection(meshes, materials, draws);
  }
}
