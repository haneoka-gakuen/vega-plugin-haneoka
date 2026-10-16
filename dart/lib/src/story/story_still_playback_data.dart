part of 'story_still_playback.dart';

extension StoryStillPlaybackSnapshotData on StoryStillPlaybackSnapshot {
  Map<String, Object?> toData() => {
    'version': 2,
    'source': sourceIdentity.toJson(),
    'storyUs': actualStoryUs,
    'speed': speed,
    'paused': paused,
    'currentRef': currentRef,
    'overlay': overlayAlpha,
    'background': backgroundAlpha,
    'suppressed': postEffectSuppressed,
    'fadeEase': fadeEase,
    'nextOperation': nextOperation,
    'order': order,
    'warnings': warnings,
    'instances': {
      for (final e in instances.entries)
        e.key: {
          'active': e.value.active,
          'alpha': e.value.alpha,
          'seconds': e.value.sequenceSeconds,
          'playing': e.value.sequencePlaying,
          'pendingSequence': e.value.pendingSequence,
          'animator': e.value.animator.toData(),
        },
    },
    'fades': [
      for (final f in _fades)
        {
          'key': f.key,
          'target': f.target.name,
          'operation': f.operationId,
          'ref': f.ref,
          'from': f.from,
          'to': f.to,
          'duration': f.duration,
          'hiding': f.hiding,
          'elapsed': f.elapsed,
          'started': f.started,
        },
    ],
    'operations': [
      for (final op in _operations)
        {
          'id': op.id,
          'commandIndex': op.commandIndex,
          'executionId': op.executionId,
          'wait': op.waitForCompletion,
          'pending': op.pending.toList(),
        },
    ],
  };
}

extension StoryStillPlaybackData on StoryStillPlayback {
  Map<String, Object?> snapshotData() => snapshot().toData();
  Map<int, StoryDispatchOperation> restoreData(
    Map data, {
    required int actualStoryUs,
    required double speed,
    required bool paused,
    required int epoch,
  }) {
    _requireOpen();
    final savedInstances = data['instances'] as Map;
    if ((data['version'] != 1 && data['version'] != 2) ||
        StorySourceIdentity.fromJson(data['source'] as Map) != sourceIdentity ||
        epoch != sourceEpoch ||
        data['fadeEase'] != actualFadeEase ||
        actualStoryUs < 0 ||
        !speed.isFinite ||
        speed <= 0 ||
        savedInstances.length != _instances.length ||
        !_instances.keys.every(savedInstances.containsKey)) {
      throw const FormatException('still_data_source');
    }
    final animatorStates = <String, StoryStillSnapshot>{};
    for (final e in savedInstances.entries) {
      final state = StoryStillSnapshot.fromData(
        (e.value as Map)['animator'] as Map,
      );
      final attachment = state.attachment;
      if (attachment.revision > 0 &&
          (attachment.packetHash != externalLayoutSource?.packetSHA256 ||
              attachment.parentId != externalLayoutSource?.targetId)) {
        throw const FormatException('still_data_external_binding');
      }
      animatorStates[e.key as String] = state;
    }
    final order = (data['order'] as List).cast<String>(),
        current = data['currentRef'] as String?;
    if (order.length != _instances.length ||
        order.toSet().length != order.length ||
        !order.every(_instances.containsKey) ||
        (current != null && !_instances.containsKey(current))) {
      throw const FormatException('still_data_order');
    }
    for (final id in _operations.keys.toList()) {
      _cancelOperation(id, 'portable_restored');
    }
    for (final e in _instances.entries) {
      final saved = savedInstances[e.key] as Map, instance = e.value;
      instance.animator.restore(animatorStates[e.key]!);
      instance.active = saved['active'] as bool;
      instance.alpha = (saved['alpha'] as num).toDouble();
      instance.seconds = (saved['seconds'] as num).toDouble();
      instance.playing = saved['playing'] as bool;
      instance.pendingSequence = saved['pendingSequence'] as String?;
    }
    _order
      ..clear()
      ..addAll(order);
    _warnings
      ..clear()
      ..addAll((data['warnings'] as List).cast<String>());
    _currentRef = current;
    _overlayAlpha = (data['overlay'] as num).toDouble();
    _backgroundAlpha = (data['background'] as num).toDouble();
    _suppressed = data['suppressed'] as bool;
    _lastStoryUs = actualStoryUs;
    _speed = speed;
    _paused = paused;
    _nextOperation = data['nextOperation'] as int;
    _fades.clear();
    for (final raw in data['fades'] as List) {
      final f = raw as Map;
      final fade = _Fade(
        key: f['key'] as String,
        target: _Target.values.byName(f['target'] as String),
        operationId: f['operation'] as int,
        ref: f['ref'] as String?,
        from: (f['from'] as num).toDouble(),
        to: (f['to'] as num).toDouble(),
        duration: (f['duration'] as num).toDouble(),
        hiding: f['hiding'] as bool,
        elapsed: (f['elapsed'] as num).toDouble(),
        started: f['started'] as bool,
      );
      _fades[fade.key] = fade;
    }
    final result = <int, StoryDispatchOperation>{};
    for (final raw in data['operations'] as List) {
      final saved = raw as Map;
      final op = _Operation(
        saved['id'] as int,
        saved['commandIndex'] as int,
        saved['executionId'] as int?,
        saved['wait'] as bool,
        (saved['pending'] as List).cast<String>().toSet(),
      );
      _operations[op.id] = op;
      result[op.id] = op.dispatched;
    }
    return Map.unmodifiable(result);
  }
}
