import 'dart:math' as math;

/// AdvCameraConfig policy in physical pixels; hosts supply display orientation.
double storyViewportHeight({
  required double width,
  required double height,
  required double pixelRatio,
  required bool displayPortrait,
  double baseAspect = 16 / 9,
}) {
  final target = displayPortrait ? baseAspect : math.max(baseAspect, 13 / 6);
  if (width / height + .0001 >= target) return height;
  final fitted = width / target;
  return (height - fitted) * pixelRatio / 2 <= 1 ? height : fitted;
}
