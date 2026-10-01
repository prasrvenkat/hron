// WASM methods accept/return ISO 8601 strings (not Temporal objects),
// so we compare strings directly.

import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, it, expect } from "vitest";
import { Schedule, fromCron } from "../pkg/hron_wasm.js";

const specPath = resolve(__dirname, "../../../spec/tests.json");
const spec = JSON.parse(readFileSync(specPath, "utf-8"));
const defaultNow: string = spec.now;

// spec/README.md "Writing a runner": fail on anything this runner cannot check.
const knownTopLevel = [
  "$schema",
  "version",
  "description",
  "now",
  "_eval_assertion_types",
  "_behavioral_notes",
  "parse",
  "parse_errors",
  "eval",
  "cron",
  "invariants",
];
const knownCron = ["to_cron", "to_cron_errors", "from_cron", "from_cron_errors", "roundtrip"];
const sectionsOf = (category: object) =>
  Object.keys(category).filter((key) => key !== "description");

it("spec has no section this runner does not know", () => {
  const unknown = [
    ...Object.keys(spec).filter((key) => !knownTopLevel.includes(key)),
    ...sectionsOf(spec.cron)
      .filter((key) => !knownCron.includes(key))
      .map((key) => `cron.${key}`),
  ];
  expect(unknown).toEqual([]);
});

// Error sections pass no assertion fields: the section itself asserts the error.
function checkFields(tc: Record<string, unknown>, inputs: string[], assertions: string[]) {
  for (const key of Object.keys(tc)) {
    const known = ["name", "description", ...inputs, ...assertions].includes(key);
    expect(known, `field '${key}' is not known to this runner`).toBe(true);
  }
  if (assertions.length > 0) {
    const asserted = assertions.some((field) => field in tc);
    expect(asserted, `case has none of the assertion fields ${assertions}`).toBe(true);
  }
}

describe("parse roundtrip", () => {
  for (const section of sectionsOf(spec.parse)) {
    describe(section, () => {
      const tests = spec.parse[section].tests;
      for (const tc of tests) {
        const name = tc.name ?? tc.input;
        it(name, () => {
          checkFields(tc, ["input"], ["canonical"]);
          const schedule = Schedule.parse(tc.input);
          const display = schedule.toString();
          expect(display).toBe(tc.canonical);

          const s2 = Schedule.parse(tc.canonical);
          expect(s2.toString()).toBe(tc.canonical);
        });
      }
    });
  }
});

describe("parse errors", () => {
  const tests = spec.parse_errors.tests;
  for (const tc of tests) {
    const name = tc.name ?? tc.input;
    it(name, () => {
      checkFields(tc, ["input", "error_contains"], []);
      expect(Schedule.validate(tc.input)).toBe(false);
      expect(() => Schedule.parse(tc.input)).toThrow(tc.error_contains ?? "");
    });
  }
});

describe("eval", () => {
  const skipSections = new Set([
    "description",
    "matches",
    "occurrences",
    "between",
    "previous_from",
  ]);
  const evalSections = Object.keys(spec.eval).filter(
    (s) => !skipSections.has(s),
  );

  for (const section of evalSections) {
    describe(section, () => {
      const tests = spec.eval[section].tests;
      for (const tc of tests) {
        const name = tc.name ?? tc.expression;
        it(name, () => {
          checkFields(
            tc,
            ["expression", "now", "next_n_count"],
            ["next", "next_date", "next_n", "next_n_length"],
          );
          const schedule = Schedule.parse(tc.expression);
          const now = tc.now ?? defaultNow;

          // Note: WASM returns undefined (not null) for Rust Option::None
          if ("next" in tc) {
            const result = schedule.nextFrom(now);
            if (tc.next === null) {
              expect(result).toBeUndefined();
            } else {
              expect(result).toBeDefined();
              expect(result).toBe(tc.next);
            }
          }

          if ("next_date" in tc) {
            const result = schedule.nextFrom(now);
            expect(result).toBeDefined();
            const datePart = result!.slice(0, 10);
            expect(datePart).toBe(tc.next_date);
          }

          if ("next_n" in tc) {
            const expected: string[] = tc.next_n;
            const asserts = expected.length > 0 || "next_n_count" in tc;
            expect(asserts, "an empty next_n asserts nothing without next_n_count").toBe(true);
            const nCount = tc.next_n_count ?? expected.length;
            const results = schedule.nextNFrom(now, nCount) as string[];
            expect(results.length).toBe(expected.length);
            for (let j = 0; j < expected.length; j++) {
              expect(results[j]).toBe(expected[j]);
            }
          }

          if ("next_n_length" in tc) {
            expect("next_n_count" in tc, "next_n_length needs next_n_count").toBe(true);
            const expectedLen: number = tc.next_n_length;
            const nCount: number = tc.next_n_count;
            const results = schedule.nextNFrom(now, nCount) as string[];
            expect(results.length).toBe(expectedLen);
          }
        });
      }
    });
  }
});

