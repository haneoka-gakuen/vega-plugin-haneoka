import 'dart:math' as math;

import 'cubism_fade_curve.dart';

/// Source-only animation data; native parameter indices are bound by the host.
final class NativeCubismFadeDefinition {
  NativeCubismFadeDefinition(Map source)
    : fadeIn = _number(source['FadeInTime']),
      fadeOut = _number(source['FadeOutTime']),
      duration = _number(source['MotionLength']),
      fadeIns = List.unmodifiable(
        (source['ParameterFadeInTimes'] as List).map(_number),
      ) {
    final ids = (source['ParameterIds'] as List).cast<String>();
    final raw = source['ParameterCurves'] as List;
    final fadeOuts = (source['ParameterFadeOutTimes'] as List)
        .map(_number)
        .toList();
    if (ids.length != raw.length ||
        ids.length != fadeIns.length ||
        ids.length != fadeOuts.length) {
      throw const FormatException('cubism_fade_channels');
    }
    channels = List.unmodifiable([
      for (var i = 0; i < ids.length; i++)
        NativeCubismFadeChannelDefinition(
          ids[i],
          raw[i],
          fadeIns[i],
          fadeOuts[i],
        ),
    ]);
  }

  final double fadeIn, fadeOut, duration;
  final List<double> fadeIns;
  late final List<NativeCubismFadeChannelDefinition> channels;
}

final class NativeCubismFadeChannelDefinition {
  NativeCubismFadeChannelDefinition(
    this.parameter,
    this._source,
    this.fadeIn,
    this.fadeOut,
  ) {
    try {
      _curve = NativeCubismFadeCurve(_source as Map);
    } on FormatException {
      // An absent native parameter never consumed this curve in the source.
    } on TypeError {
      // Keep the same source error conditional on the actual native binding.
    }
  }

  final String parameter;
  final Object? _source;
  final double fadeIn, fadeOut;
  NativeCubismFadeCurve? _curve;
  NativeCubismFadeCurve get curve =>
      _curve ?? NativeCubismFadeCurve(_source as Map);
}

final class NativeCubismExpressionDefinition {
  NativeCubismExpressionDefinition(Map source)
    : name = (source['m_Name'] as String).replaceFirst(RegExp(r'\.exp3$'), ''),
      fadeIn = math.max(
        0,
        _number(source['FadeInTime']) < 0 ? 1 : _number(source['FadeInTime']),
      ),
      fadeOut = math.max(
        0,
        _number(source['FadeOutTime']) < 0 ? 1 : _number(source['FadeOutTime']),
      ),
      parameters = List.unmodifiable([
        for (final row in (source['Parameters'] as List).cast<Map>())
          NativeCubismExpressionParameterDefinition(row),
      ]);

  final String name;
  final double fadeIn, fadeOut;
  final List<NativeCubismExpressionParameterDefinition> parameters;
}

final class NativeCubismExpressionParameterDefinition {
  NativeCubismExpressionParameterDefinition(Map source)
    : id = source['Id'],
      _sourceValue = source['Value'],
      _sourceBlend = source['Blend'] {
    final value = _sourceValue;
    if (value is num && value.isFinite) _value = value.toDouble();
  }

  final Object? id, _sourceValue, _sourceBlend;
  double? _value;
  double get value => _value ?? _number(_sourceValue);
  int get blend => _sourceBlend as int;
}

double _number(Object? value) {
  if (value is! num || !value.isFinite) {
    throw const FormatException('cubism_source_number');
  }
  return value.toDouble();
}
