import 'dart:convert';

const _componentAliases = <String, String>{
  'colorsplittoning': 'splittoning',
  'advcurvedlens': 'curvedlens',
};

String _componentName(String name) {
  final key = name.replaceAll(RegExp('[^a-zA-Z0-9]'), '').toLowerCase();
  return _componentAliases[key] ?? key;
}

Object? _freeze(Object? value) => switch (value) {
  Map map => Map<String, Object?>.unmodifiable({
    for (final entry in map.entries) '${entry.key}': _freeze(entry.value),
  }),
  List list => List<Object?>.unmodifiable(list.map(_freeze)),
  _ => value,
};

final class StoryPostSettings {
  StoryPostSettings._(Map<String, Map<String, Object?>> values, Map? curved)
    : components = Map.unmodifiable({
        for (final entry in values.entries)
          entry.key: _freeze(entry.value) as Map<String, Object?>,
      }),
      curvedLens = values['curvedlens'] == null && curved == null
          ? null
          : _freeze(values['curvedlens'] ?? curved) as Map<String, Object?>;

  /// The source default profile supplies the stack's initial parameter values.
  factory StoryPostSettings.fromDefaultProfile(Map profile) {
    final components = <String, Map<String, Object?>>{};
    for (final component in _profileComponents(profile)) {
      final values = <String, Object?>{
        'active': component['active'] != false && component['active'] != 0,
      };
      for (final entry in (component['fields'] as Map).entries) {
        final field = entry.value as Map;
        if (field.containsKey('value')) values['${entry.key}'] = field['value'];
      }
      components[_componentName(component['name'] as String)] = values;
    }
    return StoryPostSettings._(components, profile['curvedLens'] as Map?);
  }

  final Map<String, Map<String, Object?>> components;
  final Map<String, Object?>? curvedLens;
  Map<String, Object?> component(String name) =>
      components[_componentName(name)] ?? const {};

  late final String gradingKey = jsonEncode({
    for (final name in const [
      'whitebalance',
      'coloradjustments',
      'channelmixer',
      'liftgammagain',
      'shadowsmidtoneshighlights',
      'splittoning',
      'colorcurves',
    ])
      name: name == 'coloradjustments'
          ? {
              for (final entry
                  in (components[name] ?? const <String, Object?>{}).entries)
                if (entry.key != 'postExposure') entry.key: entry.value,
            }
          : components[name],
  });
}

final class _VolumeLayer {
  _VolumeLayer(
    this.profile,
    this.weight,
    this.priority,
    this.order,
    this.enabled,
  );
  final Map profile;
  double weight, priority;
  final int order;
  bool enabled;
  _VolumeLayer copy() =>
      _VolumeLayer(profile, weight, priority, order, enabled);
}

final class StoryPostVolumeSnapshot {
  StoryPostVolumeSnapshot._(this._owner, this._restore);
  final StoryPostVolumeState _owner;
  final void Function() _restore;
}

/// Unity's ordered global stack, isolated from source transport and scene IO.
final class StoryPostVolumeState {
  StoryPostVolumeState({required StoryPostSettings defaults})
    : _defaults = defaults;
  StoryPostSettings _defaults;
  _VolumeLayer? _stage;
  final _children = <String, _VolumeLayer>{};
  int _sequence = 0;
  StoryPostSettings? _resolved;
  Map<String, Object?> snapshotData() {
    Map<String, Object?> layer(_VolumeLayer value) => {
      'profile': value.profile,
      'weight': value.weight,
      'priority': value.priority,
      'order': value.order,
      'enabled': value.enabled,
    };
    return {
      'version': 1,
      'stage': _stage == null ? null : layer(_stage!),
      'children': {
        for (final entry in _children.entries) entry.key: layer(entry.value),
      },
      'sequence': _sequence,
    };
  }

  void restoreData(Map data) {
    if (data['version'] != 1)
      throw const FormatException('post_volume_data_version');
    _VolumeLayer layer(Map value) => _VolumeLayer(
      value['profile'] as Map,
      (value['weight'] as num).toDouble(),
      (value['priority'] as num).toDouble(),
      value['order'] as int,
      value['enabled'] as bool,
    );
    _stage = data['stage'] == null ? null : layer(data['stage'] as Map);
    _children
      ..clear()
      ..addAll({
        for (final entry in (data['children'] as Map).entries)
          entry.key as String: layer(entry.value as Map),
      });
    _sequence = data['sequence'] as int;
    _resolved = null;
  }

  StoryPostVolumeSnapshot snapshot() {
    final defaults = _defaults, stage = _stage?.copy();
    final children = {
      for (final entry in _children.entries) entry.key: entry.value.copy(),
    };
    final sequence = _sequence;
    return StoryPostVolumeSnapshot._(this, () {
      _defaults = defaults;
      _stage = stage?.copy();
      _children
        ..clear()
        ..addAll({
          for (final entry in children.entries) entry.key: entry.value.copy(),
        });
      _sequence = sequence;
      _resolved = null;
    });
  }

