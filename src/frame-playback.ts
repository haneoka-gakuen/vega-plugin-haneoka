import type { AdvFrameAnimator, AdvFrameAnimatorState, AdvFrameEntry } from "@haneoka/vega";
import { compileHaneokaFrameParticleBakes } from "./frame-particles";

/** Adapt the source controller packet to renderer-neutral frame playback data. */
export const normalizeHaneokaFrameEntry = (input: Readonly<Record<string, unknown>>): Record<string, unknown> => {
  const particles = compileHaneokaFrameParticleBakes(input);
  input = {
    ...input,
    ...(particles.bakes ? { canvasParticleBakes: particles.bakes } : {}),
    ...(particles.unresolved.length ? { unresolvedCanvasParticleBakes: particles.unresolved } : {}),
  };
  const frame = input as AdvFrameEntry;
  const authored = frame.animator;
  if (!authored) return { ...input };
  const states: Record<string, AdvFrameAnimatorState> = {};
  for (const [name, state] of Object.entries(authored.states)) {
    if (![state.duration, state.speed].every(Number.isFinite) || state.duration < 0)
      throw new TypeError(`Invalid frame controller state: ${frame.name ?? ""}:${name}`);
    states[name] = state.animation
      ? { ...state, animation: { ...state.animation, loop: state.loop, speed: Math.abs(state.speed) } }
      : state;
  }
  if (!states[authored.defaultState]) throw new TypeError(`Frame controller has no default state: ${frame.name ?? ""}`);
  const animator: AdvFrameAnimator = { ...authored, states };
  const initial = states[animator.defaultState]?.animation;
  return { ...input, animator, ...(initial ? { animation: initial } : {}) };
};
