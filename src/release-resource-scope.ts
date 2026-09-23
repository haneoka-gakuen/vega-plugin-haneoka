import type { StoryResourceScope } from "@haneoka/vega/runtime";

const RELEASE_ID = /^[a-z0-9]+(?:-[a-z0-9]+)*$/iu;
const RUNTIME_ROOT = /^(?:cri|live2d|note-se|sonolus|unity|unity-json)\//iu;

export interface HaneokaReleaseResourceScopeOptions {
  readonly releaseId: string;
  /** Additional host-registered schemes such as a workspace resource plugin. */
  readonly acceptsExternal?: (url: string) => boolean;
}

/**
 * Creates the Haneoka release boundary consumed by Vega's portable players.
 * Vega only sees the generic scope contract; release routing stays here.
 */
export const createHaneokaReleaseResourceScope = (
  options: Readonly<HaneokaReleaseResourceScopeOptions>,
): StoryResourceScope => {
  const releaseId = String(options.releaseId || "").trim();
  if (!RELEASE_ID.test(releaseId)) {
    throw new TypeError(`Invalid Haneoka release id: ${releaseId}`);
  }
  const encoded = encodeURIComponent(releaseId);
  const assetPrefix = `/assets/${encoded}/`;
  const runtimePrefix = `/runtime/${encoded}/`;
  return Object.freeze({
    id: `haneoka:release:${releaseId}`,
    contains(url: string): boolean {
      if (/^(?:data:|blob:|https?:\/\/)/iu.test(url)) return true;
      if (options.acceptsExternal?.(url)) return true;
      if (url.startsWith(assetPrefix)) {
        return /^(?:Assets|Packages)\//u.test(url.slice(assetPrefix.length));
      }
      return url.startsWith(runtimePrefix) && RUNTIME_ROOT.test(url.slice(runtimePrefix.length));
    },
  });
};
