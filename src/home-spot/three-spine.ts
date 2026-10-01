import { normalizeHaneokaSpineCharacterEntry } from "../story-adapter";
import {
  haneokaHomeSpotIntroProgress,
  haneokaHomeSpotPointerAngles,
  haneokaHomeSpotSelectionAlpha,
  isHaneokaHomeSpotPointInsidePolygon,
} from "./math";
import type {
  CreateHaneokaHomeSpotSceneOptions,
  HaneokaHomeSpotRuntimeModules,
  HaneokaHomeSpotSceneController,
  HaneokaHomeSpotSpineLayer,
  HaneokaHomeSpotPngOptions,
} from "./types";

/*
 * SDK objects cross this file through one deliberately narrow dynamic edge.
 * The public plugin must compile without Three.js or Spine packages, while
 * the Haneoka application injects concrete, licensed modules at runtime.
 */
type RuntimeValue = any;
type RuntimeConstructor = new (...args: RuntimeValue[]) => RuntimeValue;

interface ResolvedRuntimeModules {
  readonly THREE: RuntimeValue;
  readonly GLTFLoader: RuntimeConstructor;
  readonly TextureAtlas: RuntimeConstructor;
  readonly ThreeJsTexture: RuntimeValue;
  readonly AtlasAttachmentLoader: RuntimeConstructor;
  readonly SkeletonBinary: RuntimeConstructor;
  readonly SkeletonJson: RuntimeConstructor;
  readonly SkeletonMesh: RuntimeConstructor;
}

interface NormalizedLayer {
  readonly key: string;
  readonly characterId: number;
  readonly sortingOrder: number;
  readonly animation: string;
  readonly skeleton: string;
  readonly atlas: string;
  readonly binary: boolean;
  readonly scale: number;
  readonly transform?: readonly number[];
  readonly hitPolygon?: HaneokaHomeSpotSpineLayer["hitPolygon"];
}

interface SpineInstance {
  readonly characterId: number;
  readonly sortingOrder: number;
  readonly animation: string;
  readonly hitPolygon?: HaneokaHomeSpotSpineLayer["hitPolygon"];
  readonly spine: RuntimeValue;
}

const runtimeRecord = (value: unknown): Record<string, unknown> =>
  value && typeof value === "object" ? (value as Record<string, unknown>) : {};

const firstString = (...values: unknown[]): string =>
  values.map((value) => (typeof value === "string" ? value.trim() : "")).find(Boolean) ?? "";

const requiredConstructor = (value: unknown, label: string): RuntimeConstructor => {
  if (typeof value !== "function") {
    throw new TypeError(`Haneoka Home Spot runtime is missing ${label}`);
  }
  return value as RuntimeConstructor;
};

const resolveModules = (modules: HaneokaHomeSpotRuntimeModules): ResolvedRuntimeModules => {
  const THREE = runtimeRecord(modules.three);
  const spine = runtimeRecord(modules.spine);
  const requiredThreeConstructors = [
    "Color",
    "Euler",
    "Matrix4",
    "MeshBasicMaterial",
    "PerspectiveCamera",
    "Scene",
    "Vector2",
    "Vector3",
    "WebGLRenderer",
  ] as const;
  for (const key of requiredThreeConstructors) {
    requiredConstructor(THREE[key], `Three.${key}`);
  }
  return {
    THREE,
    GLTFLoader: requiredConstructor(modules.GLTFLoader, "GLTFLoader"),
    TextureAtlas: requiredConstructor(spine.TextureAtlas, "Spine.TextureAtlas"),
    ThreeJsTexture: requiredConstructor(spine.ThreeJsTexture, "Spine.ThreeJsTexture"),
    AtlasAttachmentLoader: requiredConstructor(spine.AtlasAttachmentLoader, "Spine.AtlasAttachmentLoader"),
    SkeletonBinary: requiredConstructor(spine.SkeletonBinary, "Spine.SkeletonBinary"),
    SkeletonJson: requiredConstructor(spine.SkeletonJson, "Spine.SkeletonJson"),
    SkeletonMesh: requiredConstructor(spine.SkeletonMesh, "Spine.SkeletonMesh"),
  };
};

const numberAt = (value: readonly number[] | undefined, index: number, fallback: number): number => {
  const number = Number(value?.[index]);
  return Number.isFinite(number) ? number : fallback;
};

const unityVector = (
  THREE: RuntimeValue,
  value: readonly number[] | undefined,
  fallback: readonly [number, number, number],
): RuntimeValue =>
  new THREE.Vector3(numberAt(value, 0, fallback[0]), numberAt(value, 1, fallback[1]), -numberAt(value, 2, fallback[2]));

