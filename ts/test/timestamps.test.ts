import { Temporal } from "@js-temporal/polyfill";
import { describe, expect, it } from "vitest";
import { HronError, Schedule } from "../src/index.js";

// spec/README.md, "Timestamps and counts".

const zoned = (s: string) => Temporal.ZonedDateTime.from(s);
const show = (ts: Iterable<Temporal.ZonedDateTime>) =>
  [...ts].map((t) => t.toString());

const tokyoNow = "2026-02-06T21:00:00+09:00[Asia/Tokyo]";
const berlinTo = "2026-02-07T15:00:00+01:00[Europe/Berlin]";
const newYork = Schedule.parse("every day at 09:00 in America/New_York");
const zoneless = Schedule.parse("every day at 09:00");

type Call = (schedule: Schedule, t: Temporal.ZonedDateTime) => unknown;

const timestampArguments: [string, string, Call][] = [
  ["nextFrom", "now", (s, t) => s.nextFrom(t)],
  ["nextNFrom", "now", (s, t) => s.nextNFrom(t, 2)],
  ["previousFrom", "now", (s, t) => s.previousFrom(t)],
  ["matches", "datetime", (s, t) => s.matches(t)],
  ["occurrences", "from", (s, t) => s.occurrences(t)],
  ["between", "from", (s, t) => s.between(t, zoned(berlinTo))],
  ["between", "to", (s, t) => s.between(zoned(tokyoNow), t)],
];

const notTimestamps: [string, unknown][] = [
  ["a Date", new Date("2026-02-06T12:00:00Z")],
  ["a string", "2026-02-06T12:00:00+00:00[UTC]"],
  ["undefined", undefined],
  ["null", null],
  ["a PlainDateTime", Temporal.PlainDateTime.from("2026-02-06T12:00:00")],
];

describe("a timestamp that is neither a ZonedDateTime nor an Instant", () => {
  for (const [method, name, call] of timestampArguments) {
    for (const [label, value] of notTimestamps) {
      it(`${method} throws a TypeError for ${label} as ${name}, when called`, () => {
        const run = () => call(newYork, value as Temporal.ZonedDateTime);
        expect(run).toThrowError(
          new TypeError(
            `${name} must be a Temporal.ZonedDateTime or Temporal.Instant`,
          ),
        );
      });
    }
  }

  it("is a TypeError, not a HronError", () => {
    let error: unknown = null;
    try {
      newYork.nextFrom(null as unknown as Temporal.ZonedDateTime);
    } catch (e) {
      error = e;
    }
    expect(error).toBeInstanceOf(TypeError);
    expect(error).not.toBeInstanceOf(HronError);
  });
});

type Timestamp = Temporal.ZonedDateTime | Temporal.Instant;
type Read = (s: string) => Timestamp;

function native(): typeof Temporal {
  const Native = (globalThis as { Temporal?: typeof Temporal }).Temporal;
  expect(Native, "native Temporal (see vitest.config.ts)").toBeDefined();
  return Native as typeof Temporal;
}

function nativeInstant(s: string): Temporal.Instant {
  const t = native().Instant.from(s);
  expect(t).not.toBeInstanceOf(Temporal.Instant);
  return t;
}

function nativeZoned(s: string): Temporal.ZonedDateTime {
  const t = native().ZonedDateTime.from(s);
  expect(t).not.toBeInstanceOf(Temporal.ZonedDateTime);
  return t;
}

function take<T>(items: Iterator<T>, n: number): T[] {
  const taken: T[] = [];
  while (taken.length < n) {
    const next = items.next();
    if (next.done) break;
    taken.push(next.value);
  }
  return taken;
}

const calls: [string, (schedule: Schedule, read: Read) => unknown][] = [
  ["nextFrom", (s, read) => s.nextFrom(read(tokyoNow))?.toString()],
  ["nextNFrom", (s, read) => show(s.nextNFrom(read(tokyoNow), 2))],
  ["previousFrom", (s, read) => s.previousFrom(read(tokyoNow))?.toString()],
  [
    "matches at 09:00 in New York",
    (s, read) => s.matches(read("2026-02-06T23:00:30+09:00[Asia/Tokyo]")),
  ],
  [
    "matches at 09:00 UTC",
    (s, read) => s.matches(read("2026-02-07T18:00:30+09:00[Asia/Tokyo]")),
  ],
  ["occurrences", (s, read) => show(take(s.occurrences(read(tokyoNow)), 2))],
  ["between", (s, read) => show(s.between(read(tokyoNow), read(berlinTo)))],
];

