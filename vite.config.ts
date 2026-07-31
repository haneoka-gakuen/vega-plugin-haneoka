import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { defineConfig } from "vite";

const root = fileURLToPath(new URL(".", import.meta.url));

export default defineConfig({
  build: {
    lib: { entry: resolve(root, "src/index.ts"), fileName: "index", formats: ["es"] },
    rollupOptions: { external: ["@haneoka/vega", "@haneoka/vega/plugin"] },
    sourcemap: true,
    target: "es2022",
  },
});
