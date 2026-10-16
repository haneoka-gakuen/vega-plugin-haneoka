import type { StoryCanvasParticleBake, StoryCanvasParticleBakes, StoryCanvasScaler } from "@haneoka/vega/renderer-kit";

type RecordValue = Record<string, unknown>;
const record = (value: unknown): RecordValue => (value && typeof value === "object" ? (value as RecordValue) : {});
const entries = (value: unknown): RecordValue[] => (Array.isArray(value) ? value.map(record) : []);
const identity = (): number[] => [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1];
const vector = (value: unknown, fallback: number): [number, number, number] => {
  const v = record(value);
  return [Number(v.x ?? fallback), Number(v.y ?? fallback), Number(v.z ?? fallback)];
};
const multiply = (a: readonly number[], b: readonly number[]): number[] => {
  const result = new Array<number>(16);
  for (let column = 0; column < 4; column++)
    for (let row = 0; row < 4; row++) {
      let value = 0;
      for (let index = 0; index < 4; index++)
        value = Math.fround(value + Math.fround(a[index * 4 + row]! * b[column * 4 + index]!));
      result[column * 4 + row] = value;
    }
  return result;
};
const transform = (node: RecordValue): number[] => {
  const p = vector(node.position, 0),
    s = vector(node.scale, 1),
    q = record(node.rotation);
  const x = Number(q.x ?? 0),
    y = Number(q.y ?? 0),
    z = Number(q.z ?? 0),
    w = Number(q.w ?? 1),
    F = Math.fround;
  const xx = F(x * F(x * 2)),
    yy = F(y * F(y * 2)),
    zz = F(z * F(z * 2));
  const xy = F(x * F(y * 2)),
    xz = F(x * F(z * 2)),
    yz = F(y * F(z * 2));
  const wx = F(w * F(x * 2)),
    wy = F(w * F(y * 2)),
    wz = F(w * F(z * 2));
  return [
    F(F(1 - F(yy + zz)) * s[0]),
    F(F(xy + wz) * s[0]),
    F(F(xz - wy) * s[0]),
    0,
    F(F(xy - wz) * s[1]),
    F(F(1 - F(xx + zz)) * s[1]),
    F(F(yz + wx) * s[1]),
    0,
    F(F(xz + wy) * s[2]),
    F(F(yz - wx) * s[2]),
    F(F(1 - F(xx + yy)) * s[2]),
    0,
    p[0],
    p[1],
    p[2],
    1,
  ];
};
const isIdentity = (node: RecordValue): boolean => {
  const matrix = transform(node),
    expected = identity();
  return matrix.every((value, index) => Math.abs(value - expected[index]!) < 1e-6);
};

