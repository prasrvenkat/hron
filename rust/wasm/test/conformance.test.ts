// Behavioral conformance test — drives spec/tests.json through WASM.
//
// WASM methods accept/return ISO 8601 strings (not Temporal objects),
// so we compare strings directly.

import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, it, expect } from "vitest";
import { Schedule, fromCron } from "../pkg/hron_wasm.js";

const specPath = resolve(__dirname, "../../../spec/tests.json");
const spec = JSON.parse(readFileSync(specPath, "utf-8"));
const defaultNow: string = spec.now;

// ===========================================================================
// Parse conformance
// ===========================================================================

describe("parse roundtrip", () => {
  const parseSections = [
    "day_repeat",
    "interval_repeat",
    "week_repeat",
    "month_repeat",
    "ordinal_repeat",
    "single_date",
    "year_repeat",
    "except_clause",
    "until_clause",
    "starting_clause",
    "during_clause",
    "timezone_clause",
    "combined_clauses",
    "case_insensitivity",
  ];

  for (const section of parseSections) {
    describe(section, () => {
      const tests = spec.parse[section].tests;
      for (const tc of tests) {
        const name = tc.name ?? tc.input;
        it(name, () => {
          const schedule = Schedule.parse(tc.input);
          const display = schedule.toString();
          expect(display).toBe(tc.canonical);

          // Idempotency: parse(canonical).toString() === canonical
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
      expect(() => Schedule.parse(tc.input)).toThrow();
    });
  }
});

// ===========================================================================
// Eval conformance
// ===========================================================================

describe("eval", () => {
  const evalSections = [
    "day_repeat",
    "interval_repeat",
    "month_repeat",
    "ordinal_repeat",
    "week_repeat",
    "single_date",
    "year_repeat",
    "except",
    "until",
    "except_and_until",
    "n_occurrences",
    "multi_time",
    "during",
    "day_ranges",
    "leap_year",
    "dst_spring_forward",
    "dst_fall_back",
  ];

  for (const section of evalSections) {
    describe(section, () => {
      const tests = spec.eval[section].tests;
      for (const tc of tests) {
        const name = tc.name ?? tc.expression;
        it(name, () => {
          const schedule = Schedule.parse(tc.expression);
          const now = tc.now ?? defaultNow;

          // next (full timestamp)
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

          // next_date (date-only check)
          if ("next_date" in tc) {
            const result = schedule.nextFrom(now);
            expect(result).toBeDefined();
            // Extract date portion from ISO string (YYYY-MM-DD)
            const datePart = result!.slice(0, 10);
            expect(datePart).toBe(tc.next_date);
          }

          // next_n (list of timestamps)
          if ("next_n" in tc) {
            const expected: string[] = tc.next_n;
            const nCount = tc.next_n_count ?? expected.length;
            const results = schedule.nextNFrom(now, nCount) as string[];
            expect(results.length).toBe(expected.length);
            for (let j = 0; j < expected.length; j++) {
              expect(results[j]).toBe(expected[j]);
            }
          }

          // next_n_length (just check count)
          if ("next_n_length" in tc) {
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

// ===========================================================================
// Cron conformance
// ===========================================================================

describe("cron", () => {
  describe("to_cron", () => {
    const tests = spec.cron.to_cron.tests;
    for (const tc of tests) {
      const name = tc.name ?? tc.hron;
      it(name, () => {
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
        expect(() => fromCron(tc.cron)).toThrow();
      });
    }
  });

  describe("roundtrip", () => {
    const tests = spec.cron.roundtrip.tests;
    for (const tc of tests) {
      const name = tc.name ?? tc.hron;
      it(name, () => {
        const schedule = Schedule.parse(tc.hron);
        const cron1 = schedule.toCron();
        const back = fromCron(cron1);
        const cron2 = back.toCron();
        expect(cron1).toBe(cron2);
      });
    }
  });
});
