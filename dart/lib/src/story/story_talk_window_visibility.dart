import 'dart:typed_data';

import 'story_scene_state.dart';

Map<String, Object?> _map(Object? value) =>
    Map<String, Object?>.from(value as Map);
double _number(Object? value) => value is num && value.isFinite
    ? value.toDouble()
    : throw const FormatException('talk_visibility_number');
String _id(Object? pointer) => _map(pointer)['m_PathID'].toString();
bool _flag(Object? value) => switch (value) {
  true || 1 => true,
  false || 0 => false,
  _ => throw const FormatException('talk_visibility_flag'),
};
final _slot = Float32List(1);
double _f(double value) {
  _slot[0] = value;
  return _slot[0];
}

List<double> _color(Object? value) {
  final raw = _map(value);
  return List.unmodifiable([
    for (final key in ['r', 'g', 'b', 'a']) _number(raw[key]),
  ]);
}

Object? _freeze(Object? value) => switch (value) {
  Map() => Map<String, Object?>.unmodifiable(
    value.map((key, item) => MapEntry(key as String, _freeze(item))),
  ),
  List() => List<Object?>.unmodifiable(value.map(_freeze)),
  _ => value,
};

final class StoryTalkTextStyle {
  StoryTalkTextStyle(
    this.targetTextId,
    List<double> textColor,
    List<double> outlineColor,
  ) : textColor = List.unmodifiable(textColor),
      outlineColor = List.unmodifiable(outlineColor);
  final String targetTextId;
  final List<double> textColor, outlineColor;
}

final class StoryTalkWindowVisibilitySource {
  StoryTalkWindowVisibilitySource._(
    this.mode,
    this.sourceUiPath,
    this.sourceUiHash,
    this.rootGameObjectId,
    this.talkAreaGameObjectId,
    this.backgroundGroupId,
    this.backgroundGameObjectId,
    this.backgroundInitialAlpha,
    this.backgroundInitiallyActive,
    this.useBackdropFilter,
    this.style,
    this.backdropFilterColor,
    this.original,
  );
  final String mode,
      sourceUiPath,
      sourceUiHash,
      rootGameObjectId,
      talkAreaGameObjectId;
  final String? backgroundGroupId, backgroundGameObjectId;
  final double backgroundInitialAlpha;
  final bool backgroundInitiallyActive, useBackdropFilter;

