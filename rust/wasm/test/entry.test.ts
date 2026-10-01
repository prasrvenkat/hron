import { describe, it, expect } from "vitest";
import * as bindings from "../pkg/hron_wasm_bg.js";
import * as entry from "../pkg/hron_wasm.js";

// The published entry is hron_wasm_entry.js, which re-exports the bindings by name,
// so a binding missing from its export list is missing from the package.
describe("package entry", () => {
  it("exports every public binding", () => {
    const publicBindings = Object.keys(bindings).filter((name) => !name.startsWith("__"));
    expect(Object.keys(entry).sort()).toEqual(publicBindings.sort());
  });

  it("explains a cron expression", () => {
    expect(entry.explainCron("0 9 * * 1-5")).toBe("every weekday at 09:00");
  });
});