describe("eval matches", () => {
  const tests = spec.eval.matches.tests;
  for (const tc of tests) {
    const name = tc.name ?? tc.expression;
    it(name, () => {
      checkFields(tc, ["expression", "datetime"], ["expected"]);
      const schedule = Schedule.parse(tc.expression);
      expect(schedule.matches(tc.datetime)).toBe(tc.expected);
    });
  }
});

describe("eval previous_from", () => {
  const tests = spec.eval.previous_from.tests;
  for (const tc of tests) {
    const name = tc.name ?? tc.expression;
    it(name, () => {
      checkFields(tc, ["expression", "now"], ["expected"]);
      const schedule = Schedule.parse(tc.expression);
      const result = schedule.previousFrom(tc.now);
      if (tc.expected === null) {
        expect(result).toBeUndefined();
      } else {
        expect(result).toBeDefined();
        expect(result).toBe(tc.expected);
      }
    });
  }
});

describe("eval occurrences", () => {
  const tests = spec.eval.occurrences.tests;
  for (const tc of tests) {
    const name = tc.name ?? tc.expression;
    it(name, () => {
      checkFields(tc, ["expression", "from", "take"], ["expected"]);
      const schedule = Schedule.parse(tc.expression);
      expect(schedule.occurrences(tc.from, tc.take)).toEqual(tc.expected);
    });
  }
});

describe("eval between", () => {
  const tests = spec.eval.between.tests;
  for (const tc of tests) {
    const name = tc.name ?? tc.expression;
    it(name, () => {
      checkFields(tc, ["expression", "from", "to"], ["expected", "expected_count"]);
      const schedule = Schedule.parse(tc.expression);
      const results = schedule.between(tc.from, tc.to) as string[];
      if ("expected" in tc) {
        expect(results).toEqual(tc.expected);
      } else {
        expect(results.length).toBe(tc.expected_count);
      }
    });
  }
});

describe("cron", () => {
  describe("to_cron", () => {
    const tests = spec.cron.to_cron.tests;
    for (const tc of tests) {
      const name = tc.name ?? tc.hron;
      it(name, () => {
        checkFields(tc, ["hron"], ["cron"]);
        const schedule = Schedule.parse(tc.hron);
        expect(schedule.toCron()).toBe(tc.cron);
      });
    }
  });

  describe("to_cron errors", () => {
    const tests = spec.cron.to_cron_errors.tests;
    for (const tc of tests) {
      const name = tc.name ?? tc.hron;
      it(name, () => {
        checkFields(tc, ["hron"], []);
        const schedule = Schedule.parse(tc.hron);
        expect(() => schedule.toCron()).toThrow();
      });
    }
  });

  describe("from_cron", () => {
    const tests = spec.cron.from_cron.tests;
    for (const tc of tests) {
      const name = tc.name ?? tc.cron;
      it(name, () => {
        checkFields(tc, ["cron"], ["hron"]);
        const schedule = fromCron(tc.cron);
        expect(schedule.toString()).toBe(tc.hron);
      });
    }
  });

  describe("from_cron errors", () => {
    const tests = spec.cron.from_cron_errors.tests;
    for (const tc of tests) {
      const name = tc.name ?? tc.cron;
      it(name, () => {
        checkFields(tc, ["cron"], []);
        expect(() => fromCron(tc.cron)).toThrow();
      });
    }
  });

  describe("roundtrip", () => {
    const tests = spec.cron.roundtrip.tests;
    for (const tc of tests) {
      const name = tc.name ?? tc.hron;
      it(name, () => {
        checkFields(tc, ["hron"], []);
        const schedule = Schedule.parse(tc.hron);
        const cron1 = schedule.toCron();
        const back = fromCron(cron1);
        const cron2 = back.toCron();
        expect(cron1).toBe(cron2);
      });
    }
  });
});