  /// Null means preserve the actual TMP font colour and original material.
  final StoryTalkTextStyle? style;
  final List<double> backdropFilterColor;
  final Map<String, Object?> original;
  factory StoryTalkWindowVisibilitySource.fromRaw(
    String mode,
    Map<String, Object?> entry, {
    required Map<String, Object?> actualScriptMetadata,
  }) {
    final frozen = _freeze(entry) as Map<String, Object?>;
    final controller = _map(frozen['controller']),
        raw = _map(controller['data']);
    final source = _map(frozen['source']);
    final pointer = _map(raw['m_Script']), ref = _map(pointer['reference']);
    final scriptRecord = _map(
      actualScriptMetadata['${ref['serializedFile']}:${ref['pathId']}'],
    );
    final script = _map(scriptRecord['data']);
    if (ref['name'] != 'UIAdvTalkWindow' ||
        scriptRecord['pathId'] != ref['pathId'] ||
        scriptRecord['serializedFile'] != ref['serializedFile'] ||
        script['m_ClassName'] != 'UIAdvTalkWindow' ||
        script['m_Namespace'] != 'AdvSystem.UI' ||
        script['m_AssemblyName'] != 'Adv') {
      throw const FormatException('talk_visibility_controller_script');
    }
    final root = _map(frozen['root']), rootGo = _map(root['gameObject']);
    if (_id(raw['m_GameObject']) != rootGo['pathId']) {
      throw const FormatException('talk_visibility_root_identity');
    }
    final references = _map(frozen['references']);
    Map<String, Object?>? endpoint(String field, String type) {
      final bound = _map(references[field]);
      if (_id(bound['pointer']) != _id(raw[field])) {
        throw const FormatException('talk_visibility_reference_identity');
      }
      if (_id(raw[field]) == '0') {
        if (bound['endpoint'] != null) {
          throw const FormatException('talk_visibility_null_reference');
        }
        return null;
      }
      final ep = _map(bound['endpoint']), object = _map(ep['object']);
      if (object['pathId'] != _id(raw[field]) ||
          object['serializedFile'] != controller['serializedFile'] ||
          object['type'] != type) {
        throw const FormatException('talk_visibility_reference_type');
      }
      return ep;
    }

    final area = endpoint('TalkArea', 'GameObject');
    if (area == null) {
      throw const FormatException('talk_visibility_area_missing');
    }
    final background = endpoint('_talkBackground', 'CanvasGroup');
    var alpha = 0.0, backgroundActive = false;
    String? backgroundGroup, backgroundGo;
    if (background != null) {
      final object = _map(background['object']),
          data = _map(object['data']),
          go = _map(background['gameObject']);
      if (_id(data['m_GameObject']) != go['pathId'] ||
          !_flag(data['m_Enabled']) ||
          _flag(data['m_IgnoreParentGroups'])) {
        throw UnsupportedError('talk_visibility_background_group_recipe');
      }
      backgroundGroup = object['pathId'] as String;
      backgroundGo = go['pathId'] as String;
      alpha = _number(data['m_Alpha']);
      backgroundActive = _flag(_map(go['data'])['m_IsActive']);
    }
    final useBackdrop = _flag(raw['_useBackdropFilter']);
    StoryTalkTextStyle? style;
    final text = endpoint('TalkText', 'MonoBehaviour');
    if (useBackdrop && text != null) {
      final textRaw = _map(_map(text['object'])['data']);
      final target = _id(textRaw['_targetText']);
      final components = (text['components'] as List).cast<Map>();
      if (target == '0' ||
          components.where((c) => c['pathId'] == target).length != 1) {
        throw const FormatException('talk_visibility_style_target');
      }
      style = StoryTalkTextStyle(
        target,
        _color(raw['_talkTextColor']),
        _color(raw['_talkTextOutlineColor']),
      );
    }
    final path = source['sourceUiPath'] as String,
        hash = source['sourceUiHash'] as String;
    if (mode.isEmpty ||
        path.isEmpty ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
      throw const FormatException('talk_visibility_source_identity');
    }
    return StoryTalkWindowVisibilitySource._(
      mode,
      path,
      hash,
      rootGo['pathId'] as String,
      _map(area['object'])['pathId'] as String,
      backgroundGroup,
      backgroundGo,
      alpha,
      backgroundActive,
      useBackdrop,
      style,
      _color(raw['_backdropFilterColor']),
      frozen,
    );
  }
}

final class StoryTalkBackdropSource {
  StoryTalkBackdropSource._(
    this.groupId,
    this.gameObjectId,
    this.imageId,
    this.initialAlpha,
    this.initialColor,
  );
  final String groupId, gameObjectId, imageId;
  final double initialAlpha;
  final List<double> initialColor;
  factory StoryTalkBackdropSource.fromRaw(
    Map<String, Object?> actualReferences,
  ) {
    final groupBinding = _map(
      actualReferences['_centerTalkBackdropCanvasGroup'],
    );
    final imageBinding = _map(actualReferences['_centerTalkBackdropImage']);
    final group = _map(_map(groupBinding['endpoint'])['object']);
    final image = _map(_map(imageBinding['endpoint'])['object']);
    final cg = _map(group['data']), im = _map(image['data']);
    if (group['type'] != 'CanvasGroup' ||
        image['type'] != 'MonoBehaviour' ||
        group['pathId'] != _id(groupBinding['pointer']) ||
        image['pathId'] != _id(imageBinding['pointer']) ||
        _id(cg['m_GameObject']) != _id(im['m_GameObject']) ||
        !_flag(cg['m_Enabled']) ||
        !_flag(im['m_Enabled'])) {
      throw const FormatException('talk_visibility_backdrop_identity');
    }
    return StoryTalkBackdropSource._(
      group['pathId'] as String,
      _id(cg['m_GameObject']),
      image['pathId'] as String,
      _number(cg['m_Alpha']),
      _color(im['m_Color']),
    );
  }
}

final class StoryTalkWindowVisibilityFrame {
  StoryTalkWindowVisibilityFrame._(_Window state)
    : source = state.source,
      rootActive = state.rootActive,
      talkAreaActive = state.showing,
      backgroundAlpha = state.alpha,
      backgroundInitiallyActive = state.source.backgroundInitiallyActive;
  final StoryTalkWindowVisibilitySource source;
  final bool rootActive, talkAreaActive, backgroundInitiallyActive;
  final double backgroundAlpha;
  StoryTalkTextStyle? get style => source.style;
}

