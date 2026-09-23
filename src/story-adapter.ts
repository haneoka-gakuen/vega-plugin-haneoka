import type { AdvStory } from "@haneoka/vega";
import { haneokaFallbackMotionSyncAudioScales } from "./motion-sync-profile";

export const HANEOKA_ADV_CHAT_DEFAULT_DATA_ROOT = "Assets/AddressableResources/Adv/Chat/Data/_template/data";

const HANEOKA_ADV_CHAT_LEGACY_DEFAULT_DATA_ROOT = `${HANEOKA_ADV_CHAT_DEFAULT_DATA_ROOT}/ChatLINE`;

export interface HaneokaLegacyCharacterFields {
  readonly modelField: string;
  readonly keyField: string;
  /** Keep source fields beside Vega's portable aliases during migration. */
  readonly preserveSourceFields?: boolean;
}

const recordValue = (value: unknown): Record<string, unknown> =>
  value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : {};

const firstString = (...values: unknown[]): string =>
  values.map((value) => (typeof value === "string" ? value.trim() : "")).find(Boolean) ?? "";

/**
 * Converts Haneoka catalog metadata into Vega's source-neutral character
 * entry. It deliberately does not invent a `format` tag: Cubism and Spine
 * plugins identify their standard model entry files themselves.
 */
export const normalizeHaneokaStoryCharacterEntry = (
  value: Readonly<Record<string, unknown>>,
): Record<string, unknown> => {
  const runtime = recordValue(value.runtime);
  const model = firstString(
    runtime.model,
    runtime.modelUrl,
    runtime.model3Json,
    value.model,
    value.modelUrl,
    value.model3Json,
  );
  const moc = firstString(runtime.moc, runtime.moc3, value.moc, value.moc3);
  const imageUrl = firstString(runtime.imageUrl, value.imageUrl, value.faceImage, value.thumbnailImage);
  const textures = Array.isArray(runtime.textures)
    ? runtime.textures
    : Array.isArray(value.textures)
      ? value.textures
      : undefined;
  const physics = firstString(runtime.physics, value.physics);
  const fallbackMotionSyncAudioScales =
    runtime.fallbackMotionSyncAudioScales ??
    value.fallbackMotionSyncAudioScales ??
    haneokaFallbackMotionSyncAudioScales(value);
  return {
    ...value,
    runtime: {
      ...runtime,
      ...(model ? { model } : {}),
      ...(moc ? { moc } : {}),
      ...(textures ? { textures: [...textures] } : {}),
      ...(physics ? { physics } : {}),
      ...(imageUrl ? { imageUrl } : {}),
      ...(fallbackMotionSyncAudioScales ? { fallbackMotionSyncAudioScales } : {}),
    },
  };
};

/**
 * Normalizes one Haneoka-authored Spine layer. Scene-only placement metadata
 * stays on the source record while the standard skeleton/atlas pair is exposed
 * through the portable runtime entry.
 */
