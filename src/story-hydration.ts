import type { AdvStory } from "@haneoka/vega";
import { createHaneokaStoryAdapter, normalizeHaneokaCharacterEntry } from "./story-adapter";
import { haneokaStoryResourceAliases, type HaneokaStoryResourceKind } from "./resource-aliases";

const adaptHaneokaCharacterFields = createHaneokaStoryAdapter({
  modelField: "live2d",
  keyField: "live2dKey",
});

// Source-authored ADV scripts occasionally contain a known animation alias
// that does not match the exported Cubism catalogue. Keep that compatibility
// at the Haneoka source boundary instead of making the generic Cubism provider
// guess at arbitrary near-matches.
const HANEOKA_MOTION_ALIASES = new Map([["mtn_surprise01_R", "mtn_surprised01_R"]]);

const collectionValues = (value: unknown): Array<Record<string, unknown>> => {
  if (Array.isArray(value))
    return value.filter((entry): entry is Record<string, unknown> => Boolean(entry && typeof entry === "object"));
  if (value && typeof value === "object")
    return Object.values(value).filter((entry): entry is Record<string, unknown> =>
      Boolean(entry && typeof entry === "object"),
    );
  return [];
};

const mapCollectionRecords = (
  value: unknown,
  mapper: (entry: Readonly<Record<string, unknown>>) => Record<string, unknown>,
): unknown => {
  if (Array.isArray(value)) {
    return value.map((entry) =>
      entry && typeof entry === "object" && !Array.isArray(entry) ? mapper(entry as Record<string, unknown>) : entry,
    );
  }
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value).map(([key, entry]) => [
        key,
        entry && typeof entry === "object" && !Array.isArray(entry) ? mapper(entry as Record<string, unknown>) : entry,
      ]),
    );
  }
  return value;
};

const indexBy = (value: unknown, keysOf: (entry: Record<string, unknown>) => unknown[]) => {
  const result = new Map<string, Record<string, unknown>>();
  for (const entry of collectionValues(value)) {
    for (const key of keysOf(entry)) {
      const identity = String(key ?? "").trim();
      if (identity && !result.has(identity)) result.set(identity, entry);
    }
  }
  return result;
};

export type StoryResourceAliases = (
  kind: HaneokaStoryResourceKind,
  entry: Readonly<Record<string, unknown>>,
) => readonly string[];

const resourceIndex = (value: unknown, kind: HaneokaStoryResourceKind, aliases: StoryResourceAliases) =>
  indexBy(value, (entry) => [...aliases(kind, entry)]);

const normalizedResourceIndex = (
  sourceValue: unknown,
  normalizedValue: unknown,
  kind: HaneokaStoryResourceKind,
  aliases: StoryResourceAliases,
) => {
  const sourceEntries = collectionValues(sourceValue);
  const normalizedEntries = collectionValues(normalizedValue);
  const result = new Map<string, Record<string, unknown>>();
  for (const [index, entry] of normalizedEntries.entries()) {
    const source = sourceEntries[index] ?? entry;
    for (const key of [...aliases(kind, source), ...aliases(kind, entry)]) {
      const identity = String(key ?? "").trim();
      if (identity && !result.has(identity)) result.set(identity, entry);
    }
  }
  return result;
};

const record = (value: unknown): Record<string, unknown> =>
  value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : {};

export interface StoryHydrationMissingResource {
  kind: string;
  reference: string;
}

export interface StoryHydrationOptions {
  /** Editor previews omit unresolved media while normal playback remains strict. */
  missingResource?: "throw" | "omit";
  onMissingResource?: (resource: StoryHydrationMissingResource) => void;
  /** Active authoring hosts inject their ADV alias contract here. */
  resourceAliases?: StoryResourceAliases;
}

const unresolvedResource = (key: unknown, kind: string, options: StoryHydrationOptions): undefined => {
  const identity = String(key || "");
  if (options.missingResource !== "omit") {
    throw new Error(`Story ${kind} reference is unresolved: ${identity || "<empty>"}`);
  }
  options.onMissingResource?.({ kind, reference: identity });
  return undefined;
};

const resolvedEntry = (
  registry: Record<string, unknown>,
  key: unknown,
  kind: string,
  options: StoryHydrationOptions,
): Record<string, unknown> | undefined => {
  const identity = String(key || "");
  const value = registry[identity];
  return identity && value && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : unresolvedResource(identity, kind, options);
};

const resolvedIndexedEntry = (
  registry: Map<string, Record<string, unknown>>,
  key: unknown,
  kind: string,
  options: StoryHydrationOptions,
): Record<string, unknown> | undefined => {
  const identity = String(key ?? "").trim();
  const value = registry.get(identity);
  return identity && value ? value : unresolvedResource(identity, kind, options);
};

const presentRecords = (values: Array<Record<string, unknown> | undefined>): Record<string, unknown>[] =>
  values.filter((value): value is Record<string, unknown> => value !== undefined);

