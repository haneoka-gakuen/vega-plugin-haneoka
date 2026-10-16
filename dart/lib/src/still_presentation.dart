import 'dart:math' as math;
import 'dart:typed_data';

import 'package:haneoka_render_profile/core.dart';
import 'story/story_still_external_layout.dart';

typedef _StillPlacement = (
  double,
  double,
  List<double>,
  double,
  List,
  List<double>,
  bool,
  List<double>,
);

/// Backend-neutral source boundary: original RectTransform units and full TRS.
/// Snapshot is serialized initial state; native sequences remain owned by runtime.
final class StillGpuSnapshot {
  const StillGpuSnapshot({
    required this.scene,
    required this.frame,
    required this.textures,
    required this.sourceHash,
    required this.sequences,
    required this.unsupportedFeatures,
    required this.imageGeometry,
  });
  final NativeSceneResources scene;
  final NativeFrame frame;
  final Map<String, Uri> textures;
  final String sourceHash;
  final List<Object?> sequences;
  final List<String> unsupportedFeatures;
  final Map<String, Object?> imageGeometry;
}

StillGpuSnapshot buildStillSnapshot(
  Map<String, Object?> document, {
  required RenderSource source,
  required int epoch,
  required int width,
  required int height,
  required Uri Function(String path) resolveTexture,
  required Map<String, (int, int)> textureSizes,
  NativeTextureAlpha textureAlpha = NativeTextureAlpha.straight,
  bool presentable = false,
  bool captureGeometryProof = false,
  StoryStillExternalLayout? externalLayout,
}) {
  if (document['schema'] != 'haneoka-still-presentation-v1' ||
      width <= 0 ||
      height <= 0) {
    throw FormatException('native_still_schema_or_viewport');
  }
  Map object(Object? value) =>
      value is Map ? value : throw FormatException('native_still_object');
  double number(Object? value) => value is num && value.isFinite
      ? value.toDouble()
      : throw FormatException('native_still_number');
  List list(Object? value, int length) =>
      value is List && value.length == length
      ? value
      : throw FormatException('native_still_vector');
  Float32List vector(Object? value, int length) =>
      Float32List.fromList(list(value, length).map(number).toList());
  final layout = object(document['layout']), camera = object(layout['camera']);
  final nodes = layout['nodes'];
  final sourceHash = document['sourceHash'];
  if (nodes is! List ||
      nodes.length > 16384 ||
      sourceHash is! String ||
      sourceHash.isEmpty) {
    throw FormatException('native_still_identity');
  }
  final reference = list(camera['referenceResolution'], 2);
  final rw = number(reference[0]), rh = number(reference[1]);
  final mode = camera['screenMatchMode'];
  final maxAspect = camera['maxAspectThreshold'];
  final matchedWidth = maxAspect is num && maxAspect > 0
      ? math.min(width.toDouble(), height * maxAspect.toDouble())
      : width.toDouble();
  final xScale = matchedWidth / rw, yScale = height / rh;
  final match = number(camera['matchWidthOrHeight']);
  final scale =
      externalLayout?.canvasScale ??
      switch (mode) {
        0 => math.exp(
          math.log(xScale) * (1 - match) + math.log(yScale) * match,
        ),
        1 => math.min(xScale, yScale),
        2 => math.max(xScale, yScale),
        _ => throw UnsupportedError('native_still_screen_match_mode:$mode'),
      };
  final rootWidth = externalLayout?.logicalWidth ?? width / scale,
      rootHeight = externalLayout?.logicalHeight ?? height / scale;
  if (externalLayout != null &&
      (externalLayout.physicalWidth != width ||
          externalLayout.physicalHeight != height)) {
    throw const FormatException('native_still_external_viewport');
  }
  final distance = number(camera['planeDistance']);
  final near = number(camera['nearClip']), far = number(camera['farClip']);
  final fov = number(camera['fieldOfView']) * math.pi / 180;
  if (rw <= 0 ||
      rh <= 0 ||
      distance <= near ||
      near <= 0 ||
      far <= distance ||
      fov <= 0 ||
      fov >= math.pi) {
    throw FormatException('native_still_camera');
  }
  final worldScale = 2 * distance * math.tan(fov / 2) / rootHeight;
  final focal = 1 / math.tan(fov / 2), aspect = width / height;
  // Unity +Z is forward; only the camera projection changes handedness.
  // Depth is represented in 0..1, with homogeneous W retained for GPU clipping.
  final projection = Float32List.fromList([
    worldScale * focal / aspect,
    0,
    0,
    0,
    0,
    worldScale * focal,
    0,
    0,
    0,
    0,
    worldScale * far / (far - near),
    worldScale,
    0,
    0,
    far * (distance - near) / (far - near),
    distance,
  ]);
  final byId = <String, Map>{};
  for (final value in nodes) {
    final node = object(value), id = node['id'];
    if (id is! String || byId.containsKey(id)) {
      throw FormatException('native_still_node_identity');
    }
    byId[id] = node;
  }
  final cache = <String, _StillPlacement>{};
  final visiting = <String>{};
  final identity = Float32List.fromList([
    1,
    0,
    0,
    0,
    0,
    1,
    0,
    0,
    0,
    0,
    1,
    0,
    0,
    0,
    0,
    1,
  ]);
  List<double> multiply(List<double> a, List<double> b) {
    final List<double> result = externalLayout == null
        ? Float32List(16)
        : List<double>.filled(16, 0);
    for (var c = 0; c < 4; c++) {
      for (var r = 0; r < 4; r++) {
        var v = 0.0;
        for (var k = 0; k < 4; k++) {
          v += a[k * 4 + r] * b[c * 4 + k];
        }
        result[c * 4 + r] = v;
      }
    }
    return result;
  }

  final scalarF32 = Float32List(1);
  double f(double value) {
    scalarF32[0] = value;
    return scalarF32[0];
  }

  List<double> affineMultiply(List<double> a, List<double> b) => [
    a[0] * b[0] + a[2] * b[1],
    a[1] * b[0] + a[3] * b[1],
    a[0] * b[2] + a[2] * b[3],
    a[1] * b[2] + a[3] * b[3],
    a[0] * b[4] + a[2] * b[5] + a[4],
    a[1] * b[4] + a[3] * b[5] + a[5],
  ];
  List<double> affineLocal(List q, List scale, double x, double y) {
    final qx = number(q[0]),
        qy = number(q[1]),
        qz = number(q[2]),
        qw = number(q[3]);
    final x2 = f(qx * 2), y2 = f(qy * 2), z2 = f(qz * 2);
    final xx = f(qx * x2),
        yy = f(qy * y2),
        zz = f(qz * z2),
        xy = f(qx * y2),
        wz = f(qw * z2);
    return [
      f(f(1 - f(yy + zz)) * number(scale[0])),
      f(f(xy + wz) * number(scale[0])),
      f(f(xy - wz) * number(scale[1])),
      f(f(1 - f(xx + zz)) * number(scale[1])),
      x,
      y,
    ];
  }

  List<double> affineMatrix(List<double> a) => [
    a[0],
    a[1],
    0,
    0,
    a[2],
    a[3],
    0,
    0,
    0,
    0,
    1,
    0,
    a[4],
    a[5],
    0,
    1,
  ];
  List<double> trs(double x, double y, double z, List q, List scale) {
    final qx = number(q[0]),
        qy = number(q[1]),
        qz = number(q[2]),
        qw = number(q[3]);
    final sx = number(scale[0]), sy = number(scale[1]), sz = number(scale[2]);
    return [
      (1 - 2 * (qy * qy + qz * qz)) * sx,
      2 * (qx * qy + qw * qz) * sx,
      2 * (qx * qz - qw * qy) * sx,
      0,
      2 * (qx * qy - qw * qz) * sy,
      (1 - 2 * (qx * qx + qz * qz)) * sy,
      2 * (qy * qz + qw * qx) * sy,
      0,
      2 * (qx * qz + qw * qy) * sz,
      2 * (qy * qz - qw * qx) * sz,
      (1 - 2 * (qx * qx + qy * qy)) * sz,
      0,
      x,
      y,
      z,
      1,
    ];
  }

  final target = externalLayout?.target;
  final externalMatrix = target == null
      ? null
      : <double>[
          target.matrix3[0], target.matrix3[4], target.matrix3[8], 0,
          target.matrix3[1], target.matrix3[5], target.matrix3[9], 0,
          target.matrix3[2], target.matrix3[6], target.matrix3[10], 0,
          // Reference bottom-left canvas origin -> this compiler's centered plane.
          target.matrix3[3] - rootWidth / 2,
          target.matrix3[7] - rootHeight / 2, target.matrix3[11], 1,
        ];

  _StillPlacement placement(String id) {
    final existing = cache[id];
    if (existing != null) return existing;
    if (!visiting.add(id)) {
      throw FormatException('native_still_hierarchy_cycle');
    }
    final node = byId[id];
    if (node == null) throw FormatException('native_still_parent_missing');
    final parentId = node['parent'];
    final parent = parentId == null
        ? target == null
              ? (
                  rootWidth,
                  rootHeight,
                  identity.toList(),
                  1.0,
                  [0.5, 0.5],
                  [
                    f(-rootWidth / 2),
                    f(-rootHeight / 2),
                    f(rootWidth),
                    f(rootHeight),
                  ],
                  true,
                  const <double>[1, 0, 0, 1, 0, 0],
                )
              : (
                  target.rect[2],
                  target.rect[3],
                  externalMatrix!,
                  target.active ? target.alpha : 0.0,
                  target.pivot,
                  target.rect,
                  target.planar,
                  <double>[
                    ...target.affine.take(4),
                    target.affine[4] - rootWidth / 2,
                    target.affine[5] - rootHeight / 2,
                  ],
                )
        : placement(parentId as String);
    if (externalLayout != null &&
        node['transformKind'] != 'rect' &&
        node['transformKind'] != 'transform') {
      throw const FormatException('native_still_formal_transform_kind');
    }
    if (externalLayout != null && node['transformKind'] == 'transform') {
      final position = list(node['position'], 2),
          scale = list(node['scale'], 2);
      final q = list(node['rotationQuaternion'], 4),
          z = number(node['positionZ']);
      final result = (
        0.0,
        0.0,
        multiply(
          parent.$3,
          trs(
            number(position[0]),
            number(position[1]),
            number(node['positionZ']),
            list(node['rotationQuaternion'], 4),
            [...scale, number(node['scaleZ'])],
          ),
        ),
        node['active'] == true ? parent.$4 : 0.0,
        const <double>[0, 0],
        const <double>[0, 0, 0, 0],
        parent.$7 &&
            z == 0 &&
            number(q[0]).abs() <= 1e-7 &&
            number(q[1]).abs() <= 1e-7,
        affineMultiply(
          parent.$8,
          affineLocal(q, scale, number(position[0]), number(position[1])),
        ),
      );
      cache[id] = result;
      visiting.remove(id);
      return result;
    }
    final amin = list(node['anchorMin'], 2),
        amax = list(node['anchorMax'], 2),
        pivot = list(node['pivot'], 2);
    final size = list(node['size'], 2),
        anchored = list(node['position'], 2),
        localScale = list(node['scale'], 2);
    final minX = f(parent.$6[0] + f(number(amin[0]) * parent.$1)),
        maxX = f(parent.$6[0] + f(number(amax[0]) * parent.$1)),
        minY = f(parent.$6[1] + f(number(amin[1]) * parent.$2)),
        maxY = f(parent.$6[1] + f(number(amax[1]) * parent.$2));
    var w = externalLayout == null
        ? parent.$1 * (number(amax[0]) - number(amin[0])) + number(size[0])
        : f(f(maxX - minX) + number(size[0]));
    var h = externalLayout == null
        ? parent.$2 * (number(amax[1]) - number(amin[1])) + number(size[1])
        : f(f(maxY - minY) + number(size[1]));
    if (node['aspect'] case final Map fit) {
      final ratio = number(fit['ratio']);
      if (ratio <= 0) throw FormatException('native_still_aspect');
      switch (fit['mode']) {
        case 0:
          break;
        case 1:
          h = w / ratio;
        case 2:
          w = h * ratio;
        case 3 || 4:
          final fitWidth = parent.$1 / parent.$2 < ratio;
          if (fitWidth == (fit['mode'] == 3)) {
            w = parent.$1;
            h = w / ratio;
          } else {
            h = parent.$2;
            w = h * ratio;
          }
        default:
          throw UnsupportedError('native_still_aspect_mode');
      }
    }
    if (externalLayout != null) {
      w = f(w);
      h = f(h);
    }
    final x = externalLayout == null
        ? parent.$1 *
                  (number(amin[0]) +
                      (number(amax[0]) - number(amin[0])) * number(pivot[0]) -
                      number(parent.$5[0])) +
              number(anchored[0])
        : f(
            f(minX + f(f(maxX - minX) * number(pivot[0]))) +
                number(anchored[0]),
          );
    final y = externalLayout == null
        ? parent.$2 *
                  (number(amin[1]) +
                      (number(amax[1]) - number(amin[1])) * number(pivot[1]) -
                      number(parent.$5[1])) +
              number(anchored[1])
        : f(
            f(minY + f(f(maxY - minY) * number(pivot[1]))) +
                number(anchored[1]),
          );
    final local = externalLayout == null
        ? NativeLocalTransform(
            position: Float32List.fromList([x, y, number(node['positionZ'])]),
            quaternion: vector(node['rotationQuaternion'], 4),
            scale: Float32List.fromList([
              ...localScale.map(number),
              number(node['scaleZ']),
            ]),
          ).matrix()
        : trs(
            x,
            y,
            number(node['positionZ']),
            list(node['rotationQuaternion'], 4),
            [...localScale, number(node['scaleZ'])],
          );
    final result = (
      w,
      h,
      multiply(parent.$3, local),
      node['active'] == true
          ? parent.$4 * number(node['opacity']).clamp(0, 1)
          : 0.0,
      pivot,
      <double>[f(-number(pivot[0]) * w), f(-number(pivot[1]) * h), w, h],
      externalLayout != null &&
          parent.$7 &&
          number(node['positionZ']) == 0 &&
          number(list(node['rotationQuaternion'], 4)[0]).abs() <= 1e-7 &&
          number(list(node['rotationQuaternion'], 4)[1]).abs() <= 1e-7,
      externalLayout == null
          ? const <double>[1, 0, 0, 1, 0, 0]
          : affineMultiply(
              parent.$8,
              affineLocal(
                list(node['rotationQuaternion'], 4),
                localScale,
                x,
                y,
              ),
            ),
    );
    cache[id] = result;
    visiting.remove(id);
    return result;
  }

  final meshes = <String, ProjectedMesh>{},
      materials = <String, NativeMaterial>{},
      textures = <String, Uri>{};
  final draws = <NativeDraw>[];
  final imageGeometry = <String, Object?>{};
  for (final id in byId.keys) {
    final node = byId[id]!, placed = placement(id), image = node['image'];
    if (image is! Map || image['enabled'] == false || placed.$4 == 0) continue;
    final color = vector(image['color'], 4);
    color[3] *= placed.$4;
    if (color[3] == 0) continue;
    final texture = image['texture'];
    final key = texture is String ? texture : 'native-solid-white';
    var w = placed.$1, h = placed.$2;
    Map? sprite;
    var fullWidth = 1.0, fullHeight = 1.0;
    var padding = const <double>[0, 0, 0, 0];
    if (texture is String) {
      if (image['sprite'] is! Map) {
        throw StateError('native_still_source_sprite_geometry_missing:$id');
      }
      sprite = object(image['sprite']);
      final full = list(sprite['rect'], 4);
      final trim = list(sprite['textureRect'], 4);
      final offset = list(sprite['trimOffset'], 2);
      fullWidth = number(full[2]);
      fullHeight = number(full[3]);
      padding = list(sprite['padding'], 4).map(number).toList();
      if (fullWidth <= 0 ||
          fullHeight <= 0 ||
          number(trim[2]) <= 0 ||
          number(trim[3]) <= 0 ||
          number(sprite['pixelsPerUnit']) <= 0 ||
          sprite['serializedFile'] is! String ||
          sprite['objectId'] is! String ||
          sprite['sourceHash'] is! String ||
          sprite['outputSHA256'] is! String) {
        throw FormatException('native_still_source_sprite_geometry:$id');
      }
      if (padding[0] != number(offset[0]) ||
          padding[1] != number(offset[1]) ||
          padding[2] != fullWidth - number(offset[0]) - number(trim[2]) ||
          padding[3] != fullHeight - number(offset[1]) - number(trim[3])) {
        throw FormatException('native_still_source_sprite_padding:$id');
      }
      if (image['type'] != 0 ||
          image['useSpriteMesh'] != false ||
          sprite['packingRotation'] != 0 ||
          sprite['packed'] != false) {
        throw UnsupportedError('native_still_source_sprite_mode:$id');
      }
      if (!textureSizes.containsKey(texture)) {
        throw StateError('native_still_texture_size_missing');
      }
    }
    if (image['preserveAspect'] == true && sprite != null) {
      final ratio = fullWidth / fullHeight;
      if (w.abs() / h.abs() > ratio) {
        w = h * ratio;
      } else {
        h = w / ratio;
      }
    }
    final px = number(placed.$5[0]), py = number(placed.$5[1]);
    double roundedPixels(double value) {
      final lower = value.floor(), remainder = value - value.floor();
      return (remainder < .5
              ? lower
              : remainder > .5
              ? lower + 1
              : lower.isEven
              ? lower
              : lower + 1)
          .toDouble();
    }

    // A derivative PNG covers only the original Sprite's trimmed region.
    // Crop the Image's local quad by original float padding/full dimensions;
    // UIImage Simple uses this rectangle proportion, without another PPU scale.
    final denominatorX = roundedPixels(fullWidth);
    final denominatorY = roundedPixels(fullHeight);
    if (denominatorX <= 0 || denominatorY <= 0) {
      throw FormatException('native_still_source_sprite_rounded_extent:$id');
    }
    final x0 = (padding[0] / denominatorX - px) * w;
    final x1 = ((denominatorX - padding[2]) / denominatorX - px) * w;
    final y0 = (padding[1] / denominatorY - py) * h;
    final y1 = ((denominatorY - padding[3]) / denominatorY - py) * h;
    final geometry = NativeSpriteGeometry(
      positions: Float32List.fromList([
        x0,
        y0,
        0,
        x1,
        y0,
        0,
        x0,
        y1,
        0,
        x1,
        y1,
        0,
      ]),
      uv: Float32List.fromList([0, 1, 1, 1, 0, 0, 1, 0]),
      indices: Uint16List.fromList([0, 1, 2, 2, 1, 3]),
    );
    final drawMatrix = externalLayout != null && placed.$7
        ? affineMatrix(placed.$8)
        : placed.$3;
    meshes[id] = projectSprite(
      geometry,
      Float32List.fromList(multiply(projection, drawMatrix)),
      color,
    );
    if (captureGeometryProof) {
      final mesh = meshes[id]!;
      final pixelPoints = <List<double>>[];
      for (var offset = 0; offset < mesh.vertices.length; offset += 10) {
        final clipW = mesh.vertices[offset + 3];
        if (clipW <= 0 || !clipW.isFinite) {
          continue;
        }
        pixelPoints.add([
          (mesh.vertices[offset] / clipW + 1) * width / 2,
          (1 - mesh.vertices[offset + 1] / clipW) * height / 2,
        ]);
      }
      final xs = pixelPoints.map((p) => p[0]),
          ys = pixelPoints.map((p) => p[1]);
      final left = pixelPoints.isEmpty ? null : xs.reduce(math.min);
      final right = pixelPoints.isEmpty ? null : xs.reduce(math.max);
      final top = pixelPoints.isEmpty ? null : ys.reduce(math.min);
      final bottom = pixelPoints.isEmpty ? null : ys.reduce(math.max);
      imageGeometry[id] = {
        'sourceSprite': sprite,
        'texture': texture,
        'imageType': image['type'],
        'useSpriteMesh': image['useSpriteMesh'],
        'preserveAspect': image['preserveAspect'],
        'rectSize': [placed.$1, placed.$2],
        'localPosition': [node['position'], node['positionZ']],
        'localScale': [node['scale'], node['scaleZ']],
        'parentId': node['parent'],
        'nodeWorldMatrix': placed.$3.toList(),
        if (externalLayout != null) 'nodePlanar': placed.$7,
        if (externalLayout != null) 'nodeAffine': placed.$8,
        if (externalLayout != null) 'drawWorldMatrix': drawMatrix,
        'canvasLogicalSize': [rootWidth, rootHeight],
        if (externalLayout != null)
          'externalLayout': {
            'sourceId': externalLayout.source.sourceIdentity,
            'recordsSHA256': externalLayout.source.packetSHA256,
            'physicalViewport': [width, height],
            'canvasScale': externalLayout.canvasScale,
            'targetId': externalLayout.target.id,
            'targetParentId': externalLayout.target.parentId,
            'targetRect': externalLayout.target.rect,
            'targetPivot': externalLayout.target.pivot,
            'containedScale': externalLayout.target.containedScale,
            'matrix3': externalLayout.target.matrix3,
          },
        'camera': camera,
        'clipFromCanvas': projection.toList(),
        'localDrawingBounds': [x0, y0, x1, y1],
        'clipVertices': mesh.vertices.toList(),
        'pixelPoints': pixelPoints,
        'unclippedPixelBounds': left == null || pixelPoints.length != 4
            ? null
            : [left, top, right! - left, bottom! - top!],
      };
    }
    final blend = image['blend'];
    if (blend != 'normal' && blend != 'additive') {
      throw UnsupportedError('native_still_blend:$blend');
    }
    materials[id] = NativeMaterial(
      texture: key,
      recipe: texture is String
          ? NativeMaterialRecipe.textured
          : NativeMaterialRecipe.solidColor,
      textureAlpha: textureAlpha,
      blend: blend == 'additive'
          ? NativeBlend.additive
          : NativeBlend.premultipliedAlpha,
    );
    if (texture is String) textures[key] = resolveTexture(texture);
    draws.add(NativeDraw(mesh: id, material: id));
  }
  const outputTarget = 'still-output';
  final outputDraws = <NativeDraw>[];
  if (presentable) {
    meshes['still-output-copy'] = ProjectedMesh(
      Float32List.fromList([
        -1,
        -1,
        0,
        1,
        0,
        1,
        1,
        1,
        1,
        1,
        1,
        -1,
        0,
        1,
        1,
        1,
        1,
        1,
        1,
        1,
        -1,
        1,
        0,
        1,
        0,
        0,
        1,
        1,
        1,
        1,
        1,
        1,
        0,
        1,
        1,
        0,
        1,
        1,
        1,
        1,
      ]),
      Uint16List.fromList([0, 1, 2, 2, 1, 3]),
    );
    materials['still-output-copy'] = const NativeMaterial(
      texture: 'still-main',
      textureAlpha: NativeTextureAlpha.premultiplied,
      blend: NativeBlend.opaque,
    );
    outputDraws.add(
      const NativeDraw(
        mesh: 'still-output-copy',
        material: 'still-output-copy',
      ),
    );
  }
  return StillGpuSnapshot(
    scene: NativeSceneResources(
      epoch: epoch,
      source: source,
      meshes: meshes,
      materials: materials,
      targets: {
        if (!presentable)
          'still-output': NativeTarget(width: width, height: height)
        else ...{
          'still-main': NativeTarget(
            width: width,
            height: height,
            format: NativeTargetFormat.rgba16f,
          ),
          'still-output': NativeTarget(
            width: width,
            height: height,
            presentable: true,
          ),
        },
      },
    ),
    frame: NativeFrame(
      epoch: epoch,
      mediaMicroseconds: 0,
      outputTarget: outputTarget,
      passes: [
        NativePass(
          target: !presentable ? outputTarget : 'still-main',
          draws: draws,
        ),
        if (presentable) NativePass(target: outputTarget, draws: outputDraws),
      ],
    ),
    textures: Map.unmodifiable(textures),
    sourceHash: sourceHash,
    sequences: List.unmodifiable(document['sequences'] as List),
    unsupportedFeatures: List.unmodifiable(
      (document['unsupportedFeatures'] as List).cast<String>(),
    ),
    imageGeometry: Map.unmodifiable(imageGeometry),
  );
}
