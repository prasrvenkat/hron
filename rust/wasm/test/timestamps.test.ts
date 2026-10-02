import { describe, it, expect } from "vitest";
import { Schedule } from "../pkg/hron_wasm.js";

// spec/README.md, "Timestamps and counts" and "Supported range".

function thrown(action: () => unknown): any {
  try {
    action();
  } catch (error) {
    return error;
  }
  throw new Error("expected a throw");
}

const daily = Schedule.parse("every day at 09:00");

describe("timestamp strings", () => {
  // Each names 2026-02-06T03:00:00Z, so the next 09:00 UTC is the same day.
  it.each([
    "2026-02-06T12:00:00+09:00[Asia/Tokyo]",
    "2026-02-06T03:00:00Z",
    "2026-02-06t03:00:00.000z",
    "2026-02-06T03:00:00+00:00[Asia/Tokyo]",
    "2026-02-06T12:00:00+09:00[!Asia/Tokyo]",
    "2026-02-06T03:00:00Z[Asia/Tokyo]",
    "2026-02-06T03:00:00Z[!Asia/Tokyo]",
    "2026-02-06T03:00:00+00:00[u-ca=hebrew]",
    "2026-02-06T12:00:00+09:00[Asia/Tokyo][u-ca=japanese]",
    "2026-02-06T12:00:00+09:00[+09:00]",
    "+002026-02-06T03:00:00Z",
  ])("reads %s as its instant", (now) => {
    expect(daily.nextFrom(now)).toBe("2026-02-06T09:00:00+00:00[UTC]");
  });

  it("lets the offset decide the instant over a zone that disagrees", () => {
    expect(daily.nextFrom("2026-02-06T08:59:00+00:00[Asia/Tokyo]")).toBe(
      "2026-02-06T09:00:00+00:00[UTC]",
    );
    expect(daily.matches("2026-02-06T09:00:30+00:00[America/New_York]")).toBe(true);
  });

  it.each([
    "2026-02-06T12:00:00[Asia/Tokyo]",
    "2026-02-06T12:00:00",
    "2026-02-06T03:00:00+00:00[!Asia/Tokyo]",
    "2026-02-06T03:00:00+00:00[Nope/Zone]",
    "2026-02-06T03:00:00+00:00[!u-ca=hebrew]",
    "2026-02-06",
    "tomorrow",
    "",
    "+010000-01-01T00:00:00[UTC]",
    "+010000-01-01T00:00:00+00:00[Nope/Zone]",
    "9999-12-31T12:00:00+00:00[Nope/Zone]",
  ])("throws a RangeError with no kind for %j", (bad) => {
    for (const action of [
      () => daily.nextFrom(bad),
      () => daily.previousFrom(bad),
      () => daily.matches(bad),
      () => daily.nextNFrom(bad, 1),
      () => daily.occurrences(bad, 1),
      () => daily.between(bad, "2026-02-06T03:00:00Z"),
      () => daily.between("2026-02-06T03:00:00Z", bad),
    ]) {
      const error = thrown(action);
      expect(error).toBeInstanceOf(RangeError);
      expect(error.message).toContain(`invalid timestamp "${bad}"`);
      expect("kind" in error).toBe(false);
    }
  });

  it.each([new Date("2026-02-06T03:00:00Z"), Date.parse("2026-02-06T03:00:00Z"), undefined, null, {}])(
    "throws a TypeError with no kind for %s",
    (value: any) => {
      for (const action of [
        () => daily.nextFrom(value),
        () => daily.previousFrom(value),
        () => daily.matches(value),
        () => daily.nextNFrom(value, 1),
        () => daily.occurrences(value, 1),
        () => daily.between(value, "2026-02-06T03:00:00Z"),
        () => daily.between("2026-02-06T03:00:00Z", value),
      ]) {
        const error = thrown(action);
        expect(error).toBeInstanceOf(TypeError);
        expect("kind" in error).toBe(false);
      }
    },
  );

  it("writes seconds, a ±HH:MM offset and the schedule's zone or UTC", () => {
    const now = "2026-02-06T21:00:00+09:00[Asia/Tokyo]";
    const newYork = Schedule.parse("every day at 09:00 in America/New_York");
    expect(newYork.nextNFrom(now, 2)).toEqual([
      "2026-02-06T09:00:00-05:00[America/New_York]",
      "2026-02-07T09:00:00-05:00[America/New_York]",
    ]);
    expect(newYork.previousFrom(now)).toBe("2026-02-05T09:00:00-05:00[America/New_York]");
    expect(newYork.between(now, "2026-02-07T15:00:00+01:00[Europe/Berlin]")).toEqual([
      "2026-02-06T09:00:00-05:00[America/New_York]",
      "2026-02-07T09:00:00-05:00[America/New_York]",
    ]);
    expect(daily.occurrences(now, 1)).toEqual(["2026-02-07T09:00:00+00:00[UTC]"]);
  });
});

