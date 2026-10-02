import { describe, it, expect } from "vitest";
import { Schedule, explainCron, fromCron } from "../pkg/hron_wasm.js";

function thrown(action: () => unknown): any {
  try {
    action();
  } catch (error) {
    return error;
  }
  throw new Error("expected a throw");
}

describe("errors", () => {
  it("counts the span in code points, which the README converts to string indices", () => {
    const input = "every day at 09:00 in 😀 #";
    const error = thrown(() => Schedule.parse(input));
    expect(error.span).toEqual({ start: 24, end: 25 });
    const start = [...input].slice(0, error.span.start).join("").length;
    const end = [...input].slice(0, error.span.end).join("").length;
    expect(input.slice(start, end)).toBe("#");
    expect(error.input).toBe(input);
  });

  // wasm-bindgen encodes strings as UTF-8, which replaces a lone surrogate with U+FFFD.
  it("reports a lone surrogate as U+FFFD, one code point wide", () => {
    const error = thrown(() => Schedule.parse("every day at 09:00 \uD800 x"));
    expect(error.kind).toBe("lex");
    expect(error.message).toBe("unexpected character U+FFFD");
    expect(error.span).toEqual({ start: 19, end: 20 });
    expect(error.input).toBe("every day at 09:00 \uFFFD x");
  });

  it("gives a lex error no suggestion", () => {
    const error = thrown(() => Schedule.parse("every day at 09:00 #"));
    expect("suggestion" in error).toBe(true);
    expect(error.suggestion).toBeUndefined();
  });

  // spec/README.md, "Timestamps and counts": a usage error, not a hron error.
  it.each([42, null, undefined, {}, new String("every day at 09:00"), ["0 9 * * *"]])(
    "throws a TypeError with no kind for the input %s",
    (value: any) => {
      for (const action of [
        () => Schedule.parse(value),
        () => Schedule.validate(value),
        () => fromCron(value),
        () => explainCron(value),
      ]) {
        const error = thrown(action);
        expect(error).toBeInstanceOf(TypeError);
        expect("kind" in error).toBe(false);
      }
    },
  );

  it("renders a cron error as its message alone, with no span", () => {
    const error = thrown(() => fromCron("0 9 15 * 1"));
    expect(error.kind).toBe("cron");
    expect(error.displayRich()).toBe(`error: ${error.message}`);
    expect(error.span).toBeUndefined();
  });
});
