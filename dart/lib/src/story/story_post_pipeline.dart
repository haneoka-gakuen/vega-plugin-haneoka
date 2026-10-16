import 'dart:math' as math;
import 'dart:convert';
import 'dart:typed_data';

import 'package:haneoka_render_profile/core.dart';

import 'story_colour_grading.dart';
import 'story_field_blur.dart';
import 'story_post_volume.dart';

final class StoryPostPlan {
  const StoryPostPlan(
    this.target,
    this.passes,
    this.dataTextures,
    this.lutRebuilt,
    this.presentationTicket,
  );
  final String target;
  final List<NativePass> passes;

  /// 128×1 RGBA16F, linear encoding, independent alpha, clamp/linear samplers.
  final Map<String, NativeTextureData> dataTextures;
  final bool lutRebuilt;

  /// Opaque acknowledgement for the revision that actually reached the GPU.
  final Object? presentationTicket;
}

final class _LutPresentationTicket {
  const _LutPresentationTicket(
    this.key,
    this.prefix,
    this.residency,
    this.generation,
  );
  final String key, prefix;
  final (int, int, int) residency;
  final int generation;
}

/// A field-camera post chain. The caller composites UI after the returned target.
final class StoryPostPasses {
  String? _curveKey, _curvePrefix;
  _LutPresentationTicket? _desired, _presented;
  int _generation = 0;
  Map<String, NativeTextureData> _curves = const {};
  static const _curvedRates = [
    1.0,
    .8500000238418579,
    .6499999761581421,
    .44999998807907104,
    .30000001192092896,
    .15000000596046448,
    0.0,
  ];
  static double curvedRateForCameraDistance(int distance) =>
      distance >= 0 && distance < _curvedRates.length
      ? _curvedRates[distance]
      : 1;

  /// Called when the caller replaces its GPU render session or loses residency.
  void reset() {
    _generation++;
    _desired = null;
    _presented = null;
  }

  bool didPresent(Object? ticket) {
    if (ticket is! _LutPresentationTicket ||
        !identical(ticket, _desired) ||
        ticket.generation != _generation)
      return false;
    _presented = ticket;
    return true;
  }

