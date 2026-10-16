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
