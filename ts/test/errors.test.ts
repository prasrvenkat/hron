import { describe, expect, it } from "vitest";
import { HronError, Schedule } from "../src/index.js";

function parseError(input: string): HronError {
  try {
    Schedule.parse(input);
  } catch (error) {
    if (error instanceof HronError) return error;
    throw error;
  }
  throw new Error(`'${input}' parsed`);
}

// JSON cannot carry a lone surrogate portably, so spec/tests.json leaves these
// to each implementation (spec/README.md, "Lex errors").
describe("spans count code points", () => {
  it("reports a lone surrogate by its own value, one code point wide", () => {
    const error = parseError("every day at 09:00 \uD800");
    expect(error.kind).toBe("lex");
    expect(error.message).toBe("unexpected character U+D800");
    expect(error.span).toEqual({ start: 19, end: 20 });
  });

  it("counts a lone low surrogate after an astral character as its own code point", () => {
    const error = parseError("every day at 09:00 in \u{1F600} \uDC00");
    expect(error.message).toBe("unexpected character U+DC00");
    expect(error.span).toEqual({ start: 24, end: 25 });
  });

  it("reports an astral character as one code point", () => {
    const error = parseError("every day at 09:00 \u{1F600}");
    expect(error.message).toBe("unexpected character U+1F600");
    expect(error.span).toEqual({ start: 19, end: 20 });
    expect(error.displayRich()).toBe(
      "error: unexpected character U+1F600\n  every day at 09:00 \u{1F600}\n                     ^",
    );
  });

  it("counts an astral character before the span as one code point", () => {
    const error = parseError("every day at 09:00 in \u{1F600}");
    expect(error.message).toBe(
      "timezone must be UTC or an Area/Location name such as America/New_York, got \u{1F600}",
    );
    expect(error.span).toEqual({ start: 22, end: 23 });
  });
});

describe("displayRich", () => {
  it("renders an eval or cron error as its message alone", () => {
    expect(HronError.eval("no zone").displayRich()).toBe("error: no zone");
    expect(HronError.cron("bad cron").displayRich()).toBe("error: bad cron");
  });
});
