import { defineConfig } from "vite";
import wasm from "vite-plugin-wasm";
import { readFileSync } from "fs";
import { resolve } from "path";

const hronVersion = JSON.parse(
  readFileSync("node_modules/hron-wasm/package.json", "utf-8"),
).version;

export default defineConfig({
  plugins: [wasm()],
  define: {
    __HRON_VERSION__: JSON.stringify(hronVersion),
  },
  build: {
    target: "es2022",
    rolldownOptions: {
      input: {
        main: resolve(import.meta.dirname, "index.html"),
        playground: resolve(import.meta.dirname, "playground/index.html"),
      },
    },
  },
});
