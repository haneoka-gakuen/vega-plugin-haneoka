import { VEGA_ADV_OPCODE as CMD, VEGA_COMMAND_GROUP_OPCODE } from "@haneoka/vega-protocol/opcodes";
import { haneokaStoryResourceAliases, type HaneokaStoryResourceKind } from "./resource-aliases.js";

type RecordValue = Readonly<Record<string, unknown>>;
export interface HaneokaTranscriptEntry {
  readonly id: string;
  readonly commandIndex: number;
  readonly kind:
    | "dialogue"
    | "message"
    | "location"
    | "conversation"
    | "subtitle"
    | "image"
    | "video"
    | "stamp"
    | "choices"
    | "voice";
  readonly command: RecordValue;
  readonly mediaKind?: "background" | "still";
  readonly source?: string;
  readonly voices: readonly RecordValue[];
}
const record = (value: unknown): RecordValue =>
  value && typeof value === "object" && !Array.isArray(value) ? (value as RecordValue) : {};
const records = (value: unknown): RecordValue[] =>
  (Array.isArray(value) ? value : Object.values(record(value))).map(record);
const hasText = (value: unknown): boolean =>
  typeof value === "string"
    ? Boolean(value.trim())
    : value && typeof value === "object"
      ? Object.values(value).some(hasText)
      : false;
const mediaUrl = (value: RecordValue): string =>
  String(value.playableUrl || value.url || value.src || value.thumbnail || "");

export function projectHaneokaTranscript(payload: RecordValue): readonly HaneokaTranscriptEntry[] {
  const assets = record(payload.assets);
  const index = (collection: string, kind: HaneokaStoryResourceKind) => {
    const map = new Map<string, RecordValue>();
    for (const asset of records(assets[collection]))
      for (const alias of haneokaStoryResourceAliases(kind, asset)) map.set(alias, asset);
    return map;
  };
  const backgrounds = index("backgrounds", "background"),
    stills = index("stills", "still"),
    sounds = index("sounds", "sound"),
    videos = index("videos", "video");
  const stamps = new Map(
    records(assets.stamps).flatMap((asset) =>
      [asset.assetName, asset.resourceRef, asset.id].filter(Boolean).map((key) => [String(key), asset] as const),
    ),
  );
  const entries: HaneokaTranscriptEntry[] = [];
  const visibleStills = new Set<string>();
  let conversation = "";
  const resolve = (
    command: RecordValue,
    field: string,
    reference: string,
    registry: ReadonlyMap<string, RecordValue>,
  ) => {
    const direct = record(command[field]);
    if (mediaUrl(direct)) return direct;
    return registry.get(String(command[reference] || command.targetAssetName || "")) ?? direct;
  };
  const append = (command: RecordValue, commandIndex: number, path: string, depth: number) => {
    if (depth > 64) throw new RangeError("Story command nesting is too deep");
    const opcode = command.command;
    if (opcode === VEGA_COMMAND_GROUP_OPCODE) {
      records(record(command.commandGroup).actions)
        .map((action, index) => ({ action, index }))
        .sort((a, b) => Number(a.action.atSeconds || 0) - Number(b.action.atSeconds || 0) || a.index - b.index)
        .forEach(({ action, index }) => append(record(action.command), commandIndex, `${path}/${index}`, depth + 1));
      return;
    }
    const id = String(command.commandId || path);
    const voices = records(command.voices);
    if (!voices.length && Array.isArray(command.voiceRefs))
      for (const ref of command.voiceRefs) {
        const voice = sounds.get(String(ref));
        if (voice) voices.push(voice);
      }
    const add = (
      kind: HaneokaTranscriptEntry["kind"],
      media: Pick<HaneokaTranscriptEntry, "source" | "mediaKind"> = {},
    ) => entries.push({ id, commandIndex, kind, command, voices, ...media });
    switch (opcode) {
      case CMD.Talk:
        if (hasText(command.text)) add("dialogue");
        break;
      case CMD.Voice:
        if (voices.length) add("voice");
        break;
      case CMD.ChatTalk:
        if (hasText(command.text)) add("message");
        break;
      case CMD.Location:
        if (hasText(command.text)) add("location");
        break;
      case CMD.Subtitles:
        if (hasText(command.text)) add("subtitle");
        break;
      case CMD.ChatWindow: {
        const params = Array.isArray(command.params) ? command.params : [];
        const key = String(
          command.targetAssetName || command.targetName || command.chatWindowAssetName || command.targetChatID || "",
        ).trim();
        const memory = String(
          command.chatMemoryId || params[2] || command.targetChatID || command.targetName || key,
        ).trim();
        const identity = JSON.stringify([key, memory, Math.max(0, Math.trunc(Number(params[1]) || 0))]);
        if (conversation === identity) conversation = "";
        else {
          conversation = identity;
          add("conversation");
        }
        break;
      }
      case CMD.Stage: {
        const source = mediaUrl(resolve(command, "background", "backgroundRef", backgrounds));
        if (source) add("image", { source, mediaKind: "background" });
        break;
      }
      case CMD.Still: {
        const source = mediaUrl(resolve(command, "still", "stillRef", stills));
        if (source) {
          if (visibleStills.has(source)) visibleStills.delete(source);
          else {
            visibleStills.add(source);
            add("image", { source, mediaKind: "still" });
          }
        }
        break;
      }
      case CMD.Movie:
      case CMD.Clip: {
        const source = mediaUrl(resolve(command, "video", "videoRef", videos));
        if (source) add("video", { source });
        break;
      }
      case CMD.ChatStamp: {
        const source = mediaUrl(resolve(command, "stamp", "stampRef", stamps));
        add("stamp", source ? { source } : {});
        break;
      }
      case CMD.ChoiceShow:
        if (Array.isArray(command.choices) && command.choices.length) add("choices");
        break;
      case CMD.Timeline:
        records(record(command.timeline).signals).forEach((signal, index) =>
          append(record(signal.episode), commandIndex, `${path}/signal/${index}`, depth + 1),
        );
        break;
    }
  };
  records(payload.commands).forEach((command, index) => append(command, index, `command/${index}`, 0));
  return entries;
}