const convertedUnityMatrix = (THREE: RuntimeValue, value: readonly number[] | undefined): RuntimeValue => {
  if (!value || value.length !== 16) return new THREE.Matrix4();
  const unity = new THREE.Matrix4().set(...value);
  const reflection = new THREE.Matrix4().makeScale(1, 1, -1);
  return reflection.clone().multiply(unity).multiply(reflection);
};

const disposeObject = (root: RuntimeValue | null, closeImages = true): void => {
  const geometries = new Set<RuntimeValue>();
  const materials = new Set<RuntimeValue>();
  const textures = new Set<RuntimeValue>();
  const images = new Set<RuntimeValue>();
  for (const item of Array.isArray(root) ? root : [root]) {
    if (item?.isTexture) textures.add(item);
    item?.traverse?.((object: RuntimeValue) => {
      if (object.geometry) geometries.add(object.geometry);
      for (const material of Array.isArray(object.material)
        ? object.material
        : object.material
          ? [object.material]
          : []) {
        materials.add(material);
        for (const value of Object.values(material) as RuntimeValue[]) {
          if (value?.isTexture) textures.add(value);
        }
      }
    });
  }
  for (const geometry of geometries) geometry.dispose();
  for (const material of materials) material.dispose();
  for (const texture of textures) {
    images.add(texture.image);
    texture.dispose();
  }
  if (closeImages) for (const image of images) image?.close?.();
};

