import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { defineConfig } from "vite";

const root = fileURLToPath(new URL(".", import.meta.url));

export default defineConfig({
  build: {
    lib: {
      entry: { index: resolve(root, "src/index.ts"), transcript: resolve(root, "src/transcript.ts") },
      fileName: (_format, name) => `${name}.js`,
      formats: ["es"],
    },
    rollupOptions: { external: ["@haneoka/vega", "@haneoka/vega/plugin", "@haneoka/vega-protocol/opcodes"] },
    sourcemap: true,
    target: "es2022",
  },
});
