part of 'story_frame_playback.dart';

extension StoryFramePlaybackSnapshotData on StoryFramePlaybackSnapshot {
  Map<String, Object?> toData() => {
    'version': definitionFingerprints == null ? 2 : 3,
    if (definitionFingerprints != null)
      'definitionFingerprints': definitionFingerprints,
    'source': identity.toJson(),
    'storyUs': storyUs,
    'updateIndex': updateIndex,
    'currentRef': currentRef,
    'order': order,
    'nextOperation': nextOperation,
    'paused': paused,
    'warnings': warnings,
    'instances': {
      for (final e in _instances.entries)
        e.key: {
          'state': e.value.state,
          'seconds': e.value.seconds,
          'speed': e.value.speed,
          'active': e.value.active,
          if (e.value.source.particleSource != null) ...{
            'particleSeconds': e.value.particleSeconds,
            'particleRunId': e.value.particleRunId,
          },
          'poses': {
            for (final p in e.value.poses.entries) p.key: p.value.toData(),
          },
        },
    },
    'operations': [
      for (final op in _operations)
        {
          'id': op.id,
          'commandIndex': op.commandIndex,
          'executionId': op.executionId,
          'ref': op.ref,
          'namedState': op.namedState,
          'fade': op.fade,
          'delay': op.delay,
          'wait': op.wait,
          'updateIndex': op.updateIndex,
          'elapsed': op.elapsed,
          'from': op.from,
          'target': op.target,
          'hiding': op.hiding,
          'tweenStarted': op.tweenStarted,
          'phase': op.phase.name,
        },
    ],
  };
}

extension StoryFramePlaybackData on StoryFramePlayback {
  Map<String, Object?> snapshotData() => snapshot().toData();
  Map<int, StoryDispatchOperation> restoreData(
    Map data, {
    required int actualStoryUs,
    required int actualUpdateIndex,
    required bool paused,
    Map<String, String>? actualPacketHashes,
  }) => restore(
    decodeSnapshotData(data, actualPacketHashes: actualPacketHashes),
    actualStoryUs: actualStoryUs,
    actualUpdateIndex: actualUpdateIndex,
    paused: paused,
  );

  StoryFramePlaybackSnapshot decodeSnapshotData(
    Map data, {
    Map<String, String>? actualPacketHashes,
  }) {
    _open();
    final savedInstances = data['instances'] as Map;
    final version = data['version'] as int;
    if (StorySourceIdentity.fromJson(data['source'] as Map) != sourceIdentity) {
      throw const FormatException('frame_data_source');
    }
    final savedRefs = savedInstances.keys.cast<String>().toSet();
    final catalog = actualSnapshotCatalog;
    if (catalog == null) {
      if ((version != 1 && version != 2) ||
          savedInstances.length != _instances.length ||
          !_instances.keys.every(savedInstances.containsKey)) {
        throw const FormatException('frame_data_source');
      }
    } else {
      if (actualPacketHashes == null) {
        throw const FormatException('frame_snapshot_packet_hashes_missing');
      }
      catalog.validateRestore(
        version: version,
        savedRefs: savedRefs,
        savedPacketHashes: actualPacketHashes,
        savedDefinitionFingerprints: data['definitionFingerprints'],
      );
    }
    double number(Object? value) {
      final result = (value as num).toDouble();
      if (!result.isFinite) {
        throw const FormatException('frame_data_number');
      }
      return result;
    }

    final instances = <String, _Instance>{};
    for (final ref in savedRefs) {
      final current = _instances[ref];
      if (current == null) {
        throw FormatException('frame_snapshot_definition_missing:$ref');
      }
      final saved = savedInstances[ref] as Map, source = current.source;
      final poses = saved['poses'] as Map;
      final state = saved['state'] as String?;
      if (poses.length != source.initialPoses.length ||
          !source.initialPoses.keys.every(poses.containsKey) ||
          (state != null && !source.states.containsKey(state))) {
        throw const FormatException('frame_data_instance');
      }
      final instance = _Instance(source);
      instance.poses = {
        for (final p in poses.entries)
          p.key as String: StoryFramePose.fromData(p.value as Map),
      };
      instance.state = state;
      instance.seconds = number(saved['seconds']);
      instance.speed = number(saved['speed']);
      if (instance.seconds < 0 || instance.speed <= 0) {
        throw const FormatException('frame_data_clock');
      }
      instance.active = saved['active'] as bool;
      instance.particleSeconds = number(saved['particleSeconds'] ?? 0);
      instance.particleRunId = saved['particleRunId'] as int? ?? 0;
      if (instance.particleSeconds < 0 || instance.particleRunId < 0) {
        throw const FormatException('frame_particle_snapshot_clock');
      }
      instances[ref] = instance;
    }
    final operations = <_Operation>[];
    final operationIds = <int>{};
    final nextOperation = data['nextOperation'] as int;
    if (nextOperation < 0) {
      throw const FormatException('frame_data_operation_counter');
    }
    for (final raw in data['operations'] as List) {
      final saved = raw as Map;
      final op = _Operation(
        id: saved['id'] as int,
        commandIndex: saved['commandIndex'] as int,
        executionId: saved['executionId'] as int?,
        ref: saved['ref'] as String,
        namedState: saved['namedState'] as String,
        fade: number(saved['fade']),
        delay: number(saved['delay']),
        wait: saved['wait'] as bool,
        updateIndex: saved['updateIndex'] as int,
      );
      if (!savedRefs.contains(op.ref) ||
          op.id < 0 ||
          op.id >= nextOperation ||
          !operationIds.add(op.id)) {
        throw FormatException('frame_data_operation:${op.id}:${op.ref}');
      }
      op.elapsed = number(saved['elapsed']);
      op.from = number(saved['from']);
      op.target = number(saved['target']);
      op.hiding = saved['hiding'] as bool;
      op.tweenStarted = saved['tweenStarted'] as bool;
      op.phase = _Phase.values.byName(saved['phase'] as String);
      operations.add(op);
    }
    final order = List<String>.from(data['order'] as List);
    final current = data['currentRef'] as String?;
    if (order.length != savedRefs.length ||
        order.toSet().length != order.length ||
        !order.every(savedRefs.contains) ||
        (current != null && !savedRefs.contains(current))) {
      throw const FormatException('frame_data_order');
    }
    final storyUs = data['storyUs'] as int;
    final updateIndex = data['updateIndex'] as int;
    _inputs(storyUs, 1, updateIndex);
    final warnings = List<String>.from(data['warnings'] as List);
    for (final ref in _definitionOrder) {
      if (!savedRefs.contains(ref)) {
        instances[ref] = _Instance(_instances[ref]!.source);
        order.add(ref);
      }
    }
    return StoryFramePlaybackSnapshot._(
      sourceIdentity,
      sourceEpoch,
      storyUs,
      updateIndex,
      current,
      List.of(order),
      instances,
      operations,
      nextOperation,
      data['paused'] as bool,
      warnings,
      definitionFingerprints: actualSnapshotCatalog?.definitionFingerprints,
    );
  }
}
