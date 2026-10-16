import 'dart:typed_data';

import 'package:haneoka_render_profile/core.dart';

Map<String, Object?> _map(Object? value) =>
    Map<String, Object?>.from(value as Map);

final class StoryFrameUiParticleGroup {
  StoryFrameUiParticleGroup(this.component, this.transform, this.systems);
  final NativeEffectObject component, transform;
  final List<NativeEffectObject> systems;
  Map get data => component.data;
  int get autoScalingMode =>
      data['m_IgnoreCanvasScaler'] == 1 ||
          data['m_IgnoreCanvasScaler'] == true ||
          data['m_AutoScaling'] == 1 ||
          data['m_AutoScaling'] == true
      ? 2
      : data['m_AutoScalingMode'] as int;
  int get positionMode =>
      data['m_AbsoluteMode'] == 1 || data['m_AbsoluteMode'] == true
      ? 1
      : data['m_PositionMode'] as int;
  List<double> get scale => [
    for (final axis in ['x', 'y', 'z'])
      ((data['m_Scale3D'] as Map)[axis] as num).toDouble(),
  ];
  double get timeScaleMultiplier =>
      (data['m_TimeScaleMultiplier'] as num).toDouble();
}

/// Immutable Coffee UI-particle bindings compiled from formal Frame records.
final class StoryFrameParticleSource {
  StoryFrameParticleSource._(
    this.graph,
    this.groups,
    this.materialTextureKeys,
    this.texturePaths,
    this.textureHashes,
    this.textureProperties,
    this.camera,
    this.cameraTransform,
    this.canvas,
    this.gravity,
  );

  final NativeAuthoredEffectGraph graph;
  final List<StoryFrameUiParticleGroup> groups;
  final Map<String, String> materialTextureKeys, texturePaths, textureHashes;
  final Map<String, Map> textureProperties;
  final Map camera, canvas;
  final NativeEffectObject cameraTransform;
  final Float64List gravity;
  double get orthographicSize =>
      (camera['orthographic size'] as num).toDouble();
  double get planeDistance => (canvas['m_PlaneDistance'] as num).toDouble();