export const hydrateStoryPayload = (
  payload: Record<string, unknown>,
  options: StoryHydrationOptions = {},
): Record<string, unknown> => {
  const aliases = options.resourceAliases ?? haneokaStoryResourceAliases;
  const assets = (payload.assets || {}) as Record<string, unknown>;
  const runtime = record(payload.runtime);
  const postEffects = record(runtime.postEffects);
  const stages = record(runtime.stages);
  const chatPresets = record(record(runtime.chatAssets).presetsByRef);
  const hydratedStages = new Map<string, Record<string, unknown>>();
  const hydrateStage = (key: unknown) => {
    const identity = String(key || "");
    const cached = hydratedStages.get(identity);
    if (cached) return cached;
    const stage = resolvedEntry(stages, identity, "stage", options);
    if (!stage) return undefined;
    const refs = stage.environmentPostEffectRefs;
    const hydrated = {
      ...stage,
      environmentPostEffects: Array.isArray(refs)
        ? presentRecords(refs.map((reference) => resolvedEntry(postEffects, reference, "post-effect", options)))
        : [],
    };
    hydratedStages.set(identity, hydrated);
    return hydrated;
  };
  const backgroundEntries = collectionValues(assets.backgrounds).map((entry) => {
    const stage = entry.stageRef ? hydrateStage(entry.stageRef) : undefined;
    return {
      ...entry,
      ...(stage ? { stage } : {}),
    };
  });
  const backgrounds = resourceIndex(backgroundEntries, "background", aliases);
  const stills = resourceIndex(assets.stills, "still", aliases);
  const sounds = resourceIndex(assets.sounds, "sound", aliases);
  const frameEntries = collectionValues(assets.frames).map((entry) => {
    const animation = record(entry.animation);
    return {
      ...entry,
      ...(entry.name === "adv_frame_eyeblink_blink" && animation.loop === false && Number(animation.duration) > 0
        ? { oneShotSeconds: Number(animation.duration) }
        : {}),
    };
  });
  const frames = resourceIndex(frameEntries, "frame", aliases);
  const effects = resourceIndex(assets.effects, "effect", aliases);
  const videos = resourceIndex(assets.videos, "video", aliases);
  const normalizedLive2dAssets = mapCollectionRecords(assets.live2d, normalizeHaneokaCharacterEntry);
  // Preserve the registry entry's identity across Character/In/Motion
  // commands. Vega uses that identity to associate animation references with
  // a model variant and avoid the conservative full-catalog preload path.
  const normalizedCharacterModels = new WeakMap<object, Record<string, unknown>>();
  for (const entry of collectionValues(normalizedLive2dAssets)) {
    normalizedCharacterModels.set(entry, entry);
  }
  const normalizedCharacterModel = (model: Record<string, unknown>): Record<string, unknown> => {
    const cached = normalizedCharacterModels.get(model);
    if (cached) return cached;
    const normalized = normalizeHaneokaCharacterEntry(model);
    normalizedCharacterModels.set(model, normalized);
    normalizedCharacterModels.set(normalized, normalized);
    return normalized;
  };
  const live2d = normalizedResourceIndex(assets.live2d, normalizedLive2dAssets, "live2d", aliases);

  const hydrateCommand = (input: unknown): unknown => {
    if (!input || typeof input !== "object") return input;
    const command = input as Record<string, unknown>;
    const {
      backgroundRef,
      stillRef,
      bgmRef,
      seRef,
      voiceRefs,
      postEffectRef,
      frameRef,
      effectRef,
      videoRef,
      timeline,
      commandGroup,
      ...fields
    } = command;
    const result: Record<string, unknown> = { ...fields };
    if (typeof result.motionName === "string") {
      result.motionName = HANEOKA_MOTION_ALIASES.get(result.motionName) ?? result.motionName;
    }
    if (!result.background && backgroundRef) {
      const value = resolvedIndexedEntry(backgrounds, backgroundRef, "background", options);
      if (value) result.background = value;
    }
    if (!result.still && stillRef) {
      const value = resolvedIndexedEntry(stills, stillRef, "still", options);
      if (value) result.still = value;
    }
    if (!result.bgm && bgmRef) {
      const value = resolvedIndexedEntry(sounds, bgmRef, "BGM", options);
      if (value) result.bgm = value;
    }
    if (!result.se && seRef) {
      const value = resolvedIndexedEntry(sounds, seRef, "sound-effect", options);
      if (value) result.se = value;
    }
    if (!result.postEffect && postEffectRef) {
      const value = resolvedEntry(postEffects, postEffectRef, "post-effect", options);
      if (value) result.postEffect = value;
    }
    if (!result.frame && frameRef) {
      const value = resolvedIndexedEntry(frames, frameRef, "frame", options);
      if (value) result.frame = value;
    }
    if (!result.effect && effectRef) {
      const value = resolvedIndexedEntry(effects, effectRef, "effect", options);
      if (value) result.effect = value;
    }
    if (!result.video && videoRef) {
      const value = resolvedIndexedEntry(videos, videoRef, "video", options);
      if (value) result.video = value;
    }
    const needsHydratedVoices = result.voices == null || (Array.isArray(result.voices) && result.voices.length === 0);
    if (needsHydratedVoices && Array.isArray(voiceRefs)) {
      result.voices = presentRecords(voiceRefs.map((key) => resolvedIndexedEntry(sounds, key, "voice", options)));
    }
    if (!result.live2d && result.live2dKey) {
      const value = resolvedIndexedEntry(live2d, result.live2dKey, "Live2D", options);
      if (value) result.live2d = value;
    }
    if (result.live2d && typeof result.live2d === "object" && !Array.isArray(result.live2d)) {
      result.live2d = normalizedCharacterModel(result.live2d as Record<string, unknown>);
    }
    if (result.chatPresetRef) {
      const preset = resolvedEntry(chatPresets, result.chatPresetRef, "chat preset", options);
      if (preset) {
        const targetChatID = Number(preset.id);
        if (!Number.isSafeInteger(targetChatID) || targetChatID <= 0) {
          if (options.missingResource !== "omit") {
            throw new Error(`Story chat preset has an invalid native identity: ${String(result.chatPresetRef)}`);
          }
          options.onMissingResource?.({
            kind: "chat preset",
            reference: String(result.chatPresetRef),
          });
        } else if (!Number.isSafeInteger(Number(result.targetChatID)) || Number(result.targetChatID) <= 0) {
          result.targetChatID = targetChatID;
        }
      }
    }
    if (timeline && typeof timeline === "object") {
      const timelineRecord = timeline as Record<string, unknown>;
      result.timeline = {
        ...timelineRecord,
        signals: Array.isArray(timelineRecord.signals)
          ? timelineRecord.signals.map((signal) => {
              if (!signal || typeof signal !== "object") return signal;
              const record = signal as Record<string, unknown>;
              return { ...record, episode: hydrateCommand(record.episode) };
            })
          : [],
      };
    }
    if (commandGroup && typeof commandGroup === "object" && !Array.isArray(commandGroup)) {
      const group = commandGroup as Record<string, unknown>;
      result.commandGroup = {
        ...group,
        actions: Array.isArray(group.actions)
          ? group.actions.map((action) => {
              if (!action || typeof action !== "object" || Array.isArray(action)) return action;
              const actionRecord = action as Record<string, unknown>;
              return {
                ...actionRecord,
                command: hydrateCommand(actionRecord.command),
              };
            })
          : [],
      };
    }
    return result;
  };

  return adaptHaneokaCharacterFields({
    ...payload,
    runtime,
    assets: {
      ...assets,
      backgrounds: backgroundEntries,
      ...(normalizedLive2dAssets === undefined ? {} : { live2d: normalizedLive2dAssets }),
    },
    commands: Array.isArray(payload.commands) ? payload.commands.map(hydrateCommand) : [],
  } as AdvStory) as unknown as Record<string, unknown>;
};