export const normalizeHaneokaSpineCharacterEntry = (
  value: Readonly<Record<string, unknown>>,
): Record<string, unknown> => {
  const runtime = recordValue(value.runtime);
  const portableSource = { ...value };
  delete portableSource.runtime;
  delete portableSource.model;
  delete portableSource.modelUrl;
  delete portableSource.skeleton;
  delete portableSource.skel;
  delete portableSource.json;
  delete portableSource.atlas;
  const portableRuntime = { ...runtime };
  // `model` is a Haneoka source alias in this adapter. Do not retain it beside
  // the standard Spine field because generic runtimes use `model` for Cubism.
  delete portableRuntime.model;
  delete portableRuntime.modelUrl;
  delete portableRuntime.skeleton;
  delete portableRuntime.skel;
  delete portableRuntime.json;
  const binarySource = firstString(runtime.skel, value.skel);
  const jsonSource = firstString(runtime.json, value.json);
  const genericSource = firstString(runtime.skeleton, value.skeleton);
  const modelSource = firstString(runtime.model, runtime.modelUrl, value.model, value.modelUrl);
  const skeleton = binarySource || jsonSource || genericSource || modelSource;
  const atlas = firstString(runtime.atlas, value.atlas);
  const imageUrl = firstString(runtime.imageUrl, value.imageUrl, value.faceImage, value.thumbnailImage);
  const explicitFormat = firstString(runtime.format, value.format).toLowerCase();
  const genericOrModelSource = genericSource || modelSource;
  const hasStandardGenericSuffix = /\.(?:json|skel)(?:[?#].*)?$/iu.test(genericOrModelSource);
  const binary =
    Boolean(binarySource) ||
    (!jsonSource &&
      (/\.skel(?:[?#].*)?$/iu.test(genericOrModelSource) ||
        (explicitFormat === "spine-binary" && !hasStandardGenericSuffix)));
  return {
    ...portableSource,
    runtime: {
      ...portableRuntime,
      ...(skeleton
        ? {
            ...(binary ? { skel: skeleton } : { json: skeleton }),
          }
        : {}),
      ...(atlas ? { atlas } : {}),
      ...((runtime.scale ?? value.scale) !== undefined ? { scale: runtime.scale ?? value.scale } : {}),
      ...(firstString(runtime.animation, value.animation)
        ? { animation: firstString(runtime.animation, value.animation) }
        : {}),
      ...(imageUrl ? { imageUrl } : {}),
    },
  };
};

/** Routes one source-specific record to the matching portable model tuple. */
export const normalizeHaneokaCharacterEntry = (value: Readonly<Record<string, unknown>>): Record<string, unknown> => {
  const runtime = recordValue(value.runtime);
  const format = firstString(runtime.format, value.format).toLowerCase();
  if (format === "spine" || format === "spine-json" || format === "spine-binary") {
    return normalizeHaneokaSpineCharacterEntry(value);
  }
  if (format) return normalizeHaneokaStoryCharacterEntry(value);
  const model = firstString(runtime.model, runtime.modelUrl, value.model, value.modelUrl);
  if (/model3?\.json(?:[?#].*)?$/iu.test(model)) {
    return normalizeHaneokaStoryCharacterEntry(value);
  }
  const atlas = firstString(runtime.atlas, value.atlas);
  const explicitSource = firstString(runtime.skel, value.skel, runtime.json, value.json);
  const genericSource = firstString(
    runtime.skeleton,
    value.skeleton,
    runtime.model,
    runtime.modelUrl,
    value.model,
    value.modelUrl,
  );
  return atlas && (explicitSource || genericSource)
    ? normalizeHaneokaSpineCharacterEntry(value)
    : normalizeHaneokaStoryCharacterEntry(value);
};

const SAFE_FIELD = /^[A-Za-z_$][A-Za-z0-9_$]{0,127}$/u;
const BLOCKED_FIELDS = new Set(["__proto__", "constructor", "prototype", "characterModel", "characterKey"]);

/**
 * Builds a host-boundary migration for a legacy character payload.
 *
 * Vega remains unaware of provider-specific field names. Haneoka passes those
 * names from its source packaging layer and receives the portable command
 * shape expected by the public engine.
 */
export const createHaneokaStoryAdapter = (fields: HaneokaLegacyCharacterFields) => {
  const modelField = safeField(fields.modelField);
  const keyField = safeField(fields.keyField);
  if (modelField === keyField) throw new TypeError("Legacy character model and key fields must differ");

  return (source: AdvStory): AdvStory => {
    const story = structuredClone(source);
    // Descriptor identity is part of Vega's animation-usage binding: commands
    // that resolve the same source model must stay on one shared descriptor so
    // the preloader can select the referenced motions instead of conservatively
    // warming the complete catalog for every separately normalized clone.
    const normalizedCharacterModels = new WeakMap<object, Record<string, unknown>>();
    const normalizedCharacterModel = (model: Record<string, unknown>): Record<string, unknown> => {
      const cached = normalizedCharacterModels.get(model);
      if (cached) return cached;
      const normalized = normalizeHaneokaCharacterEntry(model);
      normalizedCharacterModels.set(model, normalized);
      normalizedCharacterModels.set(normalized, normalized);
      return normalized;
    };
    const runtime = recordValue(story.runtime);
    const chatAssets = recordValue(runtime.chatAssets);
    const defaultDataRoot = firstString(chatAssets.defaultDataRoot).replace(/\/+$/u, "");
    if (!defaultDataRoot || defaultDataRoot === HANEOKA_ADV_CHAT_LEGACY_DEFAULT_DATA_ROOT) {
      story.runtime = {
        ...runtime,
        chatAssets: {
          ...chatAssets,
          defaultDataRoot: HANEOKA_ADV_CHAT_DEFAULT_DATA_ROOT,
        },
      } as NonNullable<AdvStory["runtime"]>;
    }
    visit(story, (record) => {
      if (!Object.hasOwn(record, "command")) return;
      if (record.characterModel === undefined && record[modelField] !== undefined) {
        const model = record[modelField];
        record.characterModel =
          model && typeof model === "object" && !Array.isArray(model)
            ? normalizedCharacterModel(model as Record<string, unknown>)
            : model;
      }
      if (record.characterKey === undefined && record[keyField] !== undefined) {
        record.characterKey = record[keyField];
      }
      if (!fields.preserveSourceFields) {
        delete record[modelField];
        delete record[keyField];
      }
    });
    return story;
  };
};

const visit = (
  value: unknown,
  operation: (record: Record<string, unknown>) => void,
  seen = new WeakSet<object>(),
): void => {
  if (!value || typeof value !== "object" || seen.has(value)) return;
  seen.add(value);
  if (Array.isArray(value)) {
    for (const entry of value) visit(entry, operation, seen);
    return;
  }
  const record = value as Record<string, unknown>;
  operation(record);
  for (const entry of Object.values(record)) visit(entry, operation, seen);
};

const safeField = (value: string): string => {
  const field = value.trim();
  if (!SAFE_FIELD.test(field) || BLOCKED_FIELDS.has(field)) {
    throw new TypeError(`Unsafe legacy character field: ${field}`);
  }
  return field;
};
