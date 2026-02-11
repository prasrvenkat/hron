import { defineConfig } from "vite";
import wasm from "vite-plugin-wasm";
import topLevelAwait from "vite-plugin-top-level-await";
import { readFileSync } from "fs";

const hronVersion = JSON.parse(
  readFileSync("node_modules/hron-wasm/package.json", "utf-8"),
).version;

export default defineConfig({
  plugins: [wasm(), topLevelAwait()],
  define: {
    __HRON_VERSION__: JSON.stringify(hronVersion),
  },
  build: {
    target: "es2022",
  },
});
