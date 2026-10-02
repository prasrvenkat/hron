import { describe, expect, it, vi } from "vitest";
import { Schedule } from "../src/index.js";

vi.mock("../src/parser.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../src/parser.js")>();
  return {
    ...actual,
    parse: (input: string) => {
      if (input === "crash") throw new RangeError("not a hron error");
      return actual.parse(input);
    },
  };
});

describe("validate", () => {
  it("passes on an error that is not a HronError", () => {
    expect(() => Schedule.validate("crash")).toThrow(
      new RangeError("not a hron error"),
    );
  });

  it("is false for a HronError", () => {
    expect(Schedule.validate("every")).toBe(false);
  });
});