final class StoryTalkVisibilityFrame {
  StoryTalkVisibilityFrame._(
    this.sourceIdentity,
    this.sourceEpoch,
    this.actualStoryUs,
    this.actualUpdateIndex,
    this.currentMode,
    this.windows,
    this.backdropSource,
    this.backdropAlpha,
    this.backdropColor,
  );
  final StorySourceIdentity sourceIdentity;
  final int sourceEpoch, actualStoryUs, actualUpdateIndex;
  final String? currentMode;
  final Map<String, StoryTalkWindowVisibilityFrame> windows;
  final StoryTalkBackdropSource? backdropSource;
  final double backdropAlpha;
  final List<double>? backdropColor;
  StoryTalkWindowVisibilityFrame? get current => windows[currentMode];
}

final class _Fade {
  _Fade(this.to, this.duration);
  final double to, duration;
  double elapsed = 0, from = 0, change = 0;
  bool started = false;
  double step(double alpha, double dt) {
    if (!started) {
      from = _f(alpha);
      change = _f(_f(to) - from);
      started = true;
    }
    elapsed = _f(elapsed + _f(dt));
    if (elapsed >= duration) elapsed = duration;
    final t = _f(elapsed / duration), ease = _f(-_f(t * _f(t - 2)));
    return _f(from + _f(change * ease));
  }

  bool get done => elapsed >= duration;
  _Fade copy() {
    final result = _Fade(to, duration);
    result.elapsed = elapsed;
    result.from = from;
    result.change = change;
    result.started = started;
    return result;
  }
}

final class _Window {
  _Window(this.source) : alpha = source.backgroundInitialAlpha;
  final StoryTalkWindowVisibilitySource source;
  bool rootActive = false, showing = false;
  double alpha;
  _Fade? fade;
  _Window copy() {
    final result = _Window(source);
    result.rootActive = rootActive;
    result.showing = showing;
    result.alpha = alpha;
    result.fade = fade?.copy();
    return result;
  }
}

final class StoryTalkVisibilitySnapshot {
  StoryTalkVisibilitySnapshot._(
    this.identity,
    this.epoch,
    this.us,
    this.index,
    this.currentMode,
    this._windows,
    this.backdropAlpha,
    this.backdropColor,
    this._backdropFade,
    this.paused,
  );
  final StorySourceIdentity identity;
  final int epoch, us, index;
  final String? currentMode;
  final Map<String, _Window> _windows;
  final double backdropAlpha;
  final List<double>? backdropColor;
  final _Fade? _backdropFade;
  final bool paused;
  Map<String, Object?> toData() {
    Map<String, Object?>? fade(_Fade? f) => f == null
        ? null
        : {
            'to': f.to,
            'duration': f.duration,
            'elapsed': f.elapsed,
            'from': f.from,
            'change': f.change,
            'started': f.started,
          };
    return {
      'version': 1,
      'source': identity.toJson(),
      'us': us,
      'index': index,
      'currentMode': currentMode,
      'backdropAlpha': backdropAlpha,
      'backdropColor': backdropColor,
      'backdropFade': fade(_backdropFade),
      'paused': paused,
      'windows': {
        for (final e in _windows.entries)
          e.key: {
            'path': e.value.source.sourceUiPath,
            'hash': e.value.source.sourceUiHash,
            'rootActive': e.value.rootActive,
            'showing': e.value.showing,
            'alpha': e.value.alpha,
            'fade': fade(e.value.fade),
          },
      },
    };
  }
}

