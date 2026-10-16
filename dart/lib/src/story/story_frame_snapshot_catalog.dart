final class StoryFrameSnapshotCatalog {
  StoryFrameSnapshotCatalog._(
    this.sourceId,
    this.definitionFingerprints,
    this.packetHashes,
    this._legacy,
  );

  static const resourceNames = {
    'frames-source.json',
    'yume-frames-source.json',
    'frame-shader-metadata.json',
    'yume-frame-shader-bindings.json',
    'frame-canvas-scaler.json',
    'frame-view-root.json',
    'frame-tiled-texture-wrap.json',
  };
  static const _definitionPackets = {
    'frames-source.json',
    'yume-frames-source.json',
  };
  static final _sha256 = RegExp(r'^[a-f0-9]{64}$');

  final String sourceId;
  final Map<String, String> definitionFingerprints, packetHashes;
  final List<_LegacyFrameCatalog> _legacy;

  factory StoryFrameSnapshotCatalog.fromRaw(
    Map data, {
    required String sourceId,
    required Iterable<String> definitionRefs,
    required Map<String, String> actualPacketHashes,
  }) {
    if (data['schema'] != 'haneoka-frame-snapshot-catalog-v1' ||
        data['sourceId'] != sourceId) {
      throw const FormatException('frame_snapshot_catalog_source');
    }
    final current = _hashMap(data['currentDefinitions'], 'currentDefinitions');
    _sameKeys(current.keys.toSet(), definitionRefs.toSet(), 'definitions');
    final hashes = _resourceHashes(actualPacketHashes);
    final legacy = <_LegacyFrameCatalog>[];
    for (final raw in data['legacyCatalogs'] as List) {
      final row = raw as Map;
      final versions = (row['versions'] as List).cast<int>().toSet();
      if (versions.isEmpty ||
          versions.any((value) => value != 1 && value != 2)) {
        throw const FormatException('frame_snapshot_catalog_legacy_versions');
      }
      final oldHashes = _resourceHashes(row['packetHashes']);
      final definitions = _hashMap(row['definitions'], 'legacyDefinitions');
      for (final entry in definitions.entries) {
        if (current[entry.key] != entry.value) {
          throw FormatException(
            'frame_snapshot_catalog_definition:${entry.key}',
          );
        }
      }
      if (legacy.any((old) => _sameMap(old.packetHashes, oldHashes))) {
        throw const FormatException('frame_snapshot_catalog_duplicate');
      }
      legacy.add(_LegacyFrameCatalog(versions, oldHashes, definitions));
    }
    return StoryFrameSnapshotCatalog._(
      sourceId,
      current,
      hashes,
      List.unmodifiable(legacy),
    );
  }

  void validateRestore({
    required int version,
    required Set<String> savedRefs,
    required Map<String, String> savedPacketHashes,
    Object? savedDefinitionFingerprints,
  }) {
    final hashes = _resourceHashes(savedPacketHashes);
    for (final name in resourceNames.difference(_definitionPackets)) {
      if (hashes[name] != packetHashes[name]) {
        throw FormatException('frame_snapshot_resource_hash:$name');
      }
    }
    if (version == 3) {
      final saved = _hashMap(savedDefinitionFingerprints, 'savedDefinitions');
      _sameKeys(saved.keys.toSet(), savedRefs, 'savedDefinitions');
      for (final entry in saved.entries) {
        if (definitionFingerprints[entry.key] != entry.value) {
          throw FormatException('frame_snapshot_definition:${entry.key}');
        }
      }
      return;
    }
    if (version != 1 && version != 2) {
      throw FormatException('frame_snapshot_version:$version');
    }
    for (final old in _legacy) {
      if (old.versions.contains(version) &&
          _sameMap(old.packetHashes, hashes)) {
        _sameKeys(old.definitions.keys.toSet(), savedRefs, 'legacyDefinitions');
        return;
      }
    }
    throw FormatException(
      'frame_snapshot_legacy_packet_signature:'
      'frames-source.json=${hashes['frames-source.json']},'
      'yume-frames-source.json=${hashes['yume-frames-source.json']}',
    );
  }

  static Map<String, String> _hashMap(Object? raw, String field) {
    if (raw is! Map) throw FormatException('frame_snapshot_catalog_map:$field');
    final result = <String, String>{};
    for (final entry in raw.entries) {
      if (entry.key is! String ||
          entry.value is! String ||
          !_sha256.hasMatch(entry.value as String)) {
        throw FormatException(
          'frame_snapshot_catalog_hash:$field:${entry.key}',
        );
      }
      result[entry.key as String] = entry.value as String;
    }
    return Map.unmodifiable(result);
  }

  static Map<String, String> _resourceHashes(Object? raw) {
    final hashes = _hashMap(raw, 'packetHashes');
    _sameKeys(hashes.keys.toSet(), resourceNames, 'packetHashes');
    return hashes;
  }

  static void _sameKeys(
    Set<String> actual,
    Set<String> expected,
    String field,
  ) {
    if (actual.length != expected.length || !actual.containsAll(expected)) {
      throw FormatException(
        'frame_snapshot_catalog_keys:$field:'
        'missing=${expected.difference(actual).join(',')}:'
        'unknown=${actual.difference(expected).join(',')}',
      );
    }
  }

  static bool _sameMap(Map<String, String> a, Map<String, String> b) =>
      a.length == b.length &&
      a.entries.every((entry) => b[entry.key] == entry.value);
}

final class _LegacyFrameCatalog {
  _LegacyFrameCatalog(this.versions, this.packetHashes, this.definitions);
  final Set<int> versions;
  final Map<String, String> packetHashes, definitions;
}
