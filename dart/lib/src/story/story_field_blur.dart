import 'dart:math' as math;
import 'dart:typed_data';

import 'package:haneoka_render_profile/core.dart';

/// The formal field renderer stores blur on its five camera entries. Models
/// registered into an entry share its value.
final class StoryCharacterBlurChannels {
  final _values = Float32List(5);
  double read(int slot) => _values[slot];
  void write(int slot, double value) => _values[slot] = value;
  List<double> get values => List.unmodifiable(_values);
}

final class StoryFieldBlur {
  // Formal AdvFieldRendererSettings (.rodata 0x20612c0), CameraDistance 0..6.
  static const _radiusByDistance = [.75, 2.25, 3.75, 5.5, 7.75, 9.75, 12.0];
  static double radiusForCameraDistance(int distance) =>
      distance >= 0 && distance < _radiusByDistance.length
      ? _radiusByDistance[distance]
      : .75;

  static ProjectedMesh fullscreen({double alpha = 1, double brightness = 1}) =>
      ProjectedMesh(
        Float32List.fromList([
          for (final point in const [
            (-1.0, -1.0, 0.0, 1.0),
            (-1.0, 1.0, 0.0, 0.0),
            (1.0, 1.0, 1.0, 0.0),
            (1.0, -1.0, 1.0, 1.0),
          ]) ...[
            point.$1,
            point.$2,
            0,
            1,
            point.$3,
            point.$4,
            brightness,
            brightness,
            brightness,
            alpha,
          ],
        ]),
        Uint16List.fromList([0, 1, 2, 0, 2, 3]),
      );

  static List<NativePass> append({
    required String prefix,
    required String sourceTarget,
    required int width,
    required int height,
    required double intensity,
    required double radiusMax,
    required Map<String, ProjectedMesh> meshes,
    required Map<String, NativeMaterial> materials,
    required Map<String, NativeTarget> targets,
    double scale = .5,
  }) {
    final temporary = '$prefix:temporary';
    int scaled(int size) {
      final value = size * scale;
      final lower = value.floor();
      final rounded = value - lower == .5
          ? (lower.isEven ? lower : lower + 1)
          : value.round();
      return math.max(1, rounded);
    }

    final temporaryWidth = scaled(width), temporaryHeight = scaled(height);
    targets[temporary] = NativeTarget(
      width: temporaryWidth,
      height: temporaryHeight,
      format: NativeTargetFormat.rgba16f,
    );
    final quad = '$prefix:quad';
    meshes[quad] = fullscreen();
    final passes = <NativePass>[];
    for (var index = 0; index < 2; index++) {
      final material = '$prefix:pass:$index';
      materials[material] = NativeMaterial(
        texture: index == 0 ? sourceTarget : temporary,
        recipe: NativeMaterialRecipe.storyBokeh,
        blend: NativeBlend.opaque,
        textureAlpha: NativeTextureAlpha.premultiplied,
        minFilter: SamplerFilter.nearest,
        magFilter: SamplerFilter.nearest,
        uniformFloats: Float32List.fromList([
          1 / (index == 0 ? width : temporaryWidth),
          1 / (index == 0 ? height : temporaryHeight),
          width.toDouble(),
          height.toDouble(),
          intensity,
          radiusMax,
          .9,
          index == 0 ? 0 : math.pi / 3,
          .05,
          .7,
          .28,
          0,
        ]),
      );
      passes.add(
        NativePass(
          target: index == 0 ? temporary : sourceTarget,
          draws: [NativeDraw(mesh: quad, material: material)],
        ),
      );
    }
    return passes;
  }
}
