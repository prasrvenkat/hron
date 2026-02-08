// Conformance test runner — drives all tests from spec/tests.json.

import { describe, it, expect } from "vitest";
import { readFileSync } from "fs";
import { resolve } from "path";
import { Temporal } from "@js-temporal/polyfill";
import { Schedule } from "../src/index.js";

const specPath = resolve(__dirname, "../../spec/tests.json");
const spec = JSON.parse(readFileSync(specPath, "utf-8"));
const defaultNow = parseZoned(spec.now);

function parseZoned(s: string): Temporal.ZonedDateTime {
  return Temporal.ZonedDateTime.from(s);
}

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
          const now = tc.now ? parseZoned(tc.now) : defaultNow;

          // next (full timestamp)
          if ("next" in tc) {
            const result = schedule.nextFrom(now);
            if (tc.next === null) {
              expect(result).toBeNull();
            } else {
              expect(result).not.toBeNull();
              expect(result!.toString()).toBe(tc.next);
            }
          }

          // next_date (date-only check)
          if ("next_date" in tc) {
            const result = schedule.nextFrom(now);
            expect(result).not.toBeNull();
            expect(result!.toPlainDate().toString()).toBe(tc.next_date);
          }

          // next_n (list of timestamps)
          if ("next_n" in tc) {
            const expected: string[] = tc.next_n;
            const nCount = tc.next_n_count ?? expected.length;
            const results = schedule.nextNFrom(now, nCount);
            expect(results.length).toBe(expected.length);
            for (let j = 0; j < expected.length; j++) {
              expect(results[j].toString()).toBe(expected[j]);
            }
          }

          // next_n_length (just check count)
          if ("next_n_length" in tc) {
            const expectedLen: number = tc.next_n_length;
            const nCount: number = tc.next_n_count;
            const results = schedule.nextNFrom(now, nCount);
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
      const dt = parseZoned(tc.datetime);
      expect(schedule.matches(dt)).toBe(tc.expected);
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
        const schedule = Schedule.fromCron(tc.cron);
        expect(schedule.toString()).toBe(tc.hron);
      });
    }
  });

  describe("from_cron errors", () => {
    const tests = spec.cron.from_cron_errors.tests;
    for (const tc of tests) {
      const name = tc.name ?? tc.cron;
      it(name, () => {
        expect(() => Schedule.fromCron(tc.cron)).toThrow();
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
        const back = Schedule.fromCron(cron1);
        const cron2 = back.toCron();
        expect(cron1).toBe(cron2);
      });
    }
  });
});
