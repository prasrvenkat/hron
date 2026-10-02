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

describe("error constructors", () => {
  const span = { start: 0, end: 5 };
  const notStrings: unknown[] = [null, undefined, 42, {}];
  // biome-ignore lint/suspicious/noExplicitAny: passes what JavaScript can
  const loose = HronError as any;

  for (const bad of notStrings) {
    it(`throw a TypeError for a message of ${String(bad)}`, () => {
      expect(() => loose.lex(bad, span, "every")).toThrow(TypeError);
      expect(() => loose.parse(bad, span, "every")).toThrow(TypeError);
      expect(() => loose.eval(bad)).toThrow(TypeError);
      expect(() => loose.cron(bad)).toThrow(TypeError);
    });

    it(`throw a TypeError for an input of ${String(bad)}`, () => {
      expect(() => loose.lex("bad", span, bad)).toThrow(TypeError);
      expect(() => loose.parse("bad", span, bad)).toThrow(TypeError);
    });
  }

  for (const bad of [null, 42, {}]) {
    it(`throw a TypeError for a suggestion of ${String(bad)}`, () => {
      expect(() => loose.parse("bad", span, "every", bad)).toThrow(TypeError);
    });
  }

  for (const bad of [
    null,
    undefined,
    0,
    "0-5",
    {},
    { start: 0 },
    { start: "0", end: 5 },
  ]) {
    it(`throw a TypeError for a span of ${JSON.stringify(bad)}`, () => {
      for (const build of [loose.lex, loose.parse]) {
        const call = () => build.call(HronError, "bad", bad, "every");
        expect(call).toThrow(TypeError);
        expect(call).toThrow(
          "span must be an object whose start and end are numbers",
        );
      }
    });
  }

  it("keep a plain span object as the span", () => {
    expect(HronError.lex("bad", span, "every").span).toBe(span);
    expect(HronError.parse("bad", span, "every").span).toBe(span);
  });

  it("build a parse error with or without a suggestion", () => {
    expect(HronError.parse("bad", span, "every").suggestion).toBeUndefined();
    expect(HronError.parse("bad", span, "every", "every day").suggestion).toBe(
      "every day",
    );
  });
});
