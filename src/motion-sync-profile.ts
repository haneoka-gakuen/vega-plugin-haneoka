export type HaneokaVowel = "A" | "I" | "U" | "E" | "O";

export type HaneokaMotionSyncAudioScales = Readonly<
  Partial<Record<HaneokaVowel, number>>
>;

const SAKIKO_AUDIO_SCALES = Object.freeze({
  I: 1,
} satisfies HaneokaMotionSyncAudioScales);

/**
 * Adds the one source-specific compatibility hint needed by older Haneoka
 * catalogs. The Cubism plugin consumes this neutral data; it does not know
 * Haneoka character identities.
 */
export const haneokaFallbackMotionSyncAudioScales = (
  entry: unknown,
): HaneokaMotionSyncAudioScales | undefined => {
  const source =
    entry && typeof entry === "object"
      ? (entry as Record<string, unknown>)
      : {};
  const characterId = Number(source.characterId);
  const characterKey = String(source.characterKey || "").padStart(3, "0");
  return characterId === 10 || characterKey === "010"
    ? SAKIKO_AUDIO_SCALES
    : undefined;
};