// Rules from spec/README.md "Invariants"; timestamps are equal when they are the same instant.
describe("invariants", () => {
  const count: number = spec.invariants.count;

  function instant(t: string): number {
    const ms = Date.parse(t.replace(/\[.*\]$/, ""));
    if (Number.isNaN(ms)) throw new Error(`cannot compare timestamp ${t}`);
    return ms;
  }
  const instants = (list: string[]) => list.map(instant);

  type Rule = (schedule: Schedule, now: string, nextN: string[]) => void;
  const rules: Record<string, Rule> = {
    next_matches(schedule, now) {
      const t = schedule.nextFrom(now);
      if (t !== undefined) expect(schedule.matches(t), `matches(${t})`).toBe(true);
    },
    next_after_now(schedule, now) {
      const t = schedule.nextFrom(now);
      if (t !== undefined) expect(instant(t), `nextFrom(now) is ${t}`).toBeGreaterThan(instant(now));
    },
    next_n_chain(schedule, now, nextN) {
      const ts = instants(nextN);
      for (let i = 1; i < ts.length; i++) {
        expect(ts[i], `nextN[${i}] after nextN[${i - 1}]`).toBeGreaterThan(ts[i - 1]);
      }
      if (nextN.length === 0) expect(schedule.nextFrom(now)).toBeUndefined();
      let cursor = now;
      for (const t of nextN) {
        const next = schedule.nextFrom(cursor);
        expect(next, `nextFrom(${cursor})`).toBeDefined();
        expect(instant(next!), `nextFrom(${cursor})`).toBe(instant(t));
        cursor = t;
      }
    },
    occurrences_prefix(schedule, now, nextN) {
      expect(instants(schedule.occurrences(now, count))).toEqual(instants(nextN));
    },
    between_window(schedule, now, nextN) {
      if (nextN.length === 0) return;
      const last = nextN[nextN.length - 1];
      expect(instants(schedule.between(now, last))).toEqual(instants(nextN));
    },
    prev_inverse(schedule, _now, nextN) {
      for (let i = 1; i < nextN.length; i++) {
        const prev = schedule.previousFrom(nextN[i]);
        expect(prev, `previousFrom(${nextN[i]})`).toBeDefined();
        expect(instant(prev!), `previousFrom(${nextN[i]})`).toBe(instant(nextN[i - 1]));
      }
    },
    prev_before_now(schedule, now) {
      const prev = schedule.previousFrom(now);
      if (prev === undefined) return;
      expect(instant(prev), `previousFrom(now) is ${prev}`).toBeLessThan(instant(now));
      expect(schedule.matches(prev), `matches(${prev})`).toBe(true);
      const next = schedule.nextFrom(prev);
      if (next !== undefined) {
        expect(instant(next), `nextFrom(${prev})`).toBeGreaterThanOrEqual(instant(now));
      }
    },
    display_roundtrip(schedule) {
      const display = schedule.toString();
      expect(Schedule.parse(display).toString()).toBe(display);
    },
  };

  for (const tc of spec.invariants.tests) {
    describe(`${tc.name}: ${tc.expression} at ${tc.now}`, () => {
      for (const rule of Object.keys(spec.invariants.rules)) {
        it(rule, () => {
          checkFields(tc, ["expression", "now"], []);
          const check = rules[rule];
          if (check === undefined) throw new Error(`rule '${rule}' is not implemented by this runner`);
          const schedule = Schedule.parse(tc.expression);
          check(schedule, tc.now, schedule.nextNFrom(tc.now, count) as string[]);
        });
      }
    });
  }
});