  StoryPostPlan append({
    required String prefix,
    required String sourceTarget,
    required int width,
    required int height,
    required StoryPostSettings settings,
    required Map<String, ProjectedMesh> meshes,
    required Map<String, NativeMaterial> materials,
    required Map<String, NativeTarget> targets,
    int cameraDistance = 0,
    double? curvedLensRate,
    bool postEnabled = true,
    bool fxaaEnabled = true,
    int sourceGraphGeneration = 0,
    bool forceRebuild = false,
    Map fxaa = const {
      'subpixelBlend': .75,
      'relativeContrast': .166,
      'absoluteContrast': .0833,
    },
  }) {
    final passes = <NativePass>[];
    final quad = '$prefix:quad';
    meshes[quad] = StoryFieldBlur.fullscreen();
    String current = sourceTarget;
    void draw(
      String output,
      NativeMaterial material, {
      int? targetWidth,
      int? targetHeight,
      NativeTargetFormat format = NativeTargetFormat.rgba16f,
      NativeColorEncoding encoding = NativeColorEncoding.gammaSrgb,
    }) {
      targets[output] = NativeTarget(
        width: targetWidth ?? width,
        height: targetHeight ?? height,
        format: format,
        alpha: NativeTextureAlpha.independent,
        encoding: encoding,
      );
      materials[output] = material;
      passes.add(
        NativePass(
          target: output,
          draws: [NativeDraw(mesh: quad, material: output)],
        ),
      );
    }

    final lutTarget = '$prefix:lut';
    var rebuilt = false;
    Object? presentationTicket;
    if (postEnabled) {
      final residency = (width, height, sourceGraphGeneration);
      if (forceRebuild ||
          _desired?.key != settings.gradingKey ||
          _desired?.prefix != prefix ||
          _desired?.residency != residency) {
        _desired = _LutPresentationTicket(
          settings.gradingKey,
          prefix,
          residency,
          _generation,
        );
      }
      presentationTicket = _desired;
      rebuilt = !identical(_desired, _presented);
      final slots = <String, String>{
        for (final slot in StoryColorGrading.curveSlots) slot: '$prefix:$slot',
      };
      if (rebuilt) {
        final curveKey = jsonEncode(settings.component('ColorCurves'));
        if (_curveKey != curveKey || _curvePrefix != prefix) {
          _curves = Map.unmodifiable({
            for (final entry in StoryColorGrading.curveData(settings).entries)
              slots[entry.key]!: entry.value,
          });
          _curveKey = curveKey;
          _curvePrefix = prefix;
        }
        draw(
          lutTarget,
          NativeMaterial(
            texture: '',
            recipe: NativeMaterialRecipe.storyColorLut,
            blend: NativeBlend.opaque,
            textureAlpha: NativeTextureAlpha.independent,
            additionalTextures: slots,
            uniformFloats: StoryColorGrading.uniforms(settings),
          ),
          targetWidth: StoryColorGrading.width,
          targetHeight: StoryColorGrading.size,
          format: NativeTargetFormat.rgba8,
          encoding: NativeColorEncoding.linear,
        );
      } else {
        targets[lutTarget] = NativeTarget(
          width: StoryColorGrading.width,
          height: StoryColorGrading.size,
          format: NativeTargetFormat.rgba8,
          alpha: NativeTextureAlpha.independent,
          encoding: NativeColorEncoding.linear,
        );
      }

      final bloom = settings.component('Bloom');
      final intensity = StoryColorGrading.number(bloom, 'intensity');
      var bloomTarget = sourceTarget;
      if (bloom['active'] != false && intensity > 0) {
        final scatter =
            .05 + .9 * StoryColorGrading.number(bloom, 'scatter', .7);
        final threshold = StoryColorGrading.gammaToLinear(
          StoryColorGrading.number(bloom, 'threshold', .9),
        );
        final clamp = StoryColorGrading.number(bloom, 'clamp', 65472);
        final down = StoryColorGrading.number(bloom, 'downscale').toInt() == 1
            ? 2
            : 1;
        var w = math.max(1, width >> down), h = math.max(1, height >> down);
        // Formal CalcBloomMipCount does not read the serialized skipIterations.
        final count = (math.log(math.max(w, h)) / math.ln2 - 1).floor().clamp(
          1,
          StoryColorGrading.number(bloom, 'maxIterations', 6).toInt(),
        );
        final mip = <String>[], sizes = <(int, int)>[];
        void bloomPass(
          String output,
          String input,
          int mode,
          int ow,
          int oh, {
          String? auxiliary,
        }) {
          final spec = targets[input]!;
          draw(
            output,
            NativeMaterial(
              texture: input,
              recipe: NativeMaterialRecipe.postProcess,
              blend: NativeBlend.opaque,
              textureAlpha: spec.alpha,
              additionalTextures: {
                if (auxiliary != null) 'auxiliaryImage': auxiliary,
              },
              uniformFloats: Float32List.fromList([
                1 / spec.width,
                1 / spec.height,
                mode.toDouble(),
                scatter,
                clamp,
                threshold,
                threshold * .5,
                intensity,
                1,
                spec.encoding == NativeColorEncoding.gammaSrgb ? 1 : 0,
                0,
                0,
                0,
                0,
                0,
                0,
              ]),
            ),
            targetWidth: ow,
            targetHeight: oh,
            encoding: NativeColorEncoding.sqrtLinear,
          );
        }

        for (var level = 0; level < count; level++) {
          final output = '$prefix:bloom:$level';
          if (level == 0) {
            bloomPass(output, sourceTarget, 6, w, h);
          } else {
            final horizontal = '$output:horizontal';
            bloomPass(horizontal, bloomTarget, 1, w, h);
            bloomPass(output, horizontal, 2, w, h);
          }
          mip.add(output);
          sizes.add((w, h));
          bloomTarget = output;
          w = math.max(1, w ~/ 2);
          h = math.max(1, h ~/ 2);
        }
        for (var level = count - 2; level >= 0; level--) {
          final output = '$prefix:bloom:$level:up';
          bloomPass(
            output,
            mip[level],
            3,
            sizes[level].$1,
            sizes[level].$2,
            auxiliary: bloomTarget,
          );
          bloomTarget = output;
        }
      }
      final linearTint = StoryColorGrading.color(bloom['tint'])
          .take(3)
          .map(StoryColorGrading.gammaToLinear)
          .toList();
      final tintLuma =
          linearTint[0] * .2126729 +
          linearTint[1] * .7151522 +
          linearTint[2] * .072175;
      final vignette = settings.component('Vignette');
      final vc = StoryColorGrading.color(vignette['color'], channel: 0);
      final center = vignette['center'] as Map? ?? const {};
      final distortion = settings.component('LensDistortion');
      final amount = StoryColorGrading.number(distortion, 'intensity') * 100;
      final theta =
          math.min(160, math.max(amount.abs(), 1) * 1.6) * math.pi / 180;
      final dc = distortion['center'] as Map? ?? const {};
      draw(
        '$prefix:uber',
        NativeMaterial(
          texture: current,
          recipe: NativeMaterialRecipe.storyUber,
          blend: NativeBlend.opaque,
          textureAlpha: targets[current]!.alpha,
          additionalTextures: {
            'gradingLut': lutTarget,
            'bloomImage': bloomTarget,
          },
          uniformFloats: Float32List.fromList([
            1 / width,
            1 / height,
            width.toDouble(),
            height.toDouble(),
            math
                .pow(
                  2,
                  StoryColorGrading.number(
                    settings.component('ColorAdjustments'),
                    'postExposure',
                  ),
                )
                .toDouble(),
            StoryColorGrading.number(
                  settings.component('ChromaticAberration'),
                  'intensity',
                ) *
                .05,
            StoryColorGrading.number(vignette, 'intensity') * 3,
            StoryColorGrading.number(vignette, 'smoothness', .2) * 5,
            vc[0],
            vc[1],
            vc[2],
            vignette['rounded'] == true || vignette['rounded'] == 1
                ? width / height
                : 1,
            StoryColorGrading.number(center, 'x', .5),
            StoryColorGrading.number(center, 'y', .5),
            targets[current]!.encoding == NativeColorEncoding.gammaSrgb ? 1 : 0,
            1,
            bloom['active'] == false ? 0 : intensity,
            for (final channel in linearTint)
              tintLuma > 0 ? channel / tintLuma : 1,
            1 / 256,
            1 / 16,
            15,
            0,
            StoryColorGrading.number(dc, 'x', .5) * 2 - 1,
            StoryColorGrading.number(dc, 'y', .5) * 2 - 1,
            StoryColorGrading.number(distortion, 'xMultiplier', 1),
            StoryColorGrading.number(distortion, 'yMultiplier', 1),
            amount >= 0 ? theta : 1 / theta,
            2 * math.tan(theta * .5),
            1 / StoryColorGrading.number(distortion, 'scale', 1),
            amount,
          ]),
        ),
      );
      current = '$prefix:uber';
      final curved = settings.curvedLens;
      if (curved != null && curved['active'] != false) {
        final rate =
            curved['attenuateByCameraDistance'] == false ||
                curved['attenuateByCameraDistance'] == 0
            ? 1.0
            : curvedLensRate ?? curvedRateForCameraDistance(cameraDistance);
        final lensIntensity =
            StoryColorGrading.number(curved, 'intensity') * rate;
        if (lensIntensity.abs() > .0001) {
          final cc = curved['center'] as Map? ?? const {};
          draw(
            '$prefix:curved',
            NativeMaterial(
              texture: current,
              recipe: NativeMaterialRecipe.storyCurvedLens,
              blend: NativeBlend.opaque,
              textureAlpha: targets[current]!.alpha,
              uniformFloats: Float32List.fromList([
                1 / width,
                1 / height,
                width.toDouble(),
                height.toDouble(),
                StoryColorGrading.number(cc, 'x', .5),
                StoryColorGrading.number(cc, 'y', .5),
                lensIntensity,
                StoryColorGrading.number(curved, 'size'),
                StoryColorGrading.number(curved, 'softness', 1),
                StoryColorGrading.number(curved, 'horizontalRate'),
                StoryColorGrading.number(curved, 'verticalRate'),
                StoryColorGrading.number(curved, 'scale', 1),
                curved['reverse'] == true || curved['reverse'] == 1 ? 1 : 0,
                0,
                0,
                0,
              ]),
            ),
          );
          current = '$prefix:curved';
        }
      }
    }
    if (fxaaEnabled) {
      draw(
        '$prefix:fxaa',
        NativeMaterial(
          texture: current,
          recipe: NativeMaterialRecipe.postProcess,
          blend: NativeBlend.opaque,
          textureAlpha: targets[current]!.alpha,
          uniformFloats: Float32List.fromList([
            1 / width,
            1 / height,
            5,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            StoryColorGrading.number(fxaa, 'subpixelBlend', .75),
            StoryColorGrading.number(fxaa, 'relativeContrast', .166),
            StoryColorGrading.number(fxaa, 'absoluteContrast', .0833),
            0,
          ]),
        ),
      );
      current = '$prefix:fxaa';
    }
    return StoryPostPlan(
      current,
      List.unmodifiable(passes),
      postEnabled ? _curves : const {},
      rebuilt,
      presentationTicket,
    );
  }
}
