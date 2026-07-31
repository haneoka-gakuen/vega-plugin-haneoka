/**
 * Structural subset of `CubismModelDescriptor` consumed by a Haneoka-owned
 * renderer adapter. Keeping this type structural avoids making the host bridge
 * depend on an optional character plugin at runtime.
 */
export interface HaneokaCubismModelDescriptor {
  readonly version: 2 | 3;
  readonly sourceKind: "manifest" | "moc";
  readonly modelSource: string;
}

export type HaneokaCubismRuntimeSource =
  | Readonly<{
      format: "cubism2";
      sourceKind: "manifest";
      modelUrl: string;
    }>
  | Readonly<{
      format: "cubism2";
      sourceKind: "moc";
      mocUrl: string;
    }>
  | Readonly<{
      format: "cubism3";
      sourceKind: "manifest";
      modelUrl: string;
    }>;

/**
 * Converts the public Cubism runtime-adapter descriptor into an unambiguous
 * Haneoka renderer source. In particular, opaque Cubism 2 keys cannot be
 * classified by suffix, so the descriptor's source kind determines whether
 * the host reads JSON or passes MOC bytes to Core.
 */
export const resolveHaneokaCubismRuntimeSource = (
  descriptor: Readonly<HaneokaCubismModelDescriptor>,
): HaneokaCubismRuntimeSource => {
  const modelSource = String(descriptor.modelSource || "").trim();
  if (!modelSource) {
    throw new TypeError("Haneoka Cubism descriptor has no model source");
  }
  if (descriptor.version === 2) {
    return descriptor.sourceKind === "moc"
      ? {
          format: "cubism2",
          sourceKind: "moc",
          mocUrl: modelSource,
        }
      : {
          format: "cubism2",
          sourceKind: "manifest",
          modelUrl: modelSource,
        };
  }
  if (descriptor.version === 3 && descriptor.sourceKind === "manifest") {
    return {
      format: "cubism3",
      sourceKind: "manifest",
      modelUrl: modelSource,
    };
  }
  throw new TypeError("Cubism 3 descriptors must identify a manifest source");
};
