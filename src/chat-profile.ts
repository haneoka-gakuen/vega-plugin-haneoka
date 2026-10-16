import { resolveStoryFrameLayout, type StoryFrameLayout } from "@haneoka/vega/renderer-kit";
import raw from "./chat-profile-data.json";

export interface HaneokaChatSourceRole {
  readonly node: string;
  readonly image?: {
    readonly color: readonly [number, number, number, number];
    readonly source: string | null;
    readonly type: number;
    readonly ppuMultiplier: number;
    readonly sprite?: {
      readonly ppu: number;
      readonly border: Readonly<Record<"x" | "y" | "z" | "w", number>>;
      readonly rect: Readonly<Record<"x" | "y" | "width" | "height", number>>;
    };
  };
  readonly text?: {
    readonly color: readonly [number, number, number, number];
    readonly fontSize: number;
    readonly fontStyle: number;
    readonly wrappingMode: number;
    readonly overflowMode: number;
  };
}

export interface HaneokaChatSourceProfile {
  readonly sourceHash: string;
  readonly dataRoot: string;
  readonly rootSize: readonly [number, number];
  readonly roles: Readonly<Record<string, HaneokaChatSourceRole>>;
  readonly layout: StoryFrameLayout;
  readonly group: boolean;
  readonly layoutMode: number;
  readonly visibility: Readonly<{ identity: boolean; read: boolean }>;
  readonly windowPosition: Readonly<{ x: number; y: number }>;
  readonly windowRotation: Readonly<{ x: number; y: number; z: number }>;
}

const source = raw as unknown as {
  readonly schema: string;
  readonly sourceId: string;
  readonly packetSHA256: string;
  readonly referencePixelsPerUnit: number;
  readonly profiles: Readonly<Record<string, HaneokaChatSourceProfile>>;
};
export const HANEOKA_CHAT_PROFILE_SOURCE = Object.freeze({
  schema: source.schema,
  sourceId: source.sourceId,
  packetSHA256: source.packetSHA256,
});

export function haneokaChatSourceProfile(windowAsset = "", dataRoot = ""): HaneokaChatSourceProfile | undefined {
  const name =
    windowAsset
      .split("/")
      .pop()
      ?.replace(/\.prefab$/u, "") ?? "";
  if (source.profiles[name]) return source.profiles[name];
  const normalized = dataRoot.replace(/\/+$/u, "").replace(/\/ChatLINE$/u, "");
  return Object.values(source.profiles).find((profile) => profile.dataRoot.replace(/\/ChatLINE$/u, "") === normalized);
}

const rectangles = new WeakMap<
  HaneokaChatSourceProfile,
  ReadonlyMap<string, readonly [number, number, number, number]>
>();

/** Original root-local UI rectangles, resolved by the common retained Image/frame geometry. */
export function haneokaChatSourceRect(
  profile: HaneokaChatSourceProfile,
  role: string,
): readonly [number, number, number, number] | undefined {
  let values = rectangles.get(profile);
  if (!values) {
    const placed = resolveStoryFrameLayout(profile.layout, profile.rootSize[0], profile.rootSize[1]);
    values = new Map(
      placed.map((p) => {
        const x = -p.node.pivot[0] * p.width,
          y = -(1 - p.node.pivot[1]) * p.height;
        const points = [
          [x, y],
          [x + p.width, y],
          [x, y + p.height],
          [x + p.width, y + p.height],
        ];
        const xs = points.map(([px, py]) => p.transform[0] * px! + p.transform[2] * py! + p.transform[4]);
        const ys = points.map(([px, py]) => p.transform[1] * px! + p.transform[3] * py! + p.transform[5]);
        const left = Math.min(...xs),
          top = Math.min(...ys);
        return [p.node.id, [left, top, Math.max(...xs) - left, Math.max(...ys) - top] as const] as const;
      }),
    );
    rectangles.set(profile, values);
  }
  const id = profile.roles[role]?.node;
  return id ? values.get(id) : undefined;
}

export function haneokaChatSourceImageBorders(
  profile: HaneokaChatSourceProfile,
  role: string,
): readonly number[] | undefined {
  const image = profile.roles[role]?.image,
    sprite = image?.sprite;
  if (!sprite || !image) return undefined;
  const ppu = (sprite.ppu / source.referencePixelsPerUnit) * image.ppuMultiplier;
  return [sprite.border.w / ppu, sprite.border.z / ppu, sprite.border.y / ppu, sprite.border.x / ppu];
}

export function haneokaChatSourceMaskBorders(profile: HaneokaChatSourceProfile): readonly number[] | undefined {
  return haneokaChatSourceImageBorders(profile, "mask");
}

export function haneokaChatSourceMaskSlices(profile: HaneokaChatSourceProfile): readonly number[] | undefined {
  const border = profile.roles.mask?.image?.sprite?.border;
  return border ? [border.w, border.z, border.y, border.x] : undefined;
}
