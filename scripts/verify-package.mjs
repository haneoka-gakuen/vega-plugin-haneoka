import {
  access,
  lstat,
  readFile,
  readdir,
  realpath,
  stat,
} from "node:fs/promises";
import { relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

import {
  restrictedHaneokaContentReason,
  restrictedHaneokaPathReason,
} from "./distribution-policy.mjs";

const root = fileURLToPath(new URL("..", import.meta.url));
const manifest = JSON.parse(
  await readFile(resolve(root, "package.json"), "utf8"),
);

const fail = (message) => {
  throw new Error(`Package verification failed: ${message}`);
};

if (manifest.name !== "@haneoka/vega-plugin-haneoka") {
  fail("unexpected package name");
}
if (manifest.license !== "MPL-2.0") fail("license must be MPL-2.0");
if (manifest.private === true) fail("package cannot be private");
if (manifest.sideEffects !== false) fail("sideEffects must be false");
if (manifest.publishConfig?.access !== "public") {
  fail("publishConfig.access must be public");
}
if (manifest.publishConfig?.provenance !== true) {
  fail("publishConfig.provenance must be enabled");
}
const expectedRepository =
  "git+https://github.com/haneoka-gakuen/vega-plugin-haneoka.git";
if (manifest.repository?.url !== expectedRepository) {
  fail(`repository.url must be ${expectedRepository}`);
}

const forbiddenRuntimeDependency =
  /(?:^three$|@esotericsoftware|cubism|live2d|motionsync|spine)/iu;
for (const section of [
  "dependencies",
  "devDependencies",
  "optionalDependencies",
  "peerDependencies",
]) {
  for (const name of Object.keys(manifest[section] ?? {})) {
    if (forbiddenRuntimeDependency.test(name)) {
      fail(`forbidden renderer SDK/runtime dependency ${name} in ${section}`);
    }
  }
}
if (Object.keys(manifest.dependencies ?? {}).length > 0) {
  fail("runtime dependencies must be supplied by Vega or host adapters");
}
if (Object.keys(manifest.optionalDependencies ?? {}).length > 0) {
  fail("optional runtime dependencies are not allowed");
}
if (
  (Array.isArray(manifest.bundledDependencies) &&
    manifest.bundledDependencies.length > 0) ||
  (Array.isArray(manifest.bundleDependencies) &&
    manifest.bundleDependencies.length > 0)
) {
  fail("bundled dependencies are not allowed");
}
const actualPeers = Object.keys(manifest.peerDependencies ?? {}).sort();
if (JSON.stringify(actualPeers) !== JSON.stringify(["@haneoka/vega"])) {
  fail("peer dependencies must be exactly @haneoka/vega");
}

const collectTargets = (value) => {
  if (typeof value === "string") {
    return value.startsWith("./dist/") ? [value] : [];
  }
  if (!value || typeof value !== "object") return [];
  return Object.values(value).flatMap(collectTargets);
};

const targets = new Set(
  [
    manifest.main,
    manifest.module,
    manifest.types,
    ...collectTargets(manifest.exports),
  ].filter(
    (value) => typeof value === "string" && value.startsWith("./dist/"),
  ),
);
if (targets.size === 0) fail("manifest has no dist export targets");
for (const target of targets) {
  try {
    await access(resolve(root, target));
  } catch {
    fail(`manifest references missing build output ${target}`);
  }
}

const insideRoot = (path) => {
  const pathFromRoot = relative(root, path);
  return (
    pathFromRoot === "" ||
    (!pathFromRoot.startsWith(`..${sep}`) &&
      pathFromRoot !== ".." &&
      !pathFromRoot.startsWith(sep))
  );
};

const ignoredRoots = new Set([".dependencies", ".git", "coverage", "dist", "node_modules"]);
const repositoryFiles = [];
const walkRepository = async (path, relativePath = "") => {
  if (!insideRoot(path)) fail(`path escapes repository: ${path}`);
  const info = await lstat(path);
  if (info.isSymbolicLink()) {
    fail(`symbolic links are not allowed: ${relativePath}`);
  }
  if (info.isDirectory()) {
    for (const entry of await readdir(path)) {
      if (!relativePath && ignoredRoots.has(entry)) continue;
      await walkRepository(
        resolve(path, entry),
        relativePath ? `${relativePath}/${entry}` : entry,
      );
    }
    return;
  }
  repositoryFiles.push(relativePath);
};

await walkRepository(root);
for (const path of repositoryFiles) {
  const pathReason = restrictedHaneokaPathReason(path);
  if (pathReason) fail(`${pathReason}: ${path}`);
  const contentReason = restrictedHaneokaContentReason(
    await readFile(resolve(root, path)),
  );
  if (contentReason) {
    fail(`${contentReason} found in repository file ${path}`);
  }
}

for (const required of ["LICENSE", "NOTICE.md", "README.md", "SECURITY.md"]) {
  if (!repositoryFiles.includes(required)) {
    fail(`code-only package is missing distribution notice ${required}`);
  }
}

const publishableFiles = [];
let publishableBytes = 0;
const walkPublishable = async (path, relativePath) => {
  if (!insideRoot(path)) fail(`publish path escapes repository: ${relativePath}`);
  const canonical = await realpath(path);
  if (!insideRoot(canonical)) {
    fail(`publish path resolves outside repository: ${relativePath}`);
  }
  const info = await lstat(path);
  if (info.isSymbolicLink()) {
    fail(`publish path is a symbolic link: ${relativePath}`);
  }
  if (info.isDirectory()) {
    for (const entry of await readdir(path)) {
      await walkPublishable(
        resolve(path, entry),
        relativePath ? `${relativePath}/${entry}` : entry,
      );
    }
    return;
  }

  publishableFiles.push(relativePath);
  publishableBytes += (await stat(path)).size;
  const pathReason = restrictedHaneokaPathReason(relativePath);
  if (pathReason) fail(`${pathReason} in publishable file ${relativePath}`);
  const contentReason = restrictedHaneokaContentReason(await readFile(path));
  if (contentReason) {
    fail(`${contentReason} found in publishable file ${relativePath}`);
  }
};

for (const entry of manifest.files ?? []) {
  if (
    typeof entry !== "string" ||
    !entry ||
    entry.startsWith("/") ||
    entry.includes("\\") ||
    entry.split("/").some((segment) => segment === "." || segment === "..")
  ) {
    fail(`invalid package files entry ${String(entry)}`);
  }
  const path = resolve(root, entry);
  if (!insideRoot(path)) fail(`package files entry escapes repository: ${entry}`);
  await walkPublishable(path, entry);
}
if (publishableBytes > 5 * 1024 * 1024) {
  fail(`publish payload is unexpectedly large (${publishableBytes} bytes)`);
}

const builtJavaScript = await readFile(resolve(root, "dist/index.js"), "utf8");
const importPattern =
  /(?:\bfrom\s*|\bimport\s*\(\s*|\bimport\s*)["']([^"']+)["']/gu;
const allowedImports = new Set(["@haneoka/vega", "@haneoka/vega/plugin"]);
const externalImports = new Set(
  [...builtJavaScript.matchAll(importPattern)]
    .map((match) => match[1])
    .filter((specifier) => specifier && !specifier.startsWith(".")),
);
const unexpectedImports = [...externalImports].filter(
  (specifier) => !allowedImports.has(specifier),
);
if (unexpectedImports.length > 0) {
  fail(`unexpected runtime imports: ${unexpectedImports.join(", ")}`);
}

console.log(
  `Verified ${manifest.name}: ${targets.size} exports, ${publishableFiles.length} files, ${publishableBytes} bytes.`,
);
