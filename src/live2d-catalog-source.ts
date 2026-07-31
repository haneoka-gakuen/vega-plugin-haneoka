const LIVE2D_RUNTIME_ROOT = "live2d";

export const HANEOKA_LIVE2D_BACKGROUND_SOURCE_PATHS = Object.freeze({
  common:
    "Assets/AddressableResources/UI/Texture/common_background.png",
  mygo:
    "Assets/AddressableResources/Band/1/band_studio_background.png",
  mujica:
    "Assets/AddressableResources/Band/2/band_studio_background.png",
});

export interface HaneokaLive2DCatalogTransport {
  /** Validate or translate a source-authored resource reference. */
  resolveResource(value: unknown): string;
  /** Resolve a path under the host's provisioned runtime output. */
  runtimeAsset(path: string): string;
  /** Resolve a path from an authorized source release. */
  sourceAsset(path: string): string;
}

export interface HaneokaLive2DCatalogEntry {
  readonly live2dKey?: string;
  readonly modelType?: string;
  readonly runtime?: Readonly<Record<string, unknown>>;
  readonly profile?: Readonly<{
    defaultMotionName?: string;
    defaultExpressionName?: string;
    anchors?: Readonly<{
      head?: Readonly<{
        position?: Readonly<{ x?: number; y?: number; z?: number }>;
      }>;
    }>;
  }>;
  readonly motions?: readonly Readonly<{ name?: string }>[];
  readonly expressions?: readonly Readonly<{ name?: string }>[];
  readonly harmonicMotion?: unknown;
}

export interface HaneokaLive2DCatalogSource {
  readonly modelUrl: string;
  readonly motions: readonly string[];
  readonly expressions: readonly string[];
  readonly defaultMotionName?: string;
  readonly defaultExpressionName?: string;
  readonly loopDefaultMotion: boolean;
  readonly harmonicMotion?: unknown;
  readonly headAnchor?: Readonly<{ x: number; y: number }>;
  readonly backgrounds: Readonly<{
    common: string;
    mygo: string;
    mujica: string;
  }>;
}

const names = (
  values: readonly Readonly<{ name?: string }>[] | undefined,
): readonly string[] =>
  Object.freeze(
    [
      ...new Set(
        (values || [])
          .map(({ name }) => String(name || "").trim())
          .filter(Boolean),
      ),
    ],
  );

const finitePoint = (
  value: Readonly<{ x?: number; y?: number }> | undefined,
): Readonly<{ x: number; y: number }> | undefined => {
  const x = Number(value?.x);
  const y = Number(value?.y);
  return Number.isFinite(x) && Number.isFinite(y)
    ? Object.freeze({ x, y })
    : undefined;
};

const canonicalModelKey = (value: unknown): string => {
  const key = String(value || "").trim();
  if (
    !key ||
    /[\\\u0000-\u001f\u007f]/u.test(key) ||
    key.split("/").some((part) => !part || part === "." || part === "..")
  ) {
    throw new TypeError(`Invalid Haneoka Live2D model key: ${key}`);
  }
  return key;
};

/**
 * Normalizes Haneoka catalogue metadata into the ordinary model descriptor
 * consumed by a Cubism viewer. The host supplies transport only; release
 * layout and fallback behavior do not leak into the component.
 */
export const resolveHaneokaLive2DCatalogSource = (
  entry: Readonly<HaneokaLive2DCatalogEntry>,
  transport: Readonly<HaneokaLive2DCatalogTransport>,
): HaneokaLive2DCatalogSource => {
  const runtime = entry.runtime || {};
  const authoredModel = transport.resolveResource(runtime.model);
  const modelUrl =
    authoredModel ||
    transport.runtimeAsset(
      `${LIVE2D_RUNTIME_ROOT}/${canonicalModelKey(entry.live2dKey)}/model3.json`,
    );
  if (!modelUrl) throw new TypeError("Haneoka Live2D model URL is empty");

  const motions = names(entry.motions);
  const expressions = names(entry.expressions);
  const preferredMotion = String(
    entry.profile?.defaultMotionName || "",
  ).trim();
  const defaultMotionName = motions.includes(preferredMotion)
    ? preferredMotion
    : entry.modelType === "live" && motions.includes("mtn_idle_01")
      ? "mtn_idle_01"
      : undefined;
  const preferredExpression = String(
    entry.profile?.defaultExpressionName || "",
  ).trim();
  const defaultExpressionName = expressions.includes(preferredExpression)
    ? preferredExpression
    : undefined;
  const harmonicMotion = runtime.harmonicMotion ?? entry.harmonicMotion;
  const headAnchor = finitePoint(entry.profile?.anchors?.head?.position);

  return Object.freeze({
    modelUrl,
    motions,
    expressions,
    ...(defaultMotionName ? { defaultMotionName } : {}),
    ...(defaultExpressionName ? { defaultExpressionName } : {}),
    loopDefaultMotion:
      entry.modelType === "live" && Boolean(defaultMotionName),
    ...(harmonicMotion !== undefined ? { harmonicMotion } : {}),
    ...(headAnchor ? { headAnchor } : {}),
    backgrounds: Object.freeze({
      common: transport.sourceAsset(
        HANEOKA_LIVE2D_BACKGROUND_SOURCE_PATHS.common,
      ),
      mygo: transport.sourceAsset(
        HANEOKA_LIVE2D_BACKGROUND_SOURCE_PATHS.mygo,
      ),
      mujica: transport.sourceAsset(
        HANEOKA_LIVE2D_BACKGROUND_SOURCE_PATHS.mujica,
      ),
    }),
  });
};
