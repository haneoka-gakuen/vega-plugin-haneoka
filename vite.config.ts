import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { defineConfig } from "vite";

const root = fileURLToPath(new URL(".", import.meta.url));

export default defineConfig({
  build: {
    lib: {
      entry: {
        index: resolve(root, "src/index.ts"),
        transcript: resolve(root, "src/transcript.ts"),
        "scene-profile": resolve(root, "src/scene-profile.ts"),
        "chat-profile": resolve(root, "src/chat-profile.ts"),
      },
      fileName: (_format, name) => `${name}.js`,
      formats: ["es"],
    },
    rollupOptions: {
      external: [
        "@haneoka/vega",
        "@haneoka/vega/plugin",
        "@haneoka/vega/renderer-kit",
        "@haneoka/vega-protocol/opcodes",
      ],
    },
    sourcemap: true,
    target: "es2022",
  },
});
