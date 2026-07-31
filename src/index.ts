import {
  VEGA_INPUT_PORT,
  VEGA_STORAGE_PORT,
  defineVegaPlugin,
  defineVegaService,
  type VegaDisposable,
  type VegaInputEvent,
} from "@haneoka/vega/plugin";

const MAX_RESOURCE_BYTES = 256 * 1024 * 1024;
const SAFE_RESOURCE_KEY = /^[A-Za-z0-9][A-Za-z0-9._/@+-]{0,1023}$/u;
const SAFE_STORAGE_KEY = /^[A-Za-z0-9][A-Za-z0-9._:/-]{0,511}$/u;

export interface HaneokaHostBridge {
  loadResource(key: string, signal: AbortSignal): Promise<Uint8Array>;
  /** Returns `undefined` when the namespaced key does not exist. */
  readStorage(key: string, signal?: AbortSignal): Promise<unknown>;
  writeStorage(
    key: string,
    value: unknown,
    signal?: AbortSignal,
  ): Promise<void>;
  deleteStorage(key: string, signal?: AbortSignal): Promise<void>;
  subscribeInput?(
    listener: (event: VegaInputEvent) => void,
    signal: AbortSignal,
  ): VegaDisposable;
  translate?(key: string, fallback: string, locale?: string): string;
}

export interface HaneokaPluginOptions {
  readonly bridge: HaneokaHostBridge;
  readonly storageNamespace?: string;
  /** Selection priority on Vega's default storage port. */
  readonly storagePriority?: number;
  /** Selection priority on Vega's host-input port. */
  readonly inputPriority?: number;
}

export const HANEOKA_HOST_BRIDGE = defineVegaService<HaneokaHostBridge>(
  "haneoka.host-bridge.v1",
);

export const createHaneokaPlugin = (options: HaneokaPluginOptions) => {
  const storageNamespace = sanitizeNamespace(
    options.storageNamespace || "haneoka",
  );
  return defineVegaPlugin({
    manifest: {
      id: "haneoka.host",
      name: "Haneoka Host Bridge",
      version: "0.1.0",
      apiVersion: 1,
      description: "Host-supplied resources, storage, localization and input",
      capabilities: [
        "resource",
        "storage",
        ...(options.bridge.subscribeInput ? (["input"] as const) : []),
      ],
    },
    setup(context) {
      context.provide(HANEOKA_HOST_BRIDGE, options.bridge);
      context.contribute("resource", {
        id: "haneoka-resource",
        name: "Haneoka host resource resolver",
        schemes: ["haneoka"],
        async load(url, signal) {
          const key = resourceKey(url);
          const bytes = await options.bridge.loadResource(key, signal);
          if (!(bytes instanceof Uint8Array))
            throw new TypeError(
              "Haneoka resource bridge must return Uint8Array",
            );
          if (bytes.byteLength > MAX_RESOURCE_BYTES) {
            throw new RangeError(
              `Haneoka resource exceeds ${MAX_RESOURCE_BYTES} bytes`,
            );
          }
          return bytes;
        },
      });
      context.contribute(
        "storage",
        {
          id: "haneoka-storage",
          name: "Haneoka namespaced storage",
          get: (key, signal) =>
            options.bridge.readStorage(
              storageKey(storageNamespace, key),
              signal,
            ),
          set: (key, value, signal) =>
            options.bridge.writeStorage(
              storageKey(storageNamespace, key),
              value,
              signal,
            ),
          delete: (key, signal) =>
            options.bridge.deleteStorage(
              storageKey(storageNamespace, key),
              signal,
            ),
        },
        {
          singletonPort: VEGA_STORAGE_PORT,
          ...(options.storagePriority !== undefined
            ? { priority: options.storagePriority }
            : {}),
        },
      );
      if (options.bridge.subscribeInput) {
        context.contribute(
          "input",
          {
            id: "haneoka-input",
            name: "Haneoka host input",
            subscribe: (listener, signal) =>
              options.bridge.subscribeInput!(listener, signal),
          },
          {
            singletonPort: VEGA_INPUT_PORT,
            ...(options.inputPriority !== undefined
              ? { priority: options.inputPriority }
              : {}),
          },
        );
      }
    },
  });
};

const resourceKey = (url: URL): string => {
  const encoded = `${url.hostname}${url.pathname}`.replace(/^\/+/u, "");
  let key: string;
  try {
    key = decodeURIComponent(encoded);
  } catch {
    throw new TypeError("Haneoka resource URL contains invalid escaping");
  }
  if (
    !SAFE_RESOURCE_KEY.test(key) ||
    key.split("/").some((part) => !part || part === "." || part === "..")
  ) {
    throw new TypeError(`Unsafe Haneoka resource key: ${key}`);
  }
  return key;
};

const storageKey = (namespace: string, key: string): string => {
  if (!SAFE_STORAGE_KEY.test(key) || key.includes(".."))
    throw new TypeError(`Unsafe Haneoka storage key: ${key}`);
  return `${namespace}:${key}`;
};

const sanitizeNamespace = (value: string): string => {
  const namespace = value
    .trim()
    .replace(/[^A-Za-z0-9._-]+/gu, "-")
    .slice(0, 64);
  if (!namespace)
    throw new TypeError("Haneoka storage namespace cannot be empty");
  return namespace;
};

export default createHaneokaPlugin;
export {
  createHaneokaStoryAdapter,
  HANEOKA_ADV_CHAT_DEFAULT_DATA_ROOT,
  normalizeHaneokaCharacterEntry,
  normalizeHaneokaSpineCharacterEntry,
  normalizeHaneokaStoryCharacterEntry,
  type HaneokaLegacyCharacterFields,
} from "./story-adapter";
export {
  haneokaStoryResourceAliases,
  type HaneokaStoryResourceKind,
} from "./resource-aliases";
export {
  hydrateStoryPayload,
  hydrateStoryTextPayload,
  type StoryHydrationMissingResource,
  type StoryHydrationOptions,
  type StoryResourceAliases,
} from "./story-hydration";
export {
  resolveHaneokaCubismRuntimeSource,
  type HaneokaCubismModelDescriptor,
  type HaneokaCubismRuntimeSource,
} from "./cubism-adapter";
export {
  createHaneokaReleaseResourceScope,
  type HaneokaReleaseResourceScopeOptions,
} from "./release-resource-scope";
export {
  HANEOKA_LIVE2D_BACKGROUND_SOURCE_PATHS,
  resolveHaneokaLive2DCatalogSource,
  type HaneokaLive2DCatalogEntry,
  type HaneokaLive2DCatalogSource,
  type HaneokaLive2DCatalogTransport,
} from "./live2d-catalog-source";
export {
  haneokaFallbackMotionSyncAudioScales,
  type HaneokaMotionSyncAudioScales,
  type HaneokaVowel,
} from "./motion-sync-profile";
export {
  HANEOKA_CHAT_ICON_SOURCE_PATHS,
  resolveHaneokaChatIconSprites,
  type HaneokaChatIconSprites,
} from "./source-assets";
export * from "./home-spot";
