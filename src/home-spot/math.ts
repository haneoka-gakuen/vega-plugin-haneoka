import type { HaneokaHomeSpotMouseFollow } from "./types";

export interface HaneokaHomeSpotPoint2 {
  readonly x: number;
  readonly y: number;
}

export const haneokaHomeSpotSelectionAlpha = (selectedCharacterId: unknown, characterId: unknown): number => {
  const selected = Number(selectedCharacterId) || 0;
  const character = Number(characterId) || 0;
  return !selected || !character || selected === character ? 1 : 0.3;
};

export const haneokaHomeSpotIntroProgress = (value: number, ease: number): number => {
  const progress = Math.max(0, Math.min(1, Number(value) || 0));
  return ease === 9 ? 1 - (1 - progress) ** 3 : progress;
};

export const haneokaHomeSpotPointerAngles = (
  pointer: HaneokaHomeSpotPoint2,
  follow: HaneokaHomeSpotMouseFollow | null | undefined,
): HaneokaHomeSpotPoint2 => {
  if (!follow) return { x: 0, y: 0 };
  const yaw = pointer.x < 0 ? -pointer.x * (Number(follow.maxLeft) || 0) : -pointer.x * (Number(follow.maxRight) || 0);
  const pitch = pointer.y < 0 ? -pointer.y * (Number(follow.maxUp) || 0) : -pointer.y * (Number(follow.maxDown) || 0);
  const threshold = Math.max(0, Number(follow.threshold) || 0);
  return {
    x: Math.abs(yaw) >= threshold ? yaw : 0,
    y: Math.abs(pitch) >= threshold ? pitch : 0,
  };
};

export const isHaneokaHomeSpotPointInsidePolygon = (
  point: HaneokaHomeSpotPoint2,
  polygon: readonly HaneokaHomeSpotPoint2[],
): boolean => {
  let inside = false;
  for (let index = 0, previous = polygon.length - 1; index < polygon.length; previous = index, index += 1) {
    const current = polygon[index];
    const prior = polygon[previous];
    if (!current || !prior) continue;
    const intersects =
      current.y > point.y !== prior.y > point.y &&
      point.x < ((prior.x - current.x) * (point.y - current.y)) / (prior.y - current.y || Number.EPSILON) + current.x;
    if (intersects) inside = !inside;
  }
  return inside;
};
