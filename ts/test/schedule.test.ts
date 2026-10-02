import { Temporal } from "@js-temporal/polyfill";
import { describe, expect, it } from "vitest";
import { Schedule } from "../src/index.js";

// spec/README.md, "Schedules built in code".

const now = Temporal.ZonedDateTime.from("2026-02-06T12:00:00+00:00[UTC]");

const everyKind = [
  "every 30 min from 09:00 to 17:00 on monday, friday",
  "every 2 days at 09:00, 17:00",
  "every weekday at 09:00",
  "every 2 weeks on monday, friday at 09:00",
  "every month on the 1st to 5th, 15th at 09:00",
  "every month on the next nearest weekday to 15th at 09:00",
  "every month on the last friday at 09:00",
  "on 2026-12-25 at 09:00",
  "on dec 25 at 09:00",
  "every year on the first monday of mar at 09:00",
  "every 2 years on the 15th of jun at 09:00",
  "every day at 09:00 except dec 25, 2026-12-31 until 2027-01-01 starting 2026-01-01 during jan, feb in America/New_York",
];

const parts = {
  expr: {
    type: "dayRepeat",
    interval: 1,
    days: { type: "every" },
    times: [{ hour: 25, minute: 0 }],
  },
  timezone: null,
  except: [],
  until: null,
  anchor: null,
  during: [],
};

// biome-ignore lint/suspicious/noExplicitAny: calls the constructor as JavaScript can
const AnySchedule = Schedule as any;

function unfrozen(value: unknown, path = "expression"): string[] {
  if (typeof value !== "object" || value === null) return [];
  const own = Object.isFrozen(value) ? [] : [path];
  return own.concat(
    Object.entries(value).flatMap(([key, field]) =>
      unfrozen(field, `${path}.${key}`),
    ),
  );
}

function expectBuilderError(build: () => unknown) {
  expect(build).toThrow(TypeError);
  expect(build).toThrow(/built only by Schedule.parse or Schedule.fromCron/);
}

describe("building", () => {
  it("rejects the constructor called from JavaScript with parts", () => {
    expectBuilderError(() => new AnySchedule(parts));
    expectBuilderError(
      () => new AnySchedule(Symbol("Schedule builder"), parts),
    );
  });

  it("rejects a subclass that passes parts to the constructor", () => {
    class Built extends AnySchedule {
      constructor() {
        super(Symbol("Schedule builder"), parts);
      }
    }
    expectBuilderError(() => new Built());
  });

  const methods: [string, (s: Schedule) => unknown][] = [
    ["nextFrom", (s) => s.nextFrom(now)],
    ["nextNFrom", (s) => s.nextNFrom(now, 1)],
    ["previousFrom", (s) => s.previousFrom(now)],
    ["matches", (s) => s.matches(now)],
    ["occurrences", (s) => s.occurrences(now)],
    ["between", (s) => s.between(now, now)],
    ["toCron", (s) => s.toCron()],
    ["toString", (s) => s.toString()],
    ["timezone", (s) => s.timezone],
    ["expression", (s) => s.expression],
  ];
  for (const [name, call] of methods) {
    it(`${name} throws a TypeError on an object that only looks like a Schedule`, () => {
      const fake = Object.create(Schedule.prototype, {
        data: { value: parts },
      });
      expect(() => call(fake)).toThrow(TypeError);
    });
  }
});

describe("a built schedule cannot change", () => {
  for (const input of everyKind) {
    it(`freezes every part of the expression of ${input}`, () => {
      expect(unfrozen(Schedule.parse(input).expression)).toEqual([]);
    });
  }

  it("freezes the expression of a schedule from cron", () => {
    const schedule = Schedule.fromCron("0 9 1-5,15 * *");
    expect(unfrozen(schedule.expression)).toEqual([]);
  });

  it("throws on a write to its expression, and still fires as parsed", () => {
    const schedule = Schedule.parse("every day at 09:00");
    const expression = schedule.expression;
    if (expression.type !== "dayRepeat") throw new Error(expression.type);
    // biome-ignore lint/suspicious/noExplicitAny: writes as JavaScript can
    const times = expression.times as any;
    expect(() => {
      times[0].hour = 25;
    }).toThrow(TypeError);
    expect(() => times.push({ hour: 10, minute: 0 })).toThrow(TypeError);
    expect(() => {
      // biome-ignore lint/suspicious/noExplicitAny: writes as JavaScript can
      (expression as any).interval = 0;
    }).toThrow(TypeError);
    expect(schedule.toString()).toBe("every day at 09:00");
    expect(schedule.nextFrom(now)?.toString()).toBe(
      "2026-02-07T09:00:00+00:00[UTC]",
    );
  });

  it("keeps no field a caller can reach", () => {
    const schedule = Schedule.parse("every day at 09:00");
    expect(Object.keys(schedule)).toEqual([]);
    expect(Object.getOwnPropertyNames(schedule)).toEqual([]);
  });
});
