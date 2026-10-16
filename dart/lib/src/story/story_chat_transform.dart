import 'dart:math' as math;
import 'dart:typed_data';

final _single = Float32List(1);
double _f(double x) {
  _single[0] = x;
  return _single[0];
}

final class StoryChatWindowTransform {
  const StoryChatWindowTransform({
    required this.x,
    required this.y,
    required this.defaultScale,
    required this.multiplier,
  });
  final double x, y, defaultScale, multiplier;
  double get scale => _f(defaultScale * multiplier);
}

/// AdvChatView AdjustWindowSize / GetScreenModeScaleMultiplier / adjusted target.
/// Visible bounds are the active RectTransform corner union in window-local units.
StoryChatWindowTransform resolveStoryChatWindowTransform({
  required double viewWidth,
  required double viewHeight,
  required double windowHeight,
  required double visibleWidth,
  required double visibleHeight,
  required int mode,
  required double defaultX,
  required double windowX,
  required double windowY,
  required double incomingX,
  required double incomingY,
  required double rotationZ,
}) {
  if ([
        viewWidth,
        viewHeight,
        windowHeight,
        visibleWidth,
        visibleHeight,
        defaultX,
        windowX,
        windowY,
        incomingX,
        incomingY,
        rotationZ,
      ].any((x) => !x.isFinite) ||
      viewWidth <= 0 ||
      viewHeight <= 0 ||
      windowHeight <= 0) {
    throw const FormatException('story_chat_view_transform_dimensions');
  }
  final base = _f(viewHeight / windowHeight);
  final rawX = _f(_f(defaultX + windowX) + (mode == 1 ? incomingX : 0));
  final rawY = _f(windowY + (mode == 1 ? incomingY : 0));
  if (mode != 1)
    return StoryChatWindowTransform(
      x: rawX,
      y: rawY,
      defaultScale: base,
      multiplier: 1,
    );
  final angle = _f(rotationZ.abs() * _f(math.pi / 180));
  final cosine = _f(math.cos(angle).abs()), sine = _f(math.sin(angle).abs());
  (double, double) extent(double factor) {
    final w = _f(_f(visibleWidth * base) * factor),
        h = _f(_f(visibleHeight * base) * factor);
    return (
      _f(_f(_f(cosine * w) + _f(sine * h)) * .5),
      _f(_f(_f(sine * w) + _f(cosine * h)) * .5),
    );
  }

  (double, double) adjusted(double factor) {
    final e = extent(factor);
    final rx = math.max(0.0, _f(_f(viewWidth * .5) - e.$1));
    final ry = math.max(0.0, _f(_f(viewHeight * .5) - e.$2));
    return (_f(rawX.clamp(-rx, rx)), _f(rawY.clamp(-ry, ry)));
  }

  final initial = adjusted(1), half = extent(1);
  final roomX = _f(_f(viewWidth * .5) - initial.$1.abs());
  final roomY = _f(_f(viewHeight * .5) - initial.$2.abs());
  final factor = roomX <= 0 || roomY <= 0 || half.$1 <= 0 || half.$2 <= 0
      ? 1.0
      : _f(math.min(_f(roomX / half.$1), _f(roomY / half.$2)).clamp(0.0, 1.0));
  final end = adjusted(factor);
  return StoryChatWindowTransform(
    x: end.$1,
    y: end.$2,
    defaultScale: base,
    multiplier: factor,
  );
}
