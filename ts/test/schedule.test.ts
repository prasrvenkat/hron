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
  expression: {
    type: "dayRepeat",
    interval: 1,
    days: { type: "every" },
    times: [{ hour: 25, minute: 0 }],
  },
  timezone: null,
  except: [],
  until: null,
  starting: null,
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
    ["except", (s) => s.except],
    ["until", (s) => s.until],
    ["starting", (s) => s.starting],
    ["during", (s) => s.during],
    ["equals", (s) => s.equals(Schedule.parse("every day at 09:00"))],
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
    it(`freezes every part of ${input}`, () => {
      const schedule = Schedule.parse(input);
      expect(unfrozen(schedule.expression)).toEqual([]);
      expect(unfrozen(schedule.except, "except")).toEqual([]);
      expect(unfrozen(schedule.until, "until")).toEqual([]);
      expect(unfrozen(schedule.during, "during")).toEqual([]);
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

describe("getters", () => {
  const all = Schedule.parse(
    "every day at 09:00 except dec 25, 2026-12-31 until 2027-01-01 starting 2026-01-01 during jan, feb in America/New_York",
  );
  const none = Schedule.parse("every day at 09:00");

  it("read the expression", () => {
    expect(none.expression).toEqual({
      type: "dayRepeat",
      interval: 1,
      days: { type: "every" },
      times: [{ hour: 9, minute: 0 }],
    });
  });

  it("read every clause", () => {
    expect(all.except).toEqual([
      { type: "named", month: "dec", day: 25 },
      { type: "iso", date: "2026-12-31" },
    ]);
    expect(all.until).toEqual({ type: "iso", date: "2027-01-01" });
    expect(all.starting).toBe("2026-01-01");
    expect(all.during).toEqual(["jan", "feb"]);
    expect(all.timezone).toBe("America/New_York");
  });

  it("read a named until", () => {
    const named = Schedule.parse(
      "every day at 09:00 until dec 31 starting 2026-01-01",
    );
    expect(named.until).toEqual({ type: "named", month: "dec", day: 31 });
  });

  it("read an absent clause as empty or null", () => {
    expect(none.except).toEqual([]);
    expect(none.until).toBeNull();
    expect(none.starting).toBeNull();
    expect(none.during).toEqual([]);
    expect(none.timezone).toBeNull();
  });

  it("read the during months of a schedule from cron", () => {
    expect(Schedule.fromCron("0 9 * 1,2 *").during).toEqual(["jan", "feb"]);
  });

  it("throw on a write, and the schedule still fires as parsed", () => {
    // biome-ignore lint/suspicious/noExplicitAny: writes as JavaScript can
    const writable = all as any;
    expect(() =>
      writable.except.push({ type: "iso", date: "2026-06-01" }),
    ).toThrow(TypeError);
    expect(() => {
      writable.except[0].day = 24;
    }).toThrow(TypeError);
    expect(() => {
      writable.until.date = "2030-01-01";
    }).toThrow(TypeError);
    expect(() => writable.during.push("mar")).toThrow(TypeError);
    for (const getter of [
      "timezone",
      "expression",
      "except",
      "until",
      "starting",
      "during",
    ]) {
      expect(() => {
        writable[getter] = null;
      }, getter).toThrow(TypeError);
    }
    expect(all.toString()).toBe(
      "every day at 09:00 except dec 25, 2026-12-31 until 2027-01-01 starting 2026-01-01 during jan, feb in America/New_York",
    );
    expect(
      all.nextFrom(Temporal.Instant.from("2026-02-28T15:00:00Z"))?.toString(),
    ).toBe("2027-01-01T09:00:00-05:00[America/New_York]");
  });
});

describe("equality", () => {
  const equal: [string, string][] = [
    ["every day at 9:00", "every day at 09:00"],
    [
      "every day at 09:00 in america/new_york",
      "every day at 09:00 in America/New_York",
    ],
    ["Every Weekday At 09:00", "every weekday at 09:00"],
  ];
  for (const [a, b] of equal) {
    it(`${a} equals ${b}`, () => {
      expect(Schedule.parse(a).equals(Schedule.parse(b))).toBe(true);
      expect(Schedule.parse(b).equals(Schedule.parse(a))).toBe(true);
    });
  }

  it("holds for a schedule and itself", () => {
    const schedule = Schedule.parse("every day at 09:00");
    expect(schedule.equals(schedule)).toBe(true);
  });

  it("holds for a schedule from cron and the same schedule parsed", () => {
    expect(
      Schedule.fromCron("0 9 * * 1-5").equals(
        Schedule.parse("every weekday at 09:00"),
      ),
    ).toBe(true);
  });

  const base =
    "every day at 09:00 except dec 25 until 2027-01-01 starting 2026-01-01 during jan in UTC";
  const differ: [string, string][] = [
    [
      "expression",
      "every day at 10:00 except dec 25 until 2027-01-01 starting 2026-01-01 during jan in UTC",
    ],
    [
      "timezone",
      "every day at 09:00 except dec 25 until 2027-01-01 starting 2026-01-01 during jan in Europe/London",
    ],
    [
      "timezone, absent",
      "every day at 09:00 except dec 25 until 2027-01-01 starting 2026-01-01 during jan",
    ],
    [
      "except",
      "every day at 09:00 except dec 24 until 2027-01-01 starting 2026-01-01 during jan in UTC",
    ],
    [
      "until",
      "every day at 09:00 except dec 25 until 2027-01-02 starting 2026-01-01 during jan in UTC",
    ],
    [
      "starting",
      "every day at 09:00 except dec 25 until 2027-01-01 starting 2026-01-02 during jan in UTC",
    ],
    [
      "during",
      "every day at 09:00 except dec 25 until 2027-01-01 starting 2026-01-01 during feb in UTC",
    ],
  ];
  for (const [part, other] of differ) {
    it(`fails when only the ${part} differs`, () => {
      expect(Schedule.parse(base).equals(Schedule.parse(other))).toBe(false);
      expect(Schedule.parse(other).equals(Schedule.parse(base))).toBe(false);
    });
  }

  const unequal: [string, string, string][] = [
    [
      "a list in another order",
      "every day at 09:00, 17:00",
      "every day at 17:00, 09:00",
    ],
    [
      "a duplicate in a list",
      "every day at 09:00 during jan, jan",
      "every day at 09:00 during jan",
    ],
    [
      "a list one item longer",
      "every day at 09:00 except dec 25, dec 26",
      "every day at 09:00 except dec 25",
    ],
    [
      "a day filter against none",
      "every 30 min from 09:00 to 17:00 on weekday",
      "every 30 min from 09:00 to 17:00",
    ],
    [
      "another expression kind",
      "every weekday at 09:00",
      "every week on monday, tuesday, wednesday, thursday, friday at 09:00",
    ],
    [
      "a nested item",
      "every 30 min from 09:00 to 17:00 on monday, friday",
      "every 30 min from 09:00 to 17:00 on monday, saturday",
    ],
  ];
  for (const [label, a, b] of unequal) {
    it(`fails for ${label}`, () => {
      expect(Schedule.parse(a).equals(Schedule.parse(b))).toBe(false);
      expect(Schedule.parse(b).equals(Schedule.parse(a))).toBe(false);
    });
  }

  const others: [string, unknown][] = [
    ["null", null],
    ["undefined", undefined],
    ["its string", "every day at 09:00"],
    ["a number", 9],
    [
      "its parts",
      { ...parts, expression: Schedule.parse("every day at 09:00").expression },
    ],
    [
      "an object built on Schedule.prototype",
      Object.create(Schedule.prototype),
    ],
  ];
  for (const [label, other] of others) {
    it(`is false, not an error, against ${label}`, () => {
      expect(Schedule.parse("every day at 09:00").equals(other)).toBe(false);
    });
  }
});

describe("an input that is not a string", () => {
  const calls: [string, string, (input: unknown) => unknown][] = [
    ["parse", "input", (input) => Schedule.parse(input as string)],
    ["validate", "input", (input) => Schedule.validate(input as string)],
    ["fromCron", "cronExpr", (input) => Schedule.fromCron(input as string)],
  ];
  const inputs: [string, unknown][] = [
    ["null", null],
    ["undefined", undefined],
    ["a number", 9],
    ["a String object", new String("every day at 09:00")],
    ["an array", ["every day at 09:00"]],
  ];
  for (const [method, name, call] of calls) {
    for (const [label, input] of inputs) {
      it(`makes ${method} throw a TypeError for ${label}`, () => {
        expect(() => call(input)).toThrow(
          new TypeError(`${name} must be a string`),
        );
      });
    }
  }

  it("leaves validate false, not throwing, for a string parse rejects", () => {
    expect(Schedule.validate("")).toBe(false);
    expect(Schedule.validate("every")).toBe(false);
    expect(Schedule.validate("every day at 09:00 in Mars/Base")).toBe(false);
  });
});