describe("timestamps outside the supported range", () => {
  const schedule = Schedule.parse("every day at 00:00 in UTC");

  // Date.prototype.toISOString writes six-digit years, up to ±275760.
  it.each([
    "+010000-01-01T00:00:00Z",
    "-010000-01-01T00:00:00Z",
    new Date(8.64e15).toISOString(),
    new Date(-8.64e15).toISOString(),
    "-000001-01-01T00:00:00Z",
    "0001-01-01T00:00:00Z",
    "9999-12-31T12:00:00+00:00[UTC]",
    "-009999-01-01T00:00:00+00:00[UTC]",
    "0001-01-01T00:00:00+14:00[Etc/GMT-14]",
    "9999-12-30T12:00:00+05:00[America/New_York]",
  ])("finds nothing for %s and throws nothing", (outside) => {
    const inside = "2026-01-01T00:00:00+00:00[UTC]";
    expect(schedule.nextFrom(outside)).toBeNull();
    expect(schedule.previousFrom(outside)).toBeNull();
    expect(schedule.matches(outside)).toBe(false);
    expect(schedule.nextNFrom(outside, 3)).toEqual([]);
    expect(schedule.occurrences(outside, 3)).toEqual([]);
    expect(schedule.between(outside, inside)).toEqual([]);
    expect(schedule.between(inside, outside)).toEqual([]);
  });
});

describe("counts", () => {
  const now = "2026-02-06T12:00:00+00:00[UTC]";
  const twice = Schedule.parse("every day at 09:00 until 2026-02-08");
  const both = ["2026-02-07T09:00:00+00:00[UTC]", "2026-02-08T09:00:00+00:00[UTC]"];

  it.each([0, -0, -1, -(2 ** 53)])("returns nothing for %d", (count) => {
    expect(daily.nextNFrom(now, count)).toEqual([]);
    expect(daily.occurrences(now, count)).toEqual([]);
  });

  it.each([2 ** 31 - 1, 2 ** 32 + 1, Number.MAX_SAFE_INTEGER])(
    "only caps the count at %d, without wrapping",
    (count) => {
      expect(twice.nextNFrom(now, count)).toEqual(both);
      expect(twice.occurrences(now, count)).toEqual(both);
    },
  );

  it.each([1.5, NaN, Infinity, -Infinity])("throws a RangeError for %d", (count) => {
    for (const action of [() => daily.nextNFrom(now, count), () => daily.occurrences(now, count)]) {
      const error = thrown(action);
      expect(error).toBeInstanceOf(RangeError);
      expect("kind" in error).toBe(false);
    }
  });

  it.each(["2", undefined, null, 2n])("throws a TypeError for %s", (count: any) => {
    for (const action of [() => daily.nextNFrom(now, count), () => daily.occurrences(now, count)]) {
      const error = thrown(action);
      expect(error).toBeInstanceOf(TypeError);
      expect("kind" in error).toBe(false);
    }
  });
});

describe("toJSON", () => {
  it("returns a plain object that JSON.stringify serializes", () => {
    const schedule = Schedule.parse("every weekday at 09:00 in UTC");
    expect(Object.getPrototypeOf(schedule.toJSON())).toBe(Object.prototype);
    expect(JSON.stringify(schedule)).toBe(
      '{"kind":"every","days":["monday","tuesday","wednesday","thursday","friday"],' +
        '"times":["09:00"],"except":[],"until":null,"starting":null,"during":[],"timezone":"UTC"}',
    );
  });
});