/// UI-only fade clock: latest real latched Update pair, unscaled active time.
/// Playback-speed changes do not rescale the 0.2-second UI tween or restart it.
final class StoryTalkWindowVisibility {
  StoryTalkWindowVisibility({
    required this.sourceIdentity,
    required this.sourceEpoch,
    required Map<String, StoryTalkWindowVisibilitySource> actualSources,
    required double actualDefaultFadeSeconds,
    required int actualFadeEase,
    required this.actualBackdropSource,
    required int actualStoryUs,
    required int actualUpdateIndex,
  }) : defaultFadeSeconds = _f(actualDefaultFadeSeconds),
       _us = actualStoryUs,
       _index = actualUpdateIndex,
       _backdropAlpha = actualBackdropSource?.initialAlpha ?? 0,
       _backdropColor = actualBackdropSource?.initialColor {
    if (sourceEpoch < 0 ||
        actualStoryUs < 0 ||
        actualUpdateIndex < 0 ||
        !actualDefaultFadeSeconds.isFinite ||
        actualDefaultFadeSeconds <= 0) {
      throw const FormatException('talk_visibility_inputs');
    }
    if (actualFadeEase != 6) {
      throw UnsupportedError('talk_visibility_ease:$actualFadeEase');
    }
    for (final entry in actualSources.entries) {
      if (entry.key != entry.value.mode) {
        throw const FormatException('talk_visibility_mode_identity');
      }
      if (entry.value.useBackdropFilter && actualBackdropSource == null) {
        throw const FormatException('talk_visibility_backdrop_missing');
      }
      _windows[entry.key] = _Window(entry.value);
    }
  }
  final StorySourceIdentity sourceIdentity;
  final int sourceEpoch;
  final double defaultFadeSeconds;
  final StoryTalkBackdropSource? actualBackdropSource;
  final _windows = <String, _Window>{};
  int _us, _index;
  String? _currentMode;
  double _backdropAlpha;
  List<double>? _backdropColor;
  _Fade? _backdropFade;
  bool _paused = false, _closed = false;
  void _open() {
    if (_closed) throw StateError('talk_visibility_closed');
  }

  StoryTalkVisibilityFrame get frame => StoryTalkVisibilityFrame._(
    sourceIdentity,
    sourceEpoch,
    _us,
    _index,
    _currentMode,
    Map.unmodifiable({
      for (final entry in _windows.entries)
        entry.key: StoryTalkWindowVisibilityFrame._(entry.value),
    }),
    actualBackdropSource,
    _backdropAlpha,
    _backdropColor == null ? null : List.unmodifiable(_backdropColor!),
  );
  void _setShowing(_Window window, bool showing, double duration) {
    window.showing = showing;
    if (window.source.backgroundGroupId == null) return;
    final to = showing ? 1.0 : 0.0;
    if (window.fade?.to == to) return;
    window.fade = null;
    if (showing ? window.alpha >= 1 : window.alpha <= 0) return;
    if (duration > 0) {
      window.fade = _Fade(to, _f(duration));
    } else {
      window.alpha = to;
    }
  }

  void attachWindow(String mode) {
    _open();
    final next = _windows[mode];
    if (next == null) throw UnsupportedError('talk_visibility_window:$mode');
    final old = _windows[_currentMode];
    if (old == null) {
      _setShowing(next, false, 0);
    } else {
      final backgroundShowing =
          old.showing && old.source.backgroundGroupId != null && old.alpha > 0;
      next.showing = old.showing;
      _setShowing(next, backgroundShowing, 0);
      old.rootActive = false;
    }
    _currentMode = mode;
    next.rootActive = true;
    _updateBackdrop();
  }

  void showTalk() {
    _open();
    final current = _windows[_currentMode];
    if (current != null) _setShowing(current, true, defaultFadeSeconds);
    _updateBackdrop();
  }

  void hideTalk() {
    _open();
    final current = _windows[_currentMode];
    if (current != null) _setShowing(current, false, defaultFadeSeconds);
    _updateBackdrop();
  }

  void refresh() {
    _open();
    final current = _windows[_currentMode];
    if (current != null) {
      _setShowing(current, false, 0);
      current.fade = null;
    }
    _backdropFade = null;
    _backdropAlpha = 0;
  }

  void _updateBackdrop() {
    if (actualBackdropSource == null) return;
    _backdropFade = null;
    final current = _windows[_currentMode];
    if (current == null ||
        !current.source.useBackdropFilter ||
        !current.showing) {
      _backdropAlpha = 0;
      return;
    }
    _backdropColor = current.source.backdropFilterColor;
    final delta = (1 - _backdropAlpha).abs();
    final magnitude = _backdropAlpha.abs() > 1 ? _backdropAlpha.abs() : 1.0;
    final relative = _f(magnitude * 1e-6),
        absolute = _f(1.401298464324817e-45 * 8);
    if (delta < (relative > absolute ? relative : absolute)) return;
    _backdropFade = _Fade(1, defaultFadeSeconds);
  }

