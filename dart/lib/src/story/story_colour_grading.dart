import 'dart:math' as math;
import 'dart:typed_data';

import 'package:haneoka_render_profile/core.dart';

import 'story_post_volume.dart';

/// CPU parameters for the formal GLES LDR LUT builder (16³, 256×16 strip).
abstract final class StoryColorGrading {
  static const size = 16, width = size * size, curveSamples = 128;
  static const uniformFloatCount = 64;
  static const curveNames = [
    'master',
    'red',
    'green',
    'blue',
    'hueVsHue',
    'hueVsSat',
    'satVsSat',
    'lumVsSat',
  ];

  static const curveSlots = [
    'curveMaster',
    'curveRed',
    'curveGreen',
    'curveBlue',
    'curveHueVsHue',
    'curveHueVsSat',
    'curveSatVsSat',
    'curveLumVsSat',
  ];

  static Map<String, Uint8List> curveTexels(StoryPostSettings state) {
    final curves = state.component('ColorCurves');
    return {
      for (var index = 0; index < curveNames.length; index++)
        curveSlots[index]: _curveBytes(
          bakeCurve(curves[curveNames[index]] as Map?, identity: index < 4),
        ),
    };
  }

  static Map<String, NativeTextureData> curveData(StoryPostSettings state) => {
    for (final entry in curveTexels(state).entries)
      entry.key: NativeTextureData(
        width: curveSamples,
        height: 1,
        rgba: entry.value,
        format: NativeTargetFormat.rgba16f,
        alpha: NativeTextureAlpha.independent,
        encoding: NativeColorEncoding.linear,
      ),
  };

  static Uint8List _curveBytes(Float32List values) {
    final data = ByteData(curveSamples * 8);
    for (var i = 0; i < curveSamples; i++) {
      data.setUint16(i * 8, _halfBits(values[i]), Endian.little);
      data.setUint16(i * 8 + 6, 0x3c00, Endian.little);
    }
    return data.buffer.asUint8List();
  }

  static int _halfBits(double value) {
    final source = ByteData(4)..setFloat32(0, value, Endian.little);
    final bits = source.getUint32(0, Endian.little);
    final sign = (bits >> 16) & 0x8000;
    final exponent = (bits >> 23) & 0xff;
    final mantissa = bits & 0x7fffff;
    if (exponent == 255) return sign | (mantissa == 0 ? 0x7c00 : 0x7e00);
    if (exponent > 142) return sign | 0x7c00;
    if (exponent < 102) return sign;
    final shift = exponent < 113 ? 126 - exponent : 13;
    final significand = exponent < 113 ? mantissa | 0x800000 : mantissa;
    var rounded = significand >> shift;
    final remainder = significand & ((1 << shift) - 1);
    final midpoint = 1 << (shift - 1);
    if (remainder > midpoint || (remainder == midpoint && rounded.isOdd))
      rounded++;
    // Addition carries through exponent and subnormal boundaries.
    return sign |
        (exponent < 113 ? rounded : ((exponent - 112) << 10) + rounded);
  }

  static Float32List uniforms(StoryPostSettings state) {
    final values = <double>[];
    void vec(List<double> value) => values.addAll([
      ...value.take(4),
      for (var i = value.length; i < 4; i++) 0,
    ]);
    final wb = state.component('WhiteBalance');
    final ca = state.component('ColorAdjustments');
    final mixer = state.component('ChannelMixer');
    final lg = state.component('LiftGammaGain');
    final smh = state.component('ShadowsMidtonesHighlights');
    final split = state.component('SplitToning');
    vec([size.toDouble(), .5 / width, .5 / size, size / (size - 1)]);
    vec(whiteBalance(number(wb, 'temperature'), number(wb, 'tint')));
    vec(color(ca['colorFilter']).take(3).map(gammaToLinear).toList());
    for (final channel in const ['red', 'green', 'blue']) {
      vec([
        for (final input in const ['Red', 'Green', 'Blue'])
          number(
                mixer,
                '${channel}Out${input}In',
                channel.toLowerCase() == input.toLowerCase() ? 100 : 0,
              ) /
              100,
      ]);
    }
    vec([
      number(ca, 'hueShift') / 360,
      number(ca, 'saturation') / 100 + 1,
      number(ca, 'contrast') / 100 + 1,
    ]);
    vec(prepareTrackball(color(lg['lift'], alpha: 0), .15, 0));
    vec(prepareTrackball(color(lg['gamma'], alpha: 0), .8, 1));
    vec(prepareTrackball(color(lg['gain'], alpha: 0), .8, 2));
    for (final key in const ['shadows', 'midtones', 'highlights']) {
      final value = color(smh[key], alpha: 0);
      final weight = value[3] * (value[3] < 0 ? 1 : 4);
      vec([
        for (var i = 0; i < 3; i++)
          math.max(0, gammaToLinear(value[i]) + weight),
      ]);
    }
    vec([
      number(smh, 'shadowsStart'),
      number(smh, 'shadowsEnd', .3),
      number(smh, 'highlightsStart', .55),
      number(smh, 'highlightsEnd', 1),
    ]);
    vec([
      ...color(split['shadows'], channel: .5).take(3),
      number(split, 'balance') / 100,
    ]);
    vec(color(split['highlights'], channel: .5).take(3).toList());
    return Float32List.fromList(values);
  }