/** Coffee's static local/world bake, normalized before a renderer sees the frame. */
export function compileHaneokaFrameParticleBakes(frame: Readonly<RecordValue>): {
  bakes?: StoryCanvasParticleBakes;
  unresolved: readonly { system: string; reason: string }[];
} {
  const owners = entries(frame.uiParticles),
    runtime = record(frame.particleRuntime),
    camera = record(frame.uiParticleCanvas);
  if (!owners.length) return { unresolved: [] };
  const authoredScaler = record(camera.canvasScaler);
  const canvasScaler: StoryCanvasScaler | undefined = Array.isArray(authoredScaler.referenceResolution)
    ? {
        referenceResolution: authoredScaler.referenceResolution as [number, number],
        screenMatchMode: Number(authoredScaler.screenMatchMode),
        matchWidthOrHeight: Number(authoredScaler.matchWidthOrHeight),
        ...(authoredScaler.maxAspectThreshold !== undefined
          ? { maxAspectThreshold: Number(authoredScaler.maxAspectThreshold) }
          : {}),
      }
    : undefined;
  const systems = new Map(entries(runtime.particleSystems).map((value) => [String(value.id), value]));
  const renderers = new Map(entries(runtime.particleRenderers).map((value) => [String(value.nodeId), value]));
  const nodes = new Map(entries(runtime.nodes).map((value) => [String(value.id), value]));
  const descriptors = new Map(entries(frame.particles).map((value) => [String(value.system), value]));
  const unresolved: { system: string; reason: string }[] = [],
    bakes: StoryCanvasParticleBake[] = [];
  const scales: StoryCanvasParticleBakes["layoutScales"][number][] = [];
  const height = Number(camera.orthographicSize) * 2,
    near = Number(camera.nearClip),
    far = Number(camera.farClip),
    planeDistance = Number(camera.planeDistance);
  const cameraReady =
    camera.status === "resolved-source" &&
    camera.orthographic === true &&
    [height, near, far, planeDistance].every(Number.isFinite) &&
    height > 0 &&
    far > near &&
    planeDistance > 0;
  const transformAnimation = entries(runtime.animations).some((animation) =>
    entries(animation.curves).some((curve) => [3, 4].includes(Number(record(curve.binding).attributeHash))),
  );
  for (const owner of owners) {
    if (!owner.enabled) continue;
    const ownerId = String(owner.node),
      ownerNode = nodes.get(ownerId),
      scale = vector(owner.scale3D, 1);
    let ownerReason = !cameraReady
      ? "canvas-camera"
      : transformAnimation
        ? "animated-transform"
        : ![1, 2].includes(Number(owner.autoScalingMode)) ||
            owner.positionMode !== 0 ||
            owner.meshSharing !== 0 ||
            entries(owner.animatableProperties).length
          ? "owner-mode"
          : !scale.every((value) => Number.isFinite(value) && value > 0) ||
              scale[0] !== scale[1] ||
              scale[0] !== scale[2]
            ? "nonuniform-ui-scale"
            : "";
    let ancestor = ownerNode?.parentId;
    const ancestors = new Set<string>();
    while (ancestor && !ownerReason) {
      const id = String(ancestor),
        node = nodes.get(id);
      if (!node || ancestors.has(id) || !isIdentity(node)) {
        ownerReason = "transformed-ui-ancestor";
        break;
      }
      ancestors.add(id);
      ancestor = node.parentId;
    }
    const ownerRotation = record(ownerNode?.rotation);
    if (!ownerNode || vector(ownerRotation, 0).some((value) => value !== 0)) ownerReason ||= "rotated-ui-owner";
    let admitted = false;
    for (const rawId of Array.isArray(owner.particleSystems) ? owner.particleSystems : []) {
      const id = String(rawId),
        system = systems.get(id);
      if (!system?.emission) continue;
      const renderer = renderers.get(String(system.nodeId)),
        descriptor = descriptors.get(id);
      const initial = record(system.initial),
        gravity = record(initial.gravityModifier);
      let reason =
        ownerReason ||
        (![0, 1].includes(Number(system.scalingMode)) || ![0, 1].includes(Number(system.moveWithTransform))
          ? "simulation-scaling"
          : "");
      const physical = owner.autoScalingMode === 1 && system.scalingMode === 1 && system.moveWithTransform === 0;
      if (owner.autoScalingMode === 1 && (!physical || String(system.nodeId) !== ownerId || !isIdentity(ownerNode!)))
        reason ||= "physical-local-emitter";
      if (
        (!physical && renderer?.renderMode !== 0) ||
        (physical && renderer?.renderMode !== 1) ||
        renderer?.renderAlignment !== 0 ||
        !descriptor
      )
        reason ||= "billboard-layout";
      if (
        system.moveWithTransform === 1 &&
        (system.noise ||
          record(system.velocityOverLifetime).inWorldSpace ||
          record(system.limitVelocityOverLifetime).inWorldSpace ||
          Number(gravity.constantMax ?? 0) !== 0)
      )
        reason ||= "world-motion-module";
      const chain: RecordValue[] = [],
        visited = new Set<string>();
      let nodeId = String(system.nodeId);
      while (nodeId !== ownerId && !reason) {
        const node = nodes.get(nodeId);
        if (!node || visited.has(nodeId)) {
          reason = "emitter-owner-path";
          break;
        }
        visited.add(nodeId);
        chain.unshift(node);
        nodeId = String(node.parentId ?? "");
      }
      if (reason) {
        unresolved.push({ system: id, reason });
        continue;
      }
      let matrix = identity();
      for (const node of chain) matrix = multiply(matrix, transform(node));
      const sizeLimitScale: [number, number, number] = [
        Math.hypot(...matrix.slice(0, 3)),
        Math.hypot(...matrix.slice(4, 7)),
        Math.hypot(...matrix.slice(8, 11)),
      ];
      const positionMatrix = matrix.map((value, index) =>
        index % 4 < 3 ? Math.fround(value * scale[index % 4]!) : value,
      );
      bakes.push({
        system: id,
        renderer: String(renderer!.id),
        anchorNode: String(descriptor!.layoutNode),
        opacityNode: String(descriptor!.layoutNode),
        positionMatrix,
        sizeScale: [sizeLimitScale[0] * scale[0], sizeLimitScale[1] * scale[1], sizeLimitScale[2] * scale[2]],
        sizeLimitScale,
        cameraWorldHeight: height,
        cameraDepthRange: far - near,
        clipDepth: -(planeDistance - near) / (far - near),
        timeScale: Math.max(0, Number(owner.timeScaleMultiplier ?? 1)),
        ...(physical ? { physicalBake: { planeDistance } } : {}),
      });
      admitted = true;
    }
    if (admitted) scales.push({ node: String(owner.layoutNode), scale: [1, 1, 1] });
  }
  return { bakes: { version: 1, ...(canvasScaler ? { canvasScaler } : {}), systems: bakes, layoutScales: scales }, unresolved };
}