/** Resolve transcript audio without requiring the WebGL runtime or stage registry. */
export const hydrateStoryTextPayload = (
  payload: Record<string, unknown>,
  options: StoryHydrationOptions = {},
): Record<string, unknown> => {
  const aliases = options.resourceAliases ?? haneokaStoryResourceAliases;
  const assets = (payload.assets || {}) as Record<string, unknown>;
  const sounds = resourceIndex(assets.sounds, "sound", aliases);

  const hydrateCommand = (input: unknown): unknown => {
    if (!input || typeof input !== "object" || Array.isArray(input)) return input;
    const command = input as Record<string, unknown>;
    const result: Record<string, unknown> = { ...command };
    const needsHydratedVoices = result.voices == null || (Array.isArray(result.voices) && result.voices.length === 0);
    if (needsHydratedVoices && Array.isArray(command.voiceRefs)) {
      result.voices = presentRecords(
        command.voiceRefs.map((key) => resolvedIndexedEntry(sounds, key, "voice", options)),
      );
    }
    if (command.timeline && typeof command.timeline === "object" && !Array.isArray(command.timeline)) {
      const timeline = command.timeline as Record<string, unknown>;
      result.timeline = {
        ...timeline,
        signals: Array.isArray(timeline.signals)
          ? timeline.signals.map((signal) => {
              if (!signal || typeof signal !== "object" || Array.isArray(signal)) return signal;
              const record = signal as Record<string, unknown>;
              return { ...record, episode: hydrateCommand(record.episode) };
            })
          : [],
      };
    }
    if (command.commandGroup && typeof command.commandGroup === "object" && !Array.isArray(command.commandGroup)) {
      const group = command.commandGroup as Record<string, unknown>;
      result.commandGroup = {
        ...group,
        actions: Array.isArray(group.actions)
          ? group.actions.map((action) => {
              if (!action || typeof action !== "object" || Array.isArray(action)) return action;
              const actionRecord = action as Record<string, unknown>;
              return {
                ...actionRecord,
                command: hydrateCommand(actionRecord.command),
              };
            })
          : [],
      };
    }
    return result;
  };

  return {
    ...payload,
    localization: {
      ...record(payload.localization),
      arrayOrder: ["ja", "en", "zh-TW", "zh-CN", "ko"],
      locales: ["ja", "en", "zh-TW", "zh-CN", "ko"],
      defaultLocale: "ja",
    },
    commands: Array.isArray(payload.commands) ? payload.commands.map(hydrateCommand) : [],
  };
};