  StoryTalkVisibilityFrame update(
    int actualStoryUs, {
    required int actualUpdateIndex,
    required bool paused,
    required int epoch,
  }) {
    _open();
    if (epoch != sourceEpoch) {
      close();
      throw StateError('talk_visibility_epoch');
    }
    if (actualStoryUs < _us || actualUpdateIndex < _index) {
      throw const FormatException('talk_visibility_clock_reversed');
    }
    if (actualUpdateIndex == _index) {
      if (actualStoryUs != _us) {
        throw const FormatException('talk_visibility_unlatched_clock');
      }
      _paused = paused;
      return frame;
    }
    final dt = (actualStoryUs - _us) / 1000000;
    _us = actualStoryUs;
    _index = actualUpdateIndex;
    _paused = paused;
    if (paused) return frame;
    for (final window in _windows.values) {
      final fade = window.fade;
      if (fade != null) {
        window.alpha = fade.step(window.alpha, dt);
        if (fade.done) window.fade = null;
      }
    }
    final backdropFade = _backdropFade;
    if (backdropFade != null) {
      _backdropAlpha = backdropFade.step(_backdropAlpha, dt);
      if (backdropFade.done) _backdropFade = null;
    }
    return frame;
  }

  StoryTalkVisibilitySnapshot snapshot() => StoryTalkVisibilitySnapshot._(
    sourceIdentity,
    sourceEpoch,
    _us,
    _index,
    _currentMode,
    Map.unmodifiable({
      for (final entry in _windows.entries) entry.key: entry.value.copy(),
    }),
    _backdropAlpha,
    _backdropColor,
    _backdropFade?.copy(),
    _paused,
  );
  void restore(StoryTalkVisibilitySnapshot snapshot) {
    _open();
    if (snapshot.identity != sourceIdentity || snapshot.epoch != sourceEpoch) {
      throw const FormatException('talk_visibility_snapshot_source');
    }
    _windows
      ..clear()
      ..addAll({
        for (final entry in snapshot._windows.entries)
          entry.key: entry.value.copy(),
      });
    _us = snapshot.us;
    _index = snapshot.index;
    _currentMode = snapshot.currentMode;
    _backdropAlpha = snapshot.backdropAlpha;
    _backdropColor = snapshot.backdropColor;
    _backdropFade = snapshot._backdropFade?.copy();
    _paused = snapshot.paused;
  }

  Map<String, Object?> snapshotData() => snapshot().toData();
  void restoreData(
    Map data, {
    required int actualStoryUs,
    required int actualUpdateIndex,
    required bool paused,
  }) {
    final windows = data['windows'] as Map;
    if (data['version'] != 1 ||
        StorySourceIdentity.fromJson(data['source'] as Map) != sourceIdentity ||
        windows.length != _windows.length ||
        !_windows.keys.every(windows.containsKey) ||
        actualStoryUs < 0 ||
        actualUpdateIndex < 0) {
      throw const FormatException('talk_visibility_data_source');
    }
    _Fade? fade(Object? value) {
      if (value == null) {
        return null;
      }
      final f = value as Map;
      return _Fade(_number(f['to']), _number(f['duration']))
        ..elapsed = _number(f['elapsed'])
        ..from = _number(f['from'])
        ..change = _number(f['change'])
        ..started = f['started'] as bool;
    }

    final restored = <String, _Window>{};
    for (final e in _windows.entries) {
      final saved = windows[e.key] as Map, source = e.value.source;
      if (saved['path'] != source.sourceUiPath ||
          saved['hash'] != source.sourceUiHash) {
        throw const FormatException('talk_visibility_data_window');
      }
      restored[e.key] = _Window(source)
        ..rootActive = saved['rootActive'] as bool
        ..showing = saved['showing'] as bool
        ..alpha = _number(saved['alpha'])
        ..fade = fade(saved['fade']);
    }
    final mode = data['currentMode'] as String?;
    if (mode != null && !restored.containsKey(mode)) {
      throw const FormatException('talk_visibility_data_mode');
    }
    restore(
      StoryTalkVisibilitySnapshot._(
        sourceIdentity,
        sourceEpoch,
        actualStoryUs,
        actualUpdateIndex,
        mode,
        restored,
        _number(data['backdropAlpha']),
        data['backdropColor'] == null
            ? null
            : [for (final v in data['backdropColor'] as List) _number(v)],
        fade(data['backdropFade']),
        paused,
      ),
    );
  }

  void close() {
    if (_closed) return;
    for (final window in _windows.values) {
      window.fade = null;
    }
    _backdropFade = null;
    _closed = true;
  }
}
