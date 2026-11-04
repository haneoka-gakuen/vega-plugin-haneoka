import type { AdvStory, VegaPlayerHost } from "@haneoka/vega/engine";
import type { ScenePoint } from "@haneoka/vega-protocol/coordinates";

const point = (x: number, y = 0, z = 0) => Object.freeze({ x, y, z });
const focusAnchors = Object.freeze(
  Object.fromEntries(
    [-1.6, -1.2, -0.8, -0.4, 0, 0.4, 0.8, 1.2, 1.6].map((x, index) => [index + 1, point(x)]),
  ) as Record<number, ScenePoint>,
);

export const HANEOKA_STAGE_GEOMETRY = Object.freeze({
  screenReferenceWidth: 2560,
  screenReferenceHeight: 1440,
  minX: -1.6,
  maxX: 1.6,
  width: 3.2,
  backgroundSize: Object.freeze({ width: 22.31, height: 14.28145 }),
  backgroundFit: "authored" as const,
  fov: 39.6,
  initialCameraPosition: point(0),
  initialCameraRotation: point(0),
  characterFieldPosition: point(0, -0.45, 5.5),
  backgroundFieldPosition: point(0, 0, 16),
  characterBasePosition: point(0, -0.41, 0),
  characterFieldScale: 4,
  backgroundFieldScale: 1,
  positions: Object.freeze(Object.fromEntries([1, 3, 5, 7, 9].map((slot) => [slot, focusAnchors[slot]!]))),
  focusAnchors,
});

export const HANEOKA_CHARACTER_FRAMING = Object.freeze({
  basePosition: HANEOKA_STAGE_GEOMETRY.characterBasePosition,
  baseScale: 1.6,
  framing: Object.freeze({ head: point(0, 0.4), stomach: point(0, 0.07), eyeSpan: 0.0735 }),
});

export function planHaneokaStageBlocking(
  actors: readonly { target: string; order: number }[],
): Map<string, ScenePoint> {
  const stage = HANEOKA_STAGE_GEOMETRY;
  const bodyWidth =
    HANEOKA_CHARACTER_FRAMING.framing.eyeSpan * HANEOKA_CHARACTER_FRAMING.baseScale * stage.characterFieldScale * 5;
  const viewWidth = 2 * stage.characterFieldPosition.z * Math.tan((stage.fov * Math.PI) / 360) * (16 / 9);
  const ordered = actors
    .map((actor, index) => ({ ...actor, index }))
    .sort((a, b) => a.order - b.order || a.index - b.index);
  const spacing = Math.min(bodyWidth, Math.max(0, viewWidth - bodyWidth) / Math.max(1, ordered.length - 1));
  return new Map(
    ordered.map(({ target }, index) => [
      target,
      {
        x: stage.characterFieldPosition.x + (index - (ordered.length - 1) / 2) * spacing,
        y: stage.characterFieldPosition.y + stage.characterBasePosition.y * stage.characterFieldScale,
        z: stage.characterFieldPosition.z + stage.characterBasePosition.z * stage.characterFieldScale,
      },
    ]),
  );
}

/** Haneoka calibration can be selected independently from the input format. */
export function withHaneokaSceneProfile<Story extends AdvStory>(story: Story): Story {
  return {
    ...story,
    runtime: {
      ...story.runtime,
      stage: { ...HANEOKA_STAGE_GEOMETRY, ...story.runtime?.stage },
    },
  };
}

export const createHaneokaSceneProfileHost = (host: VegaPlayerHost): VegaPlayerHost => ({
  create(context, options) {
    return host.create(context, { ...options, story: withHaneokaSceneProfile(options.story) });
  },
});

/** Legacy value export lives with the source profile, outside neutral math. */
export const DEFAULT_SCENE_GEOMETRY = Object.freeze({
  ...HANEOKA_STAGE_GEOMETRY,
  cameraPosition: HANEOKA_STAGE_GEOMETRY.initialCameraPosition,
  cameraRotation: HANEOKA_STAGE_GEOMETRY.initialCameraRotation,
});
