import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { Temporal } from "@js-temporal/polyfill";
import { describe, expect, it } from "vitest";
import { HronError, Schedule } from "../src/index.js";

const specPath = resolve(__dirname, "../../spec/tests.json");
const spec = JSON.parse(readFileSync(specPath, "utf-8"));
const defaultNow = parseZoned(spec.now);

function parseZoned(s: string): Temporal.ZonedDateTime {
  return Temporal.ZonedDateTime.from(s);
}

// A case this runner cannot check must fail rather than pass silently
// (spec/README.md, "Writing a runner").
const topLevelKeys = [
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
const nextSections = [
  "day_repeat",
  "interval_repeat",
  "month_repeat",
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
  "timezone_default",
  "contradictory",
  "edge_cases",
];
const cronSections = [
  "to_cron",
  "to_cron_errors",
  "from_cron",
  "from_cron_errors",
  "roundtrip",
];

// biome-ignore lint/suspicious/noExplicitAny: cases are untyped JSON
type SpecCase = Record<string, any>;

function sectionsOf(group: Record<string, unknown>): string[] {
  return Object.keys(group).filter((key) => key !== "description");
}

const labels = ["name", "description"];

function checkFields(tc: SpecCase, fields: string[]): void {
  const unchecked = Object.keys(tc).filter(
    (key) => !fields.includes(key) && !labels.includes(key),
  );
  expect(unchecked, "fields this runner does not check").toEqual([]);
}

// A missing or non-integer count would make an iterator loop run forever.
function integer(value: unknown, label: string): number {
  expect(Number.isInteger(value), `${label} is an integer`).toBe(true);
  return value as number;
}

function hronError(run: () => unknown): HronError {
  let error: unknown = null;
  try {
    run();
  } catch (e) {
    error = e;
  }
  expect(error, "a HronError").toBeInstanceOf(HronError);
  return error as HronError;
}

function expectCronError(run: () => unknown, message: unknown): void {
  expect(typeof message, "error is a string").toBe("string");
  const error = hronError(run);
  expect(error.kind, "error kind").toBe("cron");
  expect(error.message, "error message").toBe(message);
}

function show(t: Temporal.ZonedDateTime | null): string | null {
  return t === null ? null : t.toString();
}

function checkNext(tc: SpecCase): void {
  checkFields(tc, [
    "expression",
    "now",
    "next",
    "next_date",
    "next_n",
    "next_n_count",
    "next_n_length",
  ]);
  const assertions = ["next", "next_date", "next_n", "next_n_length"];
  expect(
    assertions.filter((field) => field in tc),
    "an assertion field",
  ).not.toEqual([]);
  const schedule = Schedule.parse(tc.expression);
  const now = "now" in tc ? parseZoned(tc.now) : defaultNow;
  if ("next" in tc) {
    expect(show(schedule.nextFrom(now)), "next").toBe(tc.next);
  }
  if ("next_date" in tc) {
    const date = schedule.nextFrom(now)?.toPlainDate().toString() ?? null;
    expect(date, "next_date").toBe(tc.next_date);
  }
  if ("next_n" in tc) {
    const n = integer(tc.next_n_count ?? tc.next_n.length, "next_n_count");
    expect(schedule.nextNFrom(now, n).map(show), "next_n").toEqual(tc.next_n);
  }
  if ("next_n_length" in tc) {
    const n = integer(tc.next_n_count, "next_n_count");
    const results = schedule.nextNFrom(now, n);
    expect(results.length, "next_n_length").toBe(tc.next_n_length);
  }
}

function checkMatches(tc: SpecCase): void {
  checkFields(tc, ["expression", "datetime", "expected"]);
  expect(typeof tc.expected, "expected is a boolean").toBe("boolean");
  const schedule = Schedule.parse(tc.expression);
  expect(schedule.matches(parseZoned(tc.datetime))).toBe(tc.expected);
}

function checkPreviousFrom(tc: SpecCase): void {
  checkFields(tc, ["expression", "now", "expected"]);
  expect("expected" in tc, "an expected field").toBe(true);
  const schedule = Schedule.parse(tc.expression);
  expect(show(schedule.previousFrom(parseZoned(tc.now)))).toBe(tc.expected);
}

function checkOccurrences(tc: SpecCase): void {
  checkFields(tc, ["expression", "from", "take", "expected"]);
  expect(Array.isArray(tc.expected), "expected is a list").toBe(true);
  const take = integer(tc.take, "take");
  const schedule = Schedule.parse(tc.expression);
  const taken: (string | null)[] = [];
  for (const t of schedule.occurrences(parseZoned(tc.from))) {
    if (taken.length >= take) break;
    taken.push(show(t));
  }
  expect(taken).toEqual(tc.expected);
}

function checkBetween(tc: SpecCase): void {
  checkFields(tc, ["expression", "from", "to", "expected", "expected_count"]);
  expect(
    "expected" in tc || "expected_count" in tc,
    "an expected or expected_count field",
  ).toBe(true);
  const schedule = Schedule.parse(tc.expression);
  const results = [
    ...schedule.between(parseZoned(tc.from), parseZoned(tc.to)),
  ].map(show);
  if ("expected" in tc) expect(results).toEqual(tc.expected);
  if ("expected_count" in tc) expect(results.length).toBe(tc.expected_count);
}

const evalChecks: Record<string, (tc: SpecCase) => void> = {
  matches: checkMatches,
  previous_from: checkPreviousFrom,
  occurrences: checkOccurrences,
  between: checkBetween,
  ...Object.fromEntries(nextSections.map((section) => [section, checkNext])),
};

describe("spec layout", () => {
  it("has only top-level sections this runner knows", () => {
    const unknown = Object.keys(spec).filter((k) => !topLevelKeys.includes(k));
    expect(unknown).toEqual([]);
  });

  it("has only eval sections this runner knows", () => {
    const unknown = sectionsOf(spec.eval).filter((s) => !(s in evalChecks));
    expect(unknown).toEqual([]);
  });

  it("has only cron sections this runner knows", () => {
    const unknown = sectionsOf(spec.cron).filter(
      (s) => !cronSections.includes(s),
    );
    expect(unknown).toEqual([]);
  });
});

describe("parse roundtrip", () => {
  for (const section of sectionsOf(spec.parse)) {
    describe(section, () => {
      for (const tc of spec.parse[section].tests) {
        it(tc.name ?? tc.input, () => {
          checkFields(tc, ["input", "canonical"]);
          const schedule = Schedule.parse(tc.input);
          expect(schedule.toString()).toBe(tc.canonical);
          expect(Schedule.parse(tc.canonical).toString()).toBe(tc.canonical);
          expect(
            schedule.equals(Schedule.parse(schedule.toString())),
            "equals the parse of its toString",
          ).toBe(true);
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
      checkFields(tc, ["input", "error", "display"]);
      const errorFields = ["kind", "message", "span", "suggestion"];
      expect(
        Object.keys(tc.error).filter((key) => !errorFields.includes(key)),
        "error fields this runner does not check",
      ).toEqual([]);
      const error = hronError(() => Schedule.parse(tc.input));
      expect(Schedule.validate(tc.input), "validate").toBe(false);
      expect(error.kind, "kind").toBe(tc.error.kind);
      expect(error.message, "message").toBe(tc.error.message);
      expect(error.span && [error.span.start, error.span.end], "span").toEqual(
        tc.error.span,
      );
      expect(error.suggestion, "suggestion").toBe(tc.error.suggestion);
      if ("display" in tc) {
        expect(error.displayRich(), "displayRich").toBe(tc.display);
      }
    });
  }
});

describe("eval", () => {
  for (const section of sectionsOf(spec.eval)) {
    const check = evalChecks[section];
    if (check === undefined) continue;
    describe(section, () => {
      for (const tc of spec.eval[section].tests) {
        it(tc.name ?? tc.expression, () => check(tc));
      }
    });
  }
});

type Zoned = Temporal.ZonedDateTime;
type InvariantRule = (schedule: Schedule, now: Zoned, count: number) => void;

function instant(t: Zoned | null): string | null {
  return t === null ? null : t.toInstant().toString();
}

function isBefore(a: Zoned, b: Zoned): boolean {
  return Temporal.ZonedDateTime.compare(a, b) < 0;
}

function nextMatches(schedule: Schedule, now: Zoned): void {
  const t = schedule.nextFrom(now);
  if (t !== null) {
    expect(schedule.matches(t), `matches(${t})`).toBe(true);
  }
}

function nextAfterNow(schedule: Schedule, now: Zoned): void {
  const t = schedule.nextFrom(now);
  if (t !== null) {
    expect(isBefore(now, t), `nextFrom = ${t} is after now`).toBe(true);
  }
}

function nextNChain(schedule: Schedule, now: Zoned, count: number): void {
  const list = schedule.nextNFrom(now, count);
  const first = schedule.nextFrom(now);
  if (first === null) {
    expect(list.map(instant), "nextNFrom when nextFrom is null").toEqual([]);
    return;
  }
  expect(instant(list[0] ?? null), "first element").toBe(instant(first));
  for (let i = 1; i < list.length; i++) {
    expect(isBefore(list[i - 1], list[i]), `${list[i]} increases`).toBe(true);
    expect(instant(schedule.nextFrom(list[i - 1])), `element ${i}`).toBe(
      instant(list[i]),
    );
  }
}

function occurrencesPrefix(
  schedule: Schedule,
  now: Zoned,
  count: number,
): void {
  const taken: Zoned[] = [];
  for (const t of schedule.occurrences(now)) {
    if (taken.length >= count) break;
    taken.push(t);
  }
  expect(taken.map(instant)).toEqual(
    schedule.nextNFrom(now, count).map(instant),
  );
}

function betweenWindow(schedule: Schedule, now: Zoned, count: number): void {
  const list = schedule.nextNFrom(now, count);
  if (list.length === 0) return;
  const window = [...schedule.between(now, list[list.length - 1])];
  expect(window.map(instant)).toEqual(list.map(instant));
}

function prevInverse(schedule: Schedule, now: Zoned, count: number): void {
  const list = schedule.nextNFrom(now, count);
  for (let i = 1; i < list.length; i++) {
    expect(
      instant(schedule.previousFrom(list[i])),
      `previousFrom(${list[i]})`,
    ).toBe(instant(list[i - 1]));
  }
}

function prevBeforeNow(schedule: Schedule, now: Zoned): void {
  const p = schedule.previousFrom(now);
  if (p === null) return;
  expect(isBefore(p, now), `previousFrom = ${p} is before now`).toBe(true);
  expect(schedule.matches(p), `matches(${p})`).toBe(true);
  const next = schedule.nextFrom(p);
  expect(
    next === null || !isBefore(next, now),
    `nextFrom(${p}) = ${next}`,
  ).toBe(true);
}

function displayRoundtrip(schedule: Schedule): void {
  const display = schedule.toString();
  expect(Schedule.parse(display).toString()).toBe(display);
}

const invariantRules: Record<string, InvariantRule> = {
  next_matches: nextMatches,
  next_after_now: nextAfterNow,
  next_n_chain: nextNChain,
  occurrences_prefix: occurrencesPrefix,
  between_window: betweenWindow,
  prev_inverse: prevInverse,
  prev_before_now: prevBeforeNow,
  display_roundtrip: displayRoundtrip,
};

describe("invariants", () => {
  it("covers every rule in the spec", () => {
    expect(Object.keys(invariantRules).sort()).toEqual(
      Object.keys(spec.invariants.rules).sort(),
    );
  });

  for (const tc of spec.invariants.tests) {
    describe(tc.name, () => {
      it("has only fields this runner checks", () => {
        checkFields(tc, ["expression", "now"]);
      });
      for (const [rule, check] of Object.entries(invariantRules)) {
        it(rule, () => {
          const schedule = Schedule.parse(tc.expression);
          const count = integer(spec.invariants.count, "invariants.count");
          check(schedule, parseZoned(tc.now), count);
        });
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
        checkFields(tc, ["hron", "cron"]);
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
        checkFields(tc, ["hron", "error"]);
        const schedule = Schedule.parse(tc.hron);
        expectCronError(() => schedule.toCron(), tc.error);
      });
    }
  });

  describe("from_cron", () => {
    const tests = spec.cron.from_cron.tests;
    for (const tc of tests) {
      const name = tc.name ?? tc.cron;
      it(name, () => {
        checkFields(tc, ["cron", "hron"]);
        const schedule = Schedule.fromCron(tc.cron);
        expect(schedule.toString()).toBe(tc.hron);
        expect(
          schedule.equals(Schedule.parse(schedule.toString())),
          "equals the parse of its toString",
        ).toBe(true);
      });
    }
  });

  describe("from_cron errors", () => {
    const tests = spec.cron.from_cron_errors.tests;
    for (const tc of tests) {
      const name = tc.name ?? tc.cron;
      it(name, () => {
        checkFields(tc, ["cron", "error"]);
        expectCronError(() => Schedule.fromCron(tc.cron), tc.error);
      });
    }
  });

  describe("roundtrip", () => {
    const tests = spec.cron.roundtrip.tests;
    for (const tc of tests) {
      const name = tc.name ?? tc.hron;
      it(name, () => {
        checkFields(tc, ["hron"]);
        const schedule = Schedule.parse(tc.hron);
        const cron1 = schedule.toCron();
        const back = Schedule.fromCron(cron1);
        const cron2 = back.toCron();
        expect(cron1).toBe(cron2);
      });
    }
  });
});
