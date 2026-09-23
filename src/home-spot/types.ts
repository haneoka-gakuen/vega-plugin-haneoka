export type HaneokaHomeSpotVector3 = readonly [number, number, number];

export interface HaneokaHomeSpotSpineLayer {
  readonly key: string;
  readonly characterId?: number;
  readonly sortingOrder?: number;
  readonly animation?: string;
  readonly skeleton?: string;
  readonly transform?: readonly number[];
  readonly hitPolygon?: readonly HaneokaHomeSpotVector3[];
  readonly format?: unknown;
  readonly runtime?: Readonly<Record<string, unknown>>;
  readonly [key: string]: unknown;
}

export interface HaneokaHomeSpotMouseFollow {
  readonly sensitivity?: number;
  readonly threshold?: number;
  readonly maxLeft?: number;
  readonly maxRight?: number;
  readonly maxUp?: number;
  readonly maxDown?: number;
  readonly smoothTime?: number;
}

export interface HaneokaHomeSpotCamera {
  readonly position?: readonly number[];
  readonly target?: readonly number[];
  readonly startPosition?: readonly number[];
  readonly fieldOfView?: number;
  readonly aspect?: number;
  readonly orbitRatio?: number;
  readonly introDuration?: number;
  readonly introEase?: number;
  readonly mouseFollow?: HaneokaHomeSpotMouseFollow;
}

/** Host-neutral scene data recovered from a Haneoka Home Spot. */
export interface HaneokaHomeSpotSceneDescriptor {
  readonly supported?: boolean;
  readonly atlas?: string;
  readonly backgroundScene?: string;
  readonly backgroundTransform?: readonly number[];
  readonly animation?: string;
  readonly scale?: number;
  readonly fadeInDuration?: number;
  readonly camera?: HaneokaHomeSpotCamera;
  readonly layers?: readonly HaneokaHomeSpotSpineLayer[];
}

/**
 * Runtime modules supplied by the application build.
 *
 * The plugin intentionally types these values as opaque. It validates the
 * constructors it consumes at runtime, so the public package neither imports
 * nor redistributes Three.js or an Esoteric Software Spine runtime.
 */
export interface HaneokaHomeSpotRuntimeModules {
  readonly three: object;
  readonly GLTFLoader: unknown;
  readonly spine: Readonly<{
    AssetManager: unknown;
    AtlasAttachmentLoader: unknown;
    SkeletonBinary: unknown;
    SkeletonJson: unknown;
    SkeletonMesh: unknown;
  }>;
}

export interface CreateHaneokaHomeSpotSceneOptions {
  readonly host: HTMLElement;
  readonly descriptor: HaneokaHomeSpotSceneDescriptor;
  readonly modules: HaneokaHomeSpotRuntimeModules;
  readonly clearColor: string;
  readonly ariaLabel: string;
  readonly selectedCharacterId?: number;
  readonly signal?: AbortSignal;
  readonly onContextLost?: () => void;
  readonly onContextRestored?: () => void;
}

export interface HaneokaHomeSpotSceneController {
  readonly canvas: HTMLElement;
  readonly disposed: boolean;
  setSelectedCharacter(characterId?: number): void;
  pointerMove(clientX: number, clientY: number): number;
  pointerLeave(): void;
  selectAt(clientX: number, clientY: number): number;
  replay(): void;
  resize(): void;
  dispose(): void;
}