  void restore(StoryPostVolumeSnapshot snapshot) {
    if (!identical(snapshot._owner, this)) {
      throw const FormatException('post_volume_snapshot_owner');
    }
    snapshot._restore();
  }

  void setDefaults(StoryPostSettings defaults) {
    _defaults = defaults;
    _resolved = null;
  }

  void setStage(Map? profile, {double priority = 0, double weight = 1}) {
    _stage = profile == null
        ? null
        : _VolumeLayer(profile, weight, priority, -1, true);
    _resolved = null;
  }

  void setChild(
    String key,
    Map profile, {
    double weight = 1,
    double priority = 0,
    bool enabled = true,
  }) {
    final previous = _children[key];
    _children[key] = _VolumeLayer(
      profile,
      weight,
      priority,
      previous?.order ?? _sequence++,
      enabled,
    );
    _resolved = null;
  }

  void setWeight(String key, double weight) {
    final layer = _children[key];
    if (layer == null || layer.weight == weight) return;
    layer.weight = weight;
    _resolved = null;
  }

  void removeChild(String key) {
    if (_children.remove(key) != null) _resolved = null;
  }

  void clearChildren() {
    _children.clear();
    _resolved = null;
  }

  StoryPostSettings resolve() {
    if (_resolved case final result?) return result;
    final values = <String, Map<String, Object?>>{
      for (final entry in _defaults.components.entries)
        entry.key: Map.of(entry.value),
    };
    final layers = [if (_stage != null) _stage!, ..._children.values]
      ..sort((a, b) {
        final priority = a.priority.compareTo(b.priority);
        return priority != 0 ? priority : a.order.compareTo(b.order);
      });
    Map? curved = _defaults.curvedLens;
    for (final layer in layers) {
      final weight = layer.weight.clamp(0.0, 1.0);
      if (!layer.enabled || weight <= 0) continue;
      for (final component in _profileComponents(layer.profile)) {
        if (component['active'] == false || component['active'] == 0) continue;
        final target = values.putIfAbsent(
          _componentName(component['name'] as String),
          () => <String, Object?>{},
        );
        target['active'] = true;
        for (final entry in (component['fields'] as Map).entries) {
          final field = entry.value as Map;
          if ((field['override'] != true &&
                  field['overrideState'] != 1 &&
                  field['override'] != 1) ||
              !field.containsKey('value')) {
            continue;
          }
          final key = '${entry.key}';
          target[key] = _interpolate(target[key], field['value'], weight, key);
        }
      }
      if (layer == _stage &&
          layer.profile['curvedLens'] is Map &&
          !(layer.profile['components'] as Map? ?? const {}).values.any(
            (value) =>
                value is Map &&
                _componentName('${value['name']}') == 'curvedlens',
          )) {
        curved = layer.profile['curvedLens'] as Map;
        values['curvedlens'] = Map<String, Object?>.from(curved);
      }
    }
    return _resolved = StoryPostSettings._(values, curved);
  }
}

Iterable<Map> _profileComponents(Map profile) sync* {
  final components = profile['components'] as Map? ?? const {};
  final order = profile['componentOrder'] as List? ?? components.keys.toList();
  for (final name in order) {
    final value = components[name];
    if (value is Map) yield {...value, 'name': value['name'] ?? name};
  }
  for (final name in const ['bloom', 'splitToning']) {
    final value = profile[name];
    if (value is! Map) continue;
    yield {
      'name': name,
      'active': value['active'] != false,
      'fields': {
        for (final entry in value.entries)
          if (entry.key != 'active' &&
              !'${entry.key}'.endsWith('Override') &&
              !'${entry.key}'.endsWith('OverrideState'))
            entry.key: {
              'value': entry.value,
              'override':
                  value['${entry.key}Override'] == true ||
                  value['${entry.key}OverrideState'] == 1,
            },
      },
    };
  }
}

const _nonInterpolated = {
  'active',
  'mode',
  'quality',
  'type',
  'rounded',
  'highQualityFiltering',
  'highQualitySampling',
  'downscale',
  'filter',
  'dirtTexture',
  'texture',
  'master',
  'red',
  'green',
  'blue',
  'hueVsHue',
  'hueVsSat',
  'satVsSat',
  'lumVsSat',
};
const _integers = {'skipIterations', 'maxIterations', 'bladeCount'};

Object? _interpolate(Object? from, Object? to, double weight, String field) {
  if (_nonInterpolated.contains(field)) return to;
  if (from is num && to is num) {
    final value = from + (to - from) * weight;
    if (!_integers.contains(field)) return value;
    final lower = value.floor(), fraction = value - value.floor();
    return fraction == .5 ? (lower.isEven ? lower : lower + 1) : value.round();
  }
  if (from is Map && to is Map) {
    return {
      ...from,
      for (final entry in to.entries)
        entry.key: _interpolate(
          from[entry.key],
          entry.value,
          weight,
          '${entry.key}',
        ),
    };
  }
  return to;
}