const readers: [string, Read][] = [
  ["a polyfill Instant", (s) => Temporal.Instant.from(s)],
  ["a native Instant", nativeInstant],
  ["a native ZonedDateTime", nativeZoned],
];

for (const [label, read] of readers) {
  describe(`${label} gives what the same ZonedDateTime gives`, () => {
    for (const [schedule, zone] of [
      [newYork, "America/New_York"],
      [zoneless, "UTC"],
    ] as [Schedule, string][]) {
      for (const [method, call] of calls) {
        it(`to ${method}, in ${zone}`, () => {
          expect(call(schedule, read)).toEqual(call(schedule, zoned));
        });
      }
    }
  });
}

describe("an Instant and a ZonedDateTime together", () => {
  it("bound between", () => {
    const from = Temporal.Instant.from(tokyoNow);
    expect(show(newYork.between(from, zoned(berlinTo)))).toEqual([
      "2026-02-06T09:00:00-05:00[America/New_York]",
      "2026-02-07T09:00:00-05:00[America/New_York]",
    ]);
  });
});

describe("nextNFrom's n", () => {
  const now = zoned(tokyoNow);
  // A schedule with one occurrence keeps a wrongly accepted n from running
  // to the end of the supported range.
  const once = Schedule.parse("on 2026-03-01 at 09:00");

  for (const [label, n] of [
    ["a string", "2"],
    ["undefined", undefined],
    ["null", null],
    ["a bigint", 2n],
  ] as [string, unknown][]) {
    it(`is a TypeError when it is ${label}`, () => {
      expect(() => once.nextNFrom(now, n as number)).toThrowError(
        new TypeError("n must be a number"),
      );
    });
  }

  for (const n of [1.5, Number.NaN, Number.POSITIVE_INFINITY, -Infinity]) {
    it(`is a RangeError when it is ${n}`, () => {
      expect(() => once.nextNFrom(now, n)).toThrowError(
        new RangeError("n must be an integer"),
      );
    });
  }

  for (const n of [0, -0, -1, Number.MIN_SAFE_INTEGER]) {
    it(`gives [] when it is ${n}`, () => {
      expect(once.nextNFrom(now, n)).toEqual([]);
    });
  }

  it("is checked after now", () => {
    expect(() =>
      once.nextNFrom(null as unknown as Temporal.ZonedDateTime, 1.5),
    ).toThrowError(
      new TypeError("now must be a Temporal.ZonedDateTime or Temporal.Instant"),
    );
  });

  it("only caps the count when it is huge", () => {
    expect(show(once.nextNFrom(now, Number.MAX_SAFE_INTEGER))).toEqual([
      "2026-03-01T09:00:00+00:00[UTC]",
    ]);
  });
});

describe("returned timestamps", () => {
  const now = zoned(tokyoNow);

  for (const [schedule, zone] of [
    [newYork, "America/New_York"],
    [zoneless, "UTC"],
  ] as [Schedule, string][]) {
    it(`are in ${zone} from every method`, () => {
      const results = [
        schedule.nextFrom(now),
        schedule.previousFrom(now),
        ...schedule.nextNFrom(now, 2),
        schedule.occurrences(now).next().value,
        ...schedule.between(now, zoned(berlinTo)),
      ];
      expect(results.map((t) => t?.timeZoneId)).toEqual(
        results.map(() => zone),
      );
    });
  }

  it("keep the instant of now when it is written in another zone", () => {
    expect(zoneless.nextFrom(now)?.toString()).toBe(
      "2026-02-07T09:00:00+00:00[UTC]",
    );
  });
});

describe("arguments", () => {
  it("are not modified", () => {
    const now = zoned(tokyoNow);
    const to = zoned(berlinTo);
    newYork.nextFrom(now);
    newYork.nextNFrom(now, 3);
    newYork.previousFrom(now);
    newYork.matches(now);
    [...newYork.between(now, to)];
    newYork.occurrences(now).next();
    expect([now.toString(), to.toString()]).toEqual([tokyoNow, berlinTo]);
  });
});