  factory StoryFrameParticleSource.fromRaw(Map<String, Object?> packet) {
    final graph = NativeAuthoredEffectGraph(packet['particleGraph'] as Map);
    final environment = _map(packet['particleEnvironment']);
    final server = environment['server'] as String;
    if (!RegExp(r'^[a-z][a-z0-9-]*$').hasMatch(server))
      throw const FormatException('frame_particle_server');
    final cameraRecord = _map(environment['camera']);
    final camera = _map(cameraRecord['data']);
    final canvas = _map(_map(environment['canvas'])['data']);
    final transforms = (environment['cameraTransformChain'] as List)
        .cast<Map>();
    if (camera['orthographic'] != true ||
        (camera['orthographic size'] as num) <= 0 ||
        (camera['far clip plane'] as num) <=
            (camera['near clip plane'] as num) ||
        canvas['m_RenderMode'] != 1 ||
        canvas['m_SortingOrder'] != 303 ||
        (canvas['m_PlaneDistance'] as num) <= 0 ||
        transforms.isEmpty) {
      throw const FormatException('frame_particle_canvas_source');
    }
    final global = _map(environment['globalSettings']);
    if (global['activeColorSpace'] != 0) {
      throw UnsupportedError(
        'frame_particle_color_space:${global['activeColorSpace']}',
      );
    }
    final gravity = global['gravity'] as Map;
    final texturePaths = <String, String>{}, textureHashes = <String, String>{};
    final textureProperties = <String, Map>{};
    for (final entry in (packet['particleResourceOutputs'] as Map).entries) {
      final rows = (entry.value as List).cast<Map>();
      if (rows.length != 1 || rows.single['type'] != 'Texture2D') {
        throw const FormatException('frame_particle_texture_output');
      }
      final output = rows.single, path = output['path'] as String;
      final prefix = path.startsWith('runtime/')
          ? 'runtime/'
          : path.startsWith('assets/')
          ? 'assets/'
          : null;
      if (prefix == null || path.split('/').contains('..')) {
        throw const FormatException('frame_particle_texture_path');
      }
      final identity = entry.key as String;
      final texture = graph.objects[identity];
      if (texture == null || texture.type != 'Texture2D') {
        throw FormatException('frame_particle_texture_identity:$identity');
      }
      final key = 'frame-particle:$identity';
      texturePaths[key] =
          '/${prefix.substring(0, prefix.length - 1)}/$server/${path.substring(prefix.length)}';
      textureHashes[key] = output['sha256'] as String;
      final sampling = texture.data['m_TextureSettings'] as Map;
      if (texture.data['m_MipCount'] != 1 ||
          sampling['m_FilterMode'] != 1 ||
          sampling['m_WrapU'] != 1 ||
          sampling['m_WrapV'] != 1) {
        throw UnsupportedError(
          'frame_particle_texture_sampling:${texture.key}',
        );
      }
      textureProperties[key] = texture.data;
    }
    final materialTextureKeys = <String, String>{};
    for (final material in graph.objects.values.where(
      (object) => object.type == 'Material',
    )) {
      final saved = material.data['m_SavedProperties'] as Map;
      final main = (saved['m_TexEnvs'] as List)
          .cast<List>()
          .where((row) => row[0] == '_MainTex')
          .toList();
      if (main.length != 1) {
        throw FormatException(
          'frame_particle_material_texture:${material.key}',
        );
      }
      final texture = graph.reference(
        material,
        (main.single[1] as Map)['m_Texture'] as Map,
      );
      if (texture == null ||
          !texturePaths.containsKey('frame-particle:${texture.key}')) {
        throw FormatException(
          'frame_particle_material_binding:${material.key}',
        );
      }
      materialTextureKeys[material.key] = 'frame-particle:${texture.key}';
    }
    final groups = <StoryFrameUiParticleGroup>[];
    for (final component in graph.objects.values) {
      if (component.type != 'MonoBehaviour') continue;
      final script = (component.data['m_Script'] as Map)['reference'] as Map?;
      if (script?['name'] != 'UIParticle') continue;
      final raw = component.data;
      if (raw['m_Enabled'] != 1 && raw['m_Enabled'] != true) continue;
      final scriptRecord =
          (packet['resolvedScripts'] as Map)[script!['pathId']] as Map;
      final scriptData = scriptRecord['data'] as Map;
      if (scriptRecord['serializedFile'] != script['serializedFile'] ||
          scriptData['m_ClassName'] != 'UIParticle' ||
          scriptData['m_Namespace'] != 'Coffee.UIExtensions' ||
          scriptData['m_AssemblyName'] != 'Coffee.UIParticle') {
        throw const FormatException('frame_particle_script_identity');
      }
      if (raw['m_MeshSharing'] != 0 ||
          raw['m_GroupId'] != raw['m_GroupMaxId'] ||
          raw['m_UseCustomView'] == true ||
          raw['m_UseCustomView'] == 1 ||
          (raw['m_AnimatableProperties'] as List).isNotEmpty) {
        throw UnsupportedError('frame_particle_ui_features');
      }
      final systems = <NativeEffectObject>[];
      for (final pointer in raw['m_Particles'] as List) {
        final system = graph.reference(component, pointer as Map);
        if (system == null || system.type != 'ParticleSystem') {
          throw const FormatException('frame_particle_system_identity');
        }
        final renderers = graph.selectedComponents(
          graph.gameObject(system),
          type: 'ParticleSystemRenderer',
        );
        if (renderers.length != 1) {
          throw const FormatException('frame_particle_renderer_identity');
        }
        final renderer = renderers.single;
        final material = graph.reference(
          renderer,
          (renderer.data['m_Materials'] as List).single as Map,
        );
        if (material == null) {
          // Coffee retains the empty root system in its authored list.
          if ((system.data['EmissionModule'] as Map)['enabled'] == true ||
              (system.data['SubModule'] as Map)['enabled'] == true) {
            throw UnsupportedError('frame_particle_default_material');
          }
          continue;
        }
        if (system.data['moveWithTransform'] != 0 ||
            !const [0, 1].contains(system.data['scalingMode']) ||
            (system.data['InitialModule'] as Map)['gravitySource'] != 0) {
          throw UnsupportedError('frame_particle_simulation_space');
        }
        systems.add(system);
      }
      final group = StoryFrameUiParticleGroup(
        component,
        graph.transform(component),
        List.unmodifiable(systems),
      );
      if (![0, 1, 2].contains(group.autoScalingMode) ||
          ![0, 1].contains(group.positionMode) ||
          !group.timeScaleMultiplier.isFinite ||
          group.timeScaleMultiplier < 0) {
        throw const FormatException('frame_particle_ui_modes');
      }
      groups.add(group);
    }
    if (groups.isEmpty) {
      throw const FormatException('frame_particle_ui_host');
    }
    final transform = transforms.first;
    final source = StoryFrameParticleSource._(
      graph,
      List.unmodifiable(groups),
      Map.unmodifiable(materialTextureKeys),
      Map.unmodifiable(texturePaths),
      Map.unmodifiable(textureHashes),
      Map.unmodifiable(textureProperties),
      camera,
      graph.objects['${transform['serializedFile']}:${transform['pathId']}']!,
      canvas,
      Float64List.fromList([
        for (final axis in ['x', 'y', 'z']) (gravity[axis] as num).toDouble(),
      ]),
    );
    // Validate every enabled renderer/module before admitting this frame.
    source.createSystems(seed: 0);
    return source;
  }

  List<AuthoredParticleSystem> createSystems({required int seed}) {
    final adapter = _ParticleSourceAdapter(this, seed);
    return List.unmodifiable([
      for (final group in groups)
        for (final system in group.systems)
          AuthoredParticleSystem(
            adapter,
            {'metadataUrl': system.key},
            projectGravity: gravity,
            materialResolver: (material) =>
                NativeParticleMaterial.fromSource(material, graph: graph),
            prewarm: true,
            noise: (system.data['NoiseModule'] as Map)['enabled'] == true
                ? AuthoredParticleNoise(system.data['NoiseModule'] as Map)
                : null,
          ),
    ]);
  }
}

final class _ParticleSourceAdapter implements AuthoredParticleSource {
  _ParticleSourceAdapter(this.source, int seed)
    : random = NativeAuthoredRandom(seed);
  final StoryFrameParticleSource source;
  final NativeAuthoredRandom random;
  final fixedRandom = <String, NativeAuthoredRandom>{};
  @override
  NativeAuthoredEffectGraph get graph => source.graph;
  @override
  Map<String, String> get materialTextureKeys => source.materialTextureKeys;
  @override
  NativeEffectObject component(String path) => graph.objects[path]!;
  @override
  NativeAuthoredRandom randomFor(NativeEffectObject system) =>
      system.data['autoRandomSeed'] == true
      ? random
      : fixedRandom.putIfAbsent(
          system.key,
          () => NativeAuthoredRandom(system.data['randomSeed'] as int),
        );
}
