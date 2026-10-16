import 'dart:math' as math;
import 'dart:typed_data';

import 'package:haneoka_render_profile/core.dart';

import 'story_ui_layout_data.dart';

final class StoryImageBorders {
  const StoryImageBorders({
    required this.left,
    required this.bottom,
    required this.right,
    required this.top,
  });
  final double left, bottom, right, top;
  bool get any => left > 0 || bottom > 0 || right > 0 || top > 0;
}

/// Actual source texture settings are mandatory for the Tiled branch. A
/// full, unpacked repeat texture uses one quad and native hardware wrapping.
final class StoryTiledImageSource {
  const StoryTiledImageSource({
    required this.packed,
    required this.wrapU,
    required this.wrapV,
    required this.textureWidth,
    required this.textureHeight,
  });
  final bool packed;
  final NativeSamplerAddress wrapU, wrapV;
  final int textureWidth, textureHeight;
}

/// Canvas image geometry from original Image/Sprite component values. Each
/// gradient interval is represented by its own polygons, so alpha keys inside
/// a stretched sprite do not disappear through corner-only interpolation.
ProjectedMesh buildStoryImageMesh({
  required StoryUiRect rect,
  required double canvasWidth,
  required double canvasHeight,
  required List<double> color,
  required int imageType,
  required List<double> spriteSize,
  required StoryUiRect trimmedPixels,
  required StoryImageBorders border,
  required double pixelsPerUnit,
  required bool fillCenter,
  Map? gradient,
  StoryTiledImageSource? tiledSource,
}) {
  if (imageType == 2) {
    if (tiledSource == null) {
      throw const FormatException(
        'native_story_tiled_texture_settings_required',
      );
    }
    if (!fillCenter && !border.any) {
      return ProjectedMesh(Float32List(0), Uint16List(0));
    }
    if (!tiledSource.packed &&
        !border.any &&
        tiledSource.wrapU == NativeSamplerAddress.repeat &&
        tiledSource.wrapV == NativeSamplerAddress.repeat) {
      if (trimmedPixels.x != 0 ||
          trimmedPixels.y != 0 ||
          trimmedPixels.width != spriteSize[0] ||
          trimmedPixels.height != spriteSize[1] ||
          tiledSource.textureWidth != spriteSize[0] ||
          tiledSource.textureHeight != spriteSize[1]) {
        throw UnsupportedError('native_story_tiled_repeat_crop_identity');
      }
      if (gradient != null) {
        throw UnsupportedError('native_story_tiled_repeat_gradient_pending');
      }
      final tileW = spriteSize[0] / pixelsPerUnit,
          tileH = spriteSize[1] / pixelsPerUnit;
      if (!tileW.isFinite || !tileH.isFinite || tileW <= 0 || tileH <= 0) {
        throw const FormatException('native_story_tiled_period');
      }
      final vertices = <double>[];
      final single = Float32List(1);
      double channel(double value) {
        single[0] = value.clamp(0.0, 1.0);
        single[0] *= 255;
        final floor = single[0].floor(),
            fraction = single[0] - single[0].floor();
        return (fraction < .5
                ? floor
                : fraction > .5
                ? floor + 1
                : floor.isEven
                ? floor
                : floor + 1) /
            255;
      }

      final tint = color.map(channel).toList();
      for (final p in const [(0.0, 0.0), (0.0, 1.0), (1.0, 1.0), (1.0, 0.0)]) {
        vertices.addAll([
          2 * (rect.x + rect.width * p.$1) / canvasWidth - 1,
          1 - 2 * (rect.y + rect.height * p.$2) / canvasHeight,
          0,
          1,
          rect.width * p.$1 / tileW,
          1 - rect.height * (1 - p.$2) / tileH,
          ...tint,
        ]);
      }
      return ProjectedMesh(
        Float32List.fromList(vertices),
        Uint16List.fromList([0, 1, 2, 0, 2, 3]),
      );
    }
    throw UnsupportedError('native_story_tiled_grid_and_border_pending');
  }
  if (imageType != 0 && imageType != 1) {
    throw UnsupportedError('native_story_image_type:$imageType');
  }
  if (pixelsPerUnit <= 0 || spriteSize.any((v) => v <= 0)) {
    throw const FormatException('native_story_image_units');
  }
  final polygons = <List<List<double>>>[];
  final hasBorder = imageType == 1 && border.any;
  List<double> axis(double extent, double first, double last) {
    final scale = first + last > extent && first + last > 0
        ? extent / (first + last)
        : 1.0;
    return [0, first * scale, extent - last * scale, extent];
  }

  final xs = hasBorder
      ? axis(
          rect.width,
          border.left / pixelsPerUnit,
          border.right / pixelsPerUnit,
        )
      : [0.0, rect.width];
  final ys = hasBorder
      ? axis(
          rect.height,
          border.top / pixelsPerUnit,
          border.bottom / pixelsPerUnit,
        )
      : [0.0, rect.height];
  final sourceXs = hasBorder
      ? [0.0, border.left, spriteSize[0] - border.right, spriteSize[0]]
      : [0.0, spriteSize[0]];
  final sourceYs = hasBorder
      ? [0.0, border.top, spriteSize[1] - border.bottom, spriteSize[1]]
      : [0.0, spriteSize[1]];
  final trimTop = spriteSize[1] - trimmedPixels.y - trimmedPixels.height;
  for (var y = 0; y + 1 < ys.length; y++) {
    for (var x = 0; x + 1 < xs.length; x++) {
      if (hasBorder && !fillCenter && x == 1 && y == 1) continue;
      if (xs[x + 1] <= xs[x] || ys[y + 1] <= ys[y]) continue;
      final left = math.max(sourceXs[x], trimmedPixels.x);
      final right = math.min(
        sourceXs[x + 1],
        trimmedPixels.x + trimmedPixels.width,
      );
      final top = math.max(sourceYs[y], trimTop);
      final bottom = math.min(sourceYs[y + 1], trimTop + trimmedPixels.height);
      if (right <= left || bottom <= top) continue;
      double target(
        double value,
        List<double> from,
        List<double> to,
        int cell,
      ) =>
          to[cell] +
          (to[cell + 1] - to[cell]) *
              (value - from[cell]) /
              (from[cell + 1] - from[cell]);
      final x0 = target(left, sourceXs, xs, x),
          x1 = target(right, sourceXs, xs, x),
          y0 = target(top, sourceYs, ys, y),
          y1 = target(bottom, sourceYs, ys, y);
      final u0 = (left - trimmedPixels.x) / trimmedPixels.width,
          u1 = (right - trimmedPixels.x) / trimmedPixels.width,
          v0 = (top - trimTop) / trimmedPixels.height,
          v1 = (bottom - trimTop) / trimmedPixels.height;
      polygons.add([
        [x0, y0, u0, v0],
        [x0, y1, u0, v1],
        [x1, y1, u1, v1],
        [x1, y0, u1, v0],
      ]);
    }
  }
  NativeAuthoredGradient? sampler;
  var dx = 0.0, dy = 0.0, low = 0.0, high = 0.0;
  var blend = 0;
  double projection(List<double> p) => p[0] * dx - p[1] * dy;
  if (gradient != null) {
    final angle = (gradient['angle'] as num).toDouble() * math.pi / 180;
    dx = math.cos(angle);
    dy = math.sin(angle);
    blend = gradient['blendMode'] as int;
    if (blend != 0 && blend != 1) {
      throw UnsupportedError('native_story_image_gradient_blend:$blend');
    }
    final keys = gradient['keys'] as Map;
    if (keys['m_Mode'] != 0) {
      throw UnsupportedError(
        'native_story_image_gradient_mode:${keys['m_Mode']}',
      );
    }
    sampler = NativeAuthoredGradient(keys);
    if (sampler.colorSpace != -1 && sampler.colorSpace != 0) {
      throw UnsupportedError(
        'native_story_image_gradient_color_space:${sampler.colorSpace}',
      );
    }
    final extrema = [
      for (final polygon in polygons)
        for (final point in polygon) projection(point),
    ];
    low = extrema.isEmpty ? 0 : extrema.reduce(math.min);
    high = extrema.isEmpty ? 0 : extrema.reduce(math.max);
    if (gradient['splitAtKeysWhenAxisAligned'] == true &&
        (dx.abs() < 1e-5 || dy.abs() < 1e-5) &&
        high > low) {
      final cuts = <double>{};
      for (final prefix in ['ctime', 'atime']) {
        final count =
            keys[prefix == 'ctime' ? 'm_NumColorKeys' : 'm_NumAlphaKeys']
                as int;
        for (var i = 0; i < count; i++) {
          final t = (keys['$prefix$i'] as num).toDouble() / 65535;
          if (t > 0 && t < 1) cuts.add(low + (high - low) * t);
        }
      }
      List<List<double>> clip(
        List<List<double>> polygon,
        double at,
        bool before,
      ) {
        final result = <List<double>>[];
        for (var i = 0; i < polygon.length; i++) {
          final a = polygon[i], b = polygon[(i + 1) % polygon.length];
          final da = projection(a) - at, db = projection(b) - at;
          final insideA = before ? da <= 0 : da >= 0;
          final insideB = before ? db <= 0 : db >= 0;
          if (insideA) result.add(a);
          if (insideA != insideB) {
            final t = da / (da - db);
            result.add([for (var k = 0; k < 4; k++) a[k] + (b[k] - a[k]) * t]);
          }
        }
        return result;
      }

      for (final cut in cuts.toList()..sort()) {
        final split = <List<List<double>>>[];
        for (final polygon in polygons) {
          final min = polygon.map(projection).reduce(math.min);
          final max = polygon.map(projection).reduce(math.max);
          if (min >= cut || max <= cut) {
            split.add(polygon);
          } else {
            for (final side in [true, false]) {
              final part = clip(polygon, cut, side);
              if (part.length >= 3) split.add(part);
            }
          }
        }
        polygons
          ..clear()
          ..addAll(split);
      }
    }
  }
  final vertices = <double>[], indices = <int>[];
  final single = Float32List(1);
  double colorChannel(double value) {
    single[0] = value.clamp(0.0, 1.0);
    single[0] *= 255;
    final floor = single[0].floor(), remainder = single[0] - single[0].floor();
    final byte = remainder < .5
        ? floor
        : remainder > .5
        ? floor + 1
        : floor.isEven
        ? floor
        : floor + 1;
    return byte / 255;
  }

  for (final polygon in polygons) {
    final base = vertices.length ~/ 10;
    for (final point in polygon) {
      var tint = color;
      if (sampler != null) {
        final t = high > low ? (projection(point) - low) / (high - low) : 0.0;
        final evaluated = sampler.sample(t);
        tint = [
          for (var c = 0; c < 4; c++)
            evaluated[c] * (blend == 1 ? color[c] : 1),
        ];
      }
      vertices.addAll([
        2 * (rect.x + point[0]) / canvasWidth - 1,
        1 - 2 * (rect.y + point[1]) / canvasHeight,
        0,
        1,
        point[2],
        point[3],
        // uGUI vertex colors carry four bytes; distance text has its own
        // material path. Quantize image tint after gradient evaluation.
        ...tint.map(colorChannel),
      ]);
    }
    for (var i = 1; i + 1 < polygon.length; i++) {
      indices.addAll([base, base + i, base + i + 1]);
    }
  }
  return ProjectedMesh(
    Float32List.fromList(vertices),
    Uint16List.fromList(indices),
  );
}