// Keep the source spelling of relative Unicode keys for the host resolver.
const childResourceKey = (owner: string, reference: string): string => {
  if (/^(?:[a-z][a-z0-9+.-]*:|\/)/iu.test(reference)) return reference;
  if (/^[a-z][a-z0-9+.-]*:/iu.test(owner)) return new URL(reference, owner).href;
  const path = owner.split(/[?#]/u)[0] || "";
  const joined = path.slice(0, path.lastIndexOf("/") + 1) + reference;
  const parts: string[] = [];
  for (const part of joined.split("/")) {
    if (part === ".") continue;
    if (part === "..") {
      if (parts.length && parts[parts.length - 1] !== "" && parts[parts.length - 1] !== "..") parts.pop();
      else if (!joined.startsWith("/")) parts.push(part);
    } else parts.push(part);
  }
  return parts.join("/");
};

const abortable = async <T>(operation: Promise<T>, signal: AbortSignal): Promise<T> => {
  let abort: (() => void) | undefined;
  const cancelled = new Promise<never>((_, reject) => {
    abort = () => reject(abortReason(signal));
    signal.addEventListener("abort", abort, { once: true });
    if (signal.aborted) abort();
  });
  try {
    const value = await Promise.race([operation, cancelled]);
    signal.throwIfAborted();
    return value;
  } finally {
    if (abort) signal.removeEventListener("abort", abort);
  }
};

const installPainterOrder = (mesh: RuntimeValue, Texture: RuntimeValue): void => {
  const next = mesh.nextBatch.bind(mesh);
  const configured = new WeakSet<object>();
  mesh.nextBatch = () => {
    const batch = next();
    if (configured.has(batch)) return batch;
    configured.add(batch);
    let cursor = 0;
    const clear = batch.clear.bind(batch);
    batch.clear = () => {
      cursor = 0;
      return clear();
    };
    batch.findMaterialGroup = (texture: RuntimeValue, blend: RuntimeValue) => {
      const index = cursor++;
      const material = batch.material[index] ?? batch.newMaterial();
      if (!batch.material[index]) batch.material.push(material);
      material.map = texture;
      Object.assign(material, Texture.toThreeJsBlending(blend));
      material.needsUpdate = true;
      return index;
    };
    return batch;
  };
};

const configureBackground = (root: RuntimeValue, renderer: RuntimeValue): void => {
  const anisotropy = renderer.capabilities.getMaxAnisotropy();
  root.traverse((object: RuntimeValue) => {
    if (!object.isMesh) return;
    object.renderOrder = 0;
    const materials = Array.isArray(object.material) ? object.material : [object.material];
    for (const material of materials) {
      if (!material) continue;
      material.depthTest = true;
      material.depthWrite = !material.transparent;
      material.toneMapped = false;
      if (material.alphaTest > 0) material.alphaToCoverage = true;
      if (material.map) {
        material.map.anisotropy = anisotropy;
        material.map.needsUpdate = true;
      }
    }
  });
};

const configureSpine = (instance: SpineInstance, renderer: RuntimeValue): void => {
  const anisotropy = renderer.capabilities.getMaxAnisotropy();
  instance.spine.traverse((object: RuntimeValue) => {
    if (!object.isMesh) return;
    object.renderOrder = 100 + instance.sortingOrder;
    const materials = Array.isArray(object.material) ? object.material : [object.material];
    for (const material of materials) {
      if (!material) continue;
      material.depthTest = true;
      material.depthWrite = false;
      material.toneMapped = false;
      if (material.map) {
        material.map.anisotropy = anisotropy;
        material.map.needsUpdate = true;
      }
    }
  });
};

const normalizeLayer = (
  layer: HaneokaHomeSpotSpineLayer,
  atlas: string,
  defaultScale: number | undefined,
  defaultAnimation: string | undefined,
): NormalizedLayer => {
  const normalized = normalizeHaneokaSpineCharacterEntry({
    ...layer,
    atlas,
    scale: defaultScale,
    animation: layer.animation || defaultAnimation,
  });
  const runtime = runtimeRecord(normalized.runtime);
  const skeleton = firstString(runtime.json, runtime.skel, runtime.model);
  if (!skeleton) {
    throw new TypeError(`Haneoka Home Spot layer ${layer.key || "<unnamed>"} has no skeleton`);
  }
  return {
    key: layer.key,
    characterId: Number(layer.characterId) || 0,
    sortingOrder: Number(layer.sortingOrder) || 0,
    animation: firstString(runtime.animation, layer.animation, defaultAnimation),
    skeleton,
    atlas: firstString(runtime.atlas, atlas),
    binary:
      Boolean(runtime.skel) || firstString(runtime.format) === "spine-binary" || /\.skel(?:[?#].*)?$/iu.test(skeleton),
    scale: Number(runtime.scale) || Number(defaultScale) || 0.01,
    ...(layer.transform ? { transform: layer.transform } : {}),
    ...(layer.hitPolygon ? { hitPolygon: layer.hitPolygon } : {}),
  };
};

const abortReason = (signal: AbortSignal): unknown =>
  signal.reason ?? new DOMException("Haneoka Home Spot loading was aborted", "AbortError");

const throwIfAborted = (signal: AbortSignal | undefined): void => {
  if (signal?.aborted) throw abortReason(signal);
};

const nowMilliseconds = (): number => globalThis.performance?.now?.() ?? Date.now();

class ThreeSpineHomeSpotScene implements HaneokaHomeSpotSceneController {
  readonly canvas: HTMLElement;
  private readonly options: CreateHaneokaHomeSpotSceneOptions;
  private readonly modules: ResolvedRuntimeModules;
  private readonly renderer: RuntimeValue;
  private readonly scene: RuntimeValue;
  private readonly camera: RuntimeValue;
  private readonly request = new AbortController();
  private readonly originalCursor: string;
  private readonly atlases = new Map<string, RuntimeValue>();
  private readonly bitmaps = new Set<ImageBitmap>();
  private readonly layerOrders = new WeakMap<object, number>();
  private readonly pointerTarget: RuntimeValue;
  private readonly smoothedAngles: RuntimeValue;
  private readonly desiredAngles: RuntimeValue;
  private readonly basePosition: RuntimeValue;
  private readonly startPosition: RuntimeValue;
  private readonly targetPosition: RuntimeValue;
  private readonly baseRotation: RuntimeValue;
  private readonly forward: RuntimeValue;
  private readonly orbitPosition: RuntimeValue;
  private readonly onAbort: () => void;
  private readonly onContextLost: (event: Event) => void;
  private readonly onContextRestored: () => void;
  private resizeObserver: ResizeObserver | null = null;
  private background: RuntimeValue | null = null;
  private readonly backgroundAssets = new Set<RuntimeValue>();
  private instances: SpineInstance[] = [];
  private hitInstances: SpineInstance[] = [];
  private selectedCharacterId: number;
  private previousFrameTime = 0;
  private introStartedAt = 0;
  private characterFadeStartedAt = 0;
  private contextLost = false;
  private disposedValue = false;

  constructor(options: CreateHaneokaHomeSpotSceneOptions, modules: ResolvedRuntimeModules) {
    this.options = options;
    this.originalCursor = options.host.style.cursor;
    this.modules = modules;
    const THREE = modules.THREE;
    this.renderer = new THREE.WebGLRenderer({
      antialias: true,
      alpha: false,
      depth: true,
      powerPreference: "high-performance",
    });
    this.renderer.outputColorSpace = THREE.SRGBColorSpace;
    this.renderer.setClearColor(new THREE.Color(options.clearColor), 1);
    this.renderer.domElement.classList.add("home-spot-canvas");
    this.renderer.domElement.setAttribute("role", "img");
    this.renderer.domElement.setAttribute("aria-label", options.ariaLabel);
    this.canvas = this.renderer.domElement as HTMLElement;
    this.scene = new THREE.Scene();
    const cameraSettings = options.descriptor.camera;
    this.camera = new THREE.PerspectiveCamera(
      Number(cameraSettings?.fieldOfView) || 20,
      Number(cameraSettings?.aspect) || 16 / 9,
      0.01,
      1000,
    );
    this.pointerTarget = new THREE.Vector2();
    this.smoothedAngles = new THREE.Vector2();
    this.desiredAngles = new THREE.Vector2();
    this.basePosition = unityVector(THREE, cameraSettings?.position, [0, 0, -1]);
    this.startPosition = unityVector(THREE, cameraSettings?.startPosition, [0, 0, -2]);
    this.targetPosition = unityVector(THREE, cameraSettings?.target, [0, 0, 0]);
    this.baseRotation = new THREE.Euler(0, 0, 0, "YXZ");
    this.forward = new THREE.Vector3();
    this.orbitPosition = new THREE.Vector3();
    this.camera.position.copy(this.basePosition);
    this.camera.lookAt(this.targetPosition);
    this.baseRotation.copy(this.camera.rotation).reorder("YXZ");
    this.renderer.setTransparentSort((left: RuntimeValue, right: RuntimeValue) => {
      const a = this.layerOrders.get(left.object.parent);
      const b = this.layerOrders.get(right.object.parent);
      if (a !== undefined && b !== undefined) {
        return (
          a - b || left.object.parent.children.indexOf(left.object) - right.object.parent.children.indexOf(right.object)
        );
      }
      if (a !== undefined) return 1;
      if (b !== undefined) return -1;
      return (
        left.groupOrder - right.groupOrder ||
        left.renderOrder - right.renderOrder ||
        right.z - left.z ||
        left.id - right.id
      );
    });
    this.selectedCharacterId = Number(options.selectedCharacterId) || 0;
    this.onAbort = () => this.dispose();
    this.onContextLost = (event) => {
      event.preventDefault();
      if (this.disposedValue) return;
      this.contextLost = true;
      this.renderer.setAnimationLoop(null);
      // Release upload caches while GL is lost, retaining decoded images for
      // re-upload. Old geometry/texture listeners must not delete stale handles
      // against the restored context.
      disposeObject(this.scene, false);
      this.options.onContextLost?.();
    };
    this.onContextRestored = () => {
      if (this.disposedValue) return;
      this.contextLost = false;
      if (this.background) configureBackground(this.background, this.renderer);
      for (const instance of this.instances) {
        configureSpine(instance, this.renderer);
      }
      if (this.background && this.instances.length) {
        this.replay();
        this.renderer.setAnimationLoop(this.renderFrame);
      }
      this.options.onContextRestored?.();
    };
  }

  get disposed(): boolean {
    return this.disposedValue;
  }

  async initialize(): Promise<void> {
    const descriptor = this.options.descriptor;
    const atlas = firstString(descriptor.atlas);
    const backgroundSource = firstString(descriptor.backgroundScene);
    const layers = (descriptor.layers ?? []).map((layer) =>
      normalizeLayer(layer, atlas, descriptor.scale, descriptor.animation),
    );
    this.options.host.appendChild(this.canvas);
    this.canvas.addEventListener("webglcontextlost", this.onContextLost);
    this.canvas.addEventListener("webglcontextrestored", this.onContextRestored);
    this.options.signal?.addEventListener("abort", this.onAbort, {
      once: true,
    });
    this.resize();
    if (typeof globalThis.ResizeObserver === "function") {
      this.resizeObserver = new ResizeObserver(() => this.resize());
      this.resizeObserver.observe(this.options.host);
    }

    const ordered = [...layers].sort((left, right) => left.sortingOrder - right.sortingOrder);
    await abortable(
      Promise.all([
        this.loadBackground(backgroundSource),
        ...[...new Set(ordered.map((layer) => layer.atlas))].map((key) => this.loadAtlas(key)),
      ]),
      this.request.signal,
    );
    this.checkLive();
    const skeletons = new Map<string, RuntimeValue>();
    await abortable(
      Promise.all(
        [...new Map(ordered.map((layer) => [layer.skeleton, layer])).values()].map(async (layer) => {
          // Keep only parsed data within this scene; encoded caches belong to hosts.
          const bytes = await this.readBytes(layer.skeleton);
          skeletons.set(layer.skeleton, layer.binary ? bytes : JSON.parse(new TextDecoder().decode(bytes)));
        }),
      ),
      this.request.signal,
    );
    this.checkLive();
    for (const layer of ordered) {
      const attachmentLoader = new this.modules.AtlasAttachmentLoader(this.atlases.get(layer.atlas));
      const parser = layer.binary
        ? new this.modules.SkeletonBinary(attachmentLoader)
        : new this.modules.SkeletonJson(attachmentLoader);
      parser.scale = layer.scale;
      const skeletonData = parser.readSkeletonData(skeletons.get(layer.skeleton));
      const spine = new this.modules.SkeletonMesh({
        skeletonData,
        twoColorTint: true,
        materialFactory: (parameters: Record<string, unknown>) =>
          new this.modules.THREE.MeshBasicMaterial({
            ...parameters,
            depthWrite: false,
            toneMapped: false,
            forceSinglePass: true,
          }),
      });
      const instance: SpineInstance = {
        characterId: layer.characterId,
        sortingOrder: layer.sortingOrder,
        animation: layer.animation,
        ...(layer.hitPolygon ? { hitPolygon: layer.hitPolygon } : {}),
        spine,
      };
      // Register ownership before any SDK parse/update can throw.
      this.layerOrders.set(spine, this.instances.length);
      this.instances.push(instance);
      installPainterOrder(spine, this.modules.ThreeJsTexture);
      spine.zOffset = 0;
      spine.matrixAutoUpdate = false;
      spine.matrix.copy(convertedUnityMatrix(this.modules.THREE, layer.transform));
      if (layer.animation) spine.state.setAnimation(0, layer.animation, false);
      spine.update(0);
      configureSpine(instance, this.renderer);
      this.scene.add(spine);
    }
    this.hitInstances = [...this.instances].sort((left, right) => right.sortingOrder - left.sortingOrder);
    this.replay();
    this.renderer.render(this.scene, this.camera);
    this.renderer.setAnimationLoop(this.renderFrame);
  }

  private checkLive(): void {
    this.request.signal.throwIfAborted();
  }

  private async readBytes(key: string): Promise<Uint8Array> {
    this.checkLive();
    const signal = this.request.signal;
    const operation = this.options.resources
      ? this.options.resources.load(key, signal)
      : fetch(key, { signal }).then(async (response) => {
          if (!response.ok) throw new Error(`Home Spot resource request failed (${response.status}): ${key}`);
          return new Uint8Array(await response.arrayBuffer());
        });
    const bytes = await abortable(operation, signal);
    this.checkLive();
    if (!(bytes instanceof Uint8Array)) throw new TypeError("Home Spot resources.load must return Uint8Array");
    return bytes;
  }

  private async loadAtlas(key: string): Promise<void> {
    const bytes = await this.readBytes(key);
    const atlas = new this.modules.TextureAtlas(new TextDecoder().decode(bytes));
    this.atlases.set(key, atlas);
    for (const page of atlas.pages) {
      const payload = await this.readBytes(childResourceKey(key, page.name));
      const bitmap = await createImageBitmap(new Blob([new Uint8Array(payload).buffer]), {
        premultiplyAlpha: page.pma ? "none" : "premultiply",
        colorSpaceConversion: "none",
      });
      if (this.disposedValue) {
        bitmap.close();
        this.checkLive();
      }
      this.bitmaps.add(bitmap);
      page.setTexture(new this.modules.ThreeJsTexture(bitmap, true));
    }
  }

  private async loadBackground(key: string): Promise<void> {
    const bytes = await this.readBytes(key);
    const buffer = new Uint8Array(bytes).buffer;
    const view = new DataView(buffer);
    const binary = bytes.byteLength >= 20 && view.getUint32(0, true) === 0x46546c67;
    const jsonLength = binary ? view.getUint32(12, true) : bytes.byteLength;
    const document = JSON.parse(new TextDecoder().decode(binary ? bytes.subarray(20, 20 + jsonLength) : bytes));
    const urls: string[] = [];
    try {
      // Resolve external buffers/images before GLTFLoader runs. Its internal
      // embedded/blob decoding stays with the native SDK; every external key
      // is read through the same host/default byte port and signal.
      for (const entry of [...(document.buffers || []), ...(document.images || [])]) {
        if (typeof entry.uri !== "string" || /^data:/iu.test(entry.uri)) continue;
        const payload = await this.readBytes(childResourceKey(key, entry.uri));
        const url = URL.createObjectURL(
          new Blob([new Uint8Array(payload).buffer], {
            type: entry.mimeType || "application/octet-stream",
          }),
        );
        urls.push(url);
        entry.uri = url;
      }
      this.checkLive();
      let input: string | ArrayBuffer = JSON.stringify(document);
      if (binary) {
        // Preserve BIN/extension chunks byte-for-byte while rewriting only
        // the JSON URI references to this parse's temporary Blob URLs.
        const json = new TextEncoder().encode(input);
        const padded = (json.byteLength + 3) & ~3;
        const tail = bytes.subarray(20 + jsonLength);
        const rebuilt = new Uint8Array(20 + padded + tail.byteLength);
        const header = new DataView(rebuilt.buffer);
        header.setUint32(0, 0x46546c67, true);
        header.setUint32(4, 2, true);
        header.setUint32(8, rebuilt.byteLength, true);
        header.setUint32(12, padded, true);
        header.setUint32(16, 0x4e4f534a, true);
        rebuilt.fill(0x20, 20, 20 + padded);
        rebuilt.set(json, 20);
        rebuilt.set(tail, 20 + padded);
        input = rebuilt.buffer;
      }
      const loader = new this.modules.GLTFLoader();
      // Observe native decoded dependencies as they complete, including ones
      // finishing after a sibling parse failure or cancellation.
      loader.register((parser: RuntimeValue) => {
        const dependency = parser.getDependency.bind(parser);
        parser.getDependency = (type: string, index: number) =>
          dependency(type, index).then((asset: RuntimeValue) => {
            if (type === "texture" || type === "mesh") {
              if (this.disposedValue) disposeObject(asset);
              else this.backgroundAssets.add(asset);
            }
            return asset;
          });
        return { name: "haneoka-home-spot-lifetime" };
      });
      const gltf = await loader.parseAsync(input, "");
      if (this.disposedValue) {
        disposeObject(gltf.scenes || [gltf.scene]);
        this.checkLive();
      }
      for (const scene of gltf.scenes || [gltf.scene]) this.backgroundAssets.add(scene);
      this.background = gltf.scene;
      this.background.matrixAutoUpdate = false;
      this.background.matrix.fromArray(this.options.descriptor.backgroundTransform);
      this.background.updateMatrixWorld(true);
      configureBackground(this.background, this.renderer);
      this.scene.add(this.background);
    } finally {
      // An in-flight native parse may still need these URLs after cancellation.
      // Revoke when that parse settles, including its late-success cleanup.
      for (const url of urls) URL.revokeObjectURL(url);
    }
  }

  async exportPng(options: HaneokaHomeSpotPngOptions = {}): Promise<Blob> {
    this.checkLive();
    if (this.contextLost || this.renderer.getContext().isContextLost() || !this.background || !this.instances.length)
      throw new Error("Home Spot is not ready for PNG export");
    const THREE = this.modules.THREE;
    const size = this.renderer.getDrawingBufferSize(new THREE.Vector2());
    const ratio = size.x / size.y;
    const width = options.width ?? (options.height === undefined ? size.x : Math.round(options.height * ratio));
    const height = options.height ?? (options.width === undefined ? size.y : Math.round(options.width / ratio));
    const gl = this.renderer.getContext();
    const maximum = Math.min(this.renderer.capabilities.maxTextureSize, gl.getParameter(gl.MAX_RENDERBUFFER_SIZE));
    if (
      ![width, height].every((value) => Number.isSafeInteger(value) && value > 0 && value <= maximum) ||
      width * height > 16 * 1024 * 1024
    ) {
      throw new RangeError("Home Spot PNG dimensions exceed the GPU/16-megapixel budget");
    }
    const originalSize = this.renderer.getSize(new THREE.Vector2());
    const pixelRatio = this.renderer.getPixelRatio();
    const aspect = this.camera.aspect;
    const canvas = this.options.host.ownerDocument.createElement("canvas");
    canvas.width = width;
    canvas.height = height;
    try {
      this.renderer.setPixelRatio(1);
      this.renderer.setSize(width, height, false);
      this.camera.aspect = width / height;
      this.camera.updateProjectionMatrix();
      this.renderer.render(this.scene, this.camera);
      const context = canvas.getContext("2d");
      if (!context) throw new Error("PNG copy context is unavailable");
      context.drawImage(this.renderer.domElement, 0, 0);
    } catch (error) {
      canvas.width = canvas.height = 0;
      throw error;
    } finally {
      this.renderer.setPixelRatio(pixelRatio);
      this.renderer.setSize(originalSize.x, originalSize.y, false);
      this.camera.aspect = aspect;
      this.camera.updateProjectionMatrix();
      if (!this.contextLost && !this.disposedValue) this.renderer.render(this.scene, this.camera);
    }
    const encoded = new Promise<Blob>((resolve, reject) => {
      canvas.toBlob((blob) => {
        canvas.width = canvas.height = 0;
        if (blob) resolve(blob);
        else reject(new Error("Home Spot PNG encoding failed"));
      }, "image/png");
    });
    try {
      return await abortable(encoded, this.request.signal);
    } finally {
      canvas.width = canvas.height = 0;
    }
  }

  setSelectedCharacter(characterId?: number): void {
    this.selectedCharacterId = Number(characterId) || 0;
  }

  pointerMove(clientX: number, clientY: number): number {
    if (this.disposedValue) return 0;
    const rect = this.options.host.getBoundingClientRect();
    const width = Math.max(1, rect.width);
    const height = Math.max(1, rect.height);
    this.pointerTarget.set(
      Math.max(-1, Math.min(1, ((clientX - rect.left) / width) * 2 - 1)),
      Math.max(-1, Math.min(1, ((clientY - rect.top) / height) * 2 - 1)),
    );
    const characterId = this.characterAt(clientX, clientY);
    this.options.host.style.cursor = characterId ? "pointer" : "default";
    return characterId;
  }

  pointerLeave(): void {
    this.pointerTarget.set(0, 0);
    this.options.host.style.cursor = "default";
  }

  selectAt(clientX: number, clientY: number): number {
    return this.disposedValue ? 0 : this.characterAt(clientX, clientY);
  }

  replay(): void {
    if (this.disposedValue) return;
    const now = nowMilliseconds();
    this.introStartedAt = now;
    this.characterFadeStartedAt = now;
    this.previousFrameTime = 0;
    this.pointerTarget.set(0, 0);
    this.smoothedAngles.set(0, 0);
    for (const instance of this.instances) {
      instance.spine.state.clearTracks();
      instance.spine.skeleton.setToSetupPose();
      instance.spine.skeleton.color.a =
        Number(this.options.descriptor.fadeInDuration) > 0
          ? 0
          : haneokaHomeSpotSelectionAlpha(this.selectedCharacterId, instance.characterId);
      if (instance.animation) {
        instance.spine.state.setAnimation(0, instance.animation, false);
      }
      instance.spine.update(0);
      configureSpine(instance, this.renderer);
    }
    this.applyCamera(now, 0);
  }

  resize(): void {
    if (this.disposedValue) return;
    const width = Math.max(1, this.options.host.clientWidth);
    const height = Math.max(1, this.options.host.clientHeight);
    const maximumRatio = Math.min(
      this.renderer.capabilities.maxTextureSize / width,
      this.renderer.capabilities.maxTextureSize / height,
    );
    const devicePixelRatio = Number(globalThis.devicePixelRatio) || 1;
    this.renderer.setPixelRatio(Math.min(devicePixelRatio, maximumRatio, 2));
    this.renderer.setSize(width, height, false);
    this.camera.aspect = width / height;
    this.camera.updateProjectionMatrix();
  }

  dispose(): void {
    if (this.disposedValue) return;
    this.disposedValue = true;
    this.request.abort(this.options.signal?.reason ?? new DOMException("Home Spot disposed", "AbortError"));
    this.options.signal?.removeEventListener("abort", this.onAbort);
    this.resizeObserver?.disconnect();
    this.resizeObserver = null;
    this.renderer.setAnimationLoop(null);
    this.canvas.removeEventListener("webglcontextlost", this.onContextLost);
    this.canvas.removeEventListener("webglcontextrestored", this.onContextRestored);
    for (const instance of this.instances) instance.spine.dispose();
    this.instances = [];
    this.hitInstances = [];
    disposeObject([...this.backgroundAssets]);
    this.backgroundAssets.clear();
    this.background = null;
    for (const atlas of this.atlases.values()) atlas.dispose();
    this.atlases.clear();
    for (const bitmap of this.bitmaps) bitmap.close();
    this.bitmaps.clear();
    this.renderer.dispose();
    this.renderer.forceContextLoss();
    this.canvas.remove();
    this.options.host.style.cursor = this.originalCursor;
  }

  private readonly renderFrame = (time: number): void => {
    if (this.disposedValue || this.contextLost || !this.background) {
      return;
    }
    const deltaTime = this.previousFrameTime ? Math.min(0.064, Math.max(0, (time - this.previousFrameTime) / 1000)) : 0;
    this.previousFrameTime = time;
    this.applyCamera(time, deltaTime);
    const fadeDuration = Math.max(0, Number(this.options.descriptor.fadeInDuration) || 0) * 1000;
    const fade = fadeDuration ? Math.max(0, Math.min(1, (time - this.characterFadeStartedAt) / fadeDuration)) : 1;
    for (const instance of this.instances) {
      instance.spine.skeleton.color.a =
        fade * haneokaHomeSpotSelectionAlpha(this.selectedCharacterId, instance.characterId);
      instance.spine.update(deltaTime);
    }
    this.renderer.render(this.scene, this.camera);
  };

  private applyCamera(time: number, deltaTime: number): void {
    const settings = this.options.descriptor.camera;
    if (!settings) return;
    const duration = Math.max(0, Number(settings.introDuration) || 0) * 1000;
    const elapsed = Math.max(0, time - this.introStartedAt);
    if (duration > 0 && elapsed < duration) {
      this.camera.rotation.copy(this.baseRotation);
      this.forward.set(0, 0, -1).applyEuler(this.baseRotation);
      this.orbitPosition.copy(this.basePosition).addScaledVector(this.forward, -(Number(settings.orbitRatio) || 0));
      this.camera.position.lerpVectors(
        this.startPosition,
        this.orbitPosition,
        haneokaHomeSpotIntroProgress(elapsed / duration, Number(settings.introEase) || 0),
      );
      return;
    }

    const desired = haneokaHomeSpotPointerAngles(this.pointerTarget, settings.mouseFollow);
    this.desiredAngles.set(desired.x, desired.y);
    const smoothTime = Math.max(0.001, Number(settings.mouseFollow?.smoothTime) || 0.1);
    this.smoothedAngles.lerp(this.desiredAngles, 1 - Math.exp(-Math.max(0, deltaTime) / smoothTime));
    const degreesToRadians = Math.PI / 180;
    this.camera.rotation.set(
      this.baseRotation.x + this.smoothedAngles.y * degreesToRadians,
      this.baseRotation.y + this.smoothedAngles.x * degreesToRadians,
      this.baseRotation.z,
      "YXZ",
    );
    this.forward.set(0, 0, -1).applyQuaternion(this.camera.quaternion);
    this.camera.position.copy(this.basePosition).addScaledVector(this.forward, -(Number(settings.orbitRatio) || 0));
  }

  private characterAt(clientX: number, clientY: number): number {
    const rect = this.options.host.getBoundingClientRect();
    const pointer = {
      x: clientX - rect.left,
      y: clientY - rect.top,
    };
    for (const instance of this.hitInstances) {
      if (!instance.characterId || !instance.hitPolygon?.length) continue;
      instance.spine.updateMatrixWorld(true);
      const corners = instance.hitPolygon.map((point) => {
        const projected = unityVector(this.modules.THREE, point, [0, 0, 0])
          .applyMatrix4(instance.spine.matrixWorld)
          .project(this.camera);
        return {
          x: (projected.x + 1) * rect.width * 0.5,
          y: (1 - projected.y) * rect.height * 0.5,
        };
      });
      if (isHaneokaHomeSpotPointInsidePolygon(pointer, corners)) {
        return instance.characterId;
      }
    }
    return 0;
  }
}

const validateDescriptor = (options: CreateHaneokaHomeSpotSceneOptions): void => {
  const descriptor = options.descriptor;
  if (
    !options.host ||
    descriptor.supported !== true ||
    !firstString(descriptor.atlas) ||
    !firstString(descriptor.backgroundScene) ||
    descriptor.backgroundTransform?.length !== 16 ||
    !descriptor.layers?.length
  ) {
    throw new TypeError("Haneoka Home Spot scene descriptor is incomplete");
  }
  if (typeof options.clearColor !== "string" || !options.clearColor.trim()) {
    throw new TypeError("Haneoka Home Spot clear color cannot be empty");
  }
};

/**
 * Create the complete Home Spot Three/Spine scene from host-injected modules.
 *
 * This function owns renderer, assets, animation loop, camera, hit testing,
 * resize/context lifecycle, and deterministic disposal.
 */
export const createHaneokaThreeSpineHomeSpotScene = async (
  options: CreateHaneokaHomeSpotSceneOptions,
): Promise<HaneokaHomeSpotSceneController> => {
  validateDescriptor(options);
  throwIfAborted(options.signal);
  const controller = new ThreeSpineHomeSpotScene(options, resolveModules(options.modules));
  try {
    await controller.initialize();
    throwIfAborted(options.signal);
    return controller;
  } catch (error) {
    controller.dispose();
    throw error;
  }
};
