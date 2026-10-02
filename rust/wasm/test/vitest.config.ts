import { fileURLToPath } from "node:url";
import { defineConfig } from "vitest/config";
import wasm from "vite-plugin-wasm";

export default defineConfig({
  plugins: [wasm()],
  resolve: {
    // getters.test.ts imports hron-ts from its source, whose own dependencies
    // are not installed in this job.
    alias: {
      "@js-temporal/polyfill": fileURLToPath(
        new URL("./node_modules/@js-temporal/polyfill", import.meta.url),
      ),
    },
  },
  test: {
    include: ["*.test.ts"],
  },
});