  /// Mathf.GammaToLinearSpace, including its HDR (>1) branch.
  static double gammaToLinear(double value) {
    if (value <= .04045) return value / 12.92;
    if (value < 1) return math.pow((value + .055) / 1.055, 2.4).toDouble();
    return math.pow(value, 2.2).toDouble();
  }

  static double number(Map value, String field, [double fallback = 0]) =>
      (value[field] as num?)?.toDouble() ?? fallback;

  static List<double> color(
    Object? value, {
    double channel = 1,
    double alpha = 1,
  }) {
    final map = value as Map? ?? const {};
    return [
      for (final pair in const [('r', 'x'), ('g', 'y'), ('b', 'z')])
        ((map[pair.$1] ?? map[pair.$2]) as num?)?.toDouble() ?? channel,
      ((map['a'] ?? map['w']) as num?)?.toDouble() ?? alpha,
    ];
  }

  /// ColorUtils.PrepareLiftGammaGain: 0=lift, 1=gamma, 2=gain.
  static List<double> prepareTrackball(
    List<double> value,
    double scale,
    int kind,
  ) {
    final rgb = value.take(3).map((v) => gammaToLinear(v) * scale).toList();
    final luma = rgb[0] * .2126729 + rgb[1] * .7151522 + rgb[2] * .072175;
    final offset = value[3] + (kind == 0 ? 0 : 1);
    return [
      for (final v in rgb)
        kind == 1 ? 1 / math.max(v - luma + offset, .001) : v - luma + offset,
      0,
    ];
  }

  static List<double> whiteBalance(double temperature, double tint) {
    final t1 = temperature / 65, t2 = tint / 65;
    final x = .31271 - t1 * (t1 < 0 ? .1 : .05);
    final y = 2.87 * x - 3 * x * x - .27509507 + t2 * .05;
    final xx = x / y, zz = (1 - x - y) / y;
    return [
      .949237 / (.7328 * xx + .4296 - .1624 * zz),
      1.03542 / (-.7036 * xx + 1.6975 + .0061 * zz),
      1.08728 / (.0030 * xx + .0136 + .9834 * zz),
    ];
  }

  /// Match TextureCurve.GetTexture's 128 R16F samples using the source keys.
  static Float32List bakeCurve(Map? value, {required bool identity}) {
    final body = value?['m_Curve'] as Map?;
    final keys = (body?['m_Curve'] as List? ?? const []).cast<Map>();
    if (keys.isEmpty) {
      final zero = (value?['m_ZeroValue'] as num?)?.toDouble();
      return Float32List.fromList([
        for (var i = 0; i < curveSamples; i++)
          zero ?? (identity ? i / curveSamples : .5),
      ]);
    }
    final range = (value?['m_Range'] as num?)?.toDouble() ?? 1;
    final loop = value?['m_Loop'] == true || value?['m_Loop'] == 1;
    final extended = [
      if (loop) {...keys.last, 'time': (keys.last['time'] as num) - range},
      ...keys,
      if (loop) {...keys.first, 'time': (keys.first['time'] as num) + range},
    ];
    final curve = NativeAuthoredCurve({'m_Curve': extended});
    return Float32List.fromList([
      for (var i = 0; i < curveSamples; i++) curve.sample(i / curveSamples),
    ]);
  }

  static double half(double value) {
    final bits = _halfBits(value),
        exponent = (bits >> 10) & 31,
        mantissa = bits & 1023;
    final sign = (bits & 0x8000) == 0 ? 1.0 : -1.0;
    if (exponent == 31)
      return mantissa == 0 ? sign * double.infinity : double.nan;
    return sign *
        (exponent == 0
            ? mantissa * math.pow(2, -24)
            : (1 + mantissa / 1024) * math.pow(2, exponent - 15));
  }
}
