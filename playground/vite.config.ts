import { defineConfig } from "vite";
import wasm from "vite-plugin-wasm";
import topLevelAwait from "vite-plugin-top-level-await";
import { readFileSync } from "fs";
import { resolve } from "path";

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
    rollupOptions: {
      input: {
        main: resolve(__dirname, "index.html"),
        playground: resolve(__dirname, "playground/index.html"),
      },
    },
  },
});
