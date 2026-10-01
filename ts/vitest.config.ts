import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: ["test/**/*.test.ts"],
    // Native Temporal objects are tested beside the polyfill's; Node offers
    // Temporal behind this flag before it ships it unflagged.
    execArgv: "Temporal" in globalThis ? [] : ["--harmony-temporal"],
  },
});
