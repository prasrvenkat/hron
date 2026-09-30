import { Temporal } from "@js-temporal/polyfill";
import { describe, expect, it } from "vitest";
import { Schedule } from "../src/index.js";

const zoned = (s: string) => Temporal.ZonedDateTime.from(s);

describe("offset changes close together", () => {
  it("resolves a time inside one week of DST (Boa Vista 2000)", () => {
    const schedule = Schedule.parse(
      "on 2000-10-08 at 09:00 in America/Boa_Vista",
    );
    const next = schedule.nextFrom(zoned("2000-10-01T00:00:00+00:00[UTC]"));
    expect(next?.toString()).toBe(
      "2000-10-08T09:00:00-03:00[America/Boa_Vista]",
    );
  });

  it("returns across three offsets in two weeks (Riga 1944)", () => {
    const schedule = Schedule.parse("every day at 12:00 in Europe/Riga");
    const now = zoned("1944-10-02T00:00:00+00:00[UTC]");
    const expected = Temporal.PlainDateTime.from("1944-10-02T12:00")
      .toZonedDateTime("Europe/Riga")
      .toString();
    expect(schedule.nextFrom(now)?.toString()).toBe(expected);
  });
});

describe("sub-millisecond instants before 1970", () => {
  const schedule = Schedule.parse("every day at 09:00 in UTC");
  const now = zoned("1969-07-20T08:59:59.9995+00:00[UTC]");

  it("nextFrom is the occurrence half a millisecond later", () => {
    expect(schedule.nextFrom(now)?.toString()).toBe(
      "1969-07-20T09:00:00+00:00[UTC]",
    );
  });

  it("previousFrom is the day before", () => {
    expect(schedule.previousFrom(now)?.toString()).toBe(
      "1969-07-19T09:00:00+00:00[UTC]",
    );
  });
});

describe("supported range at nanosecond precision", () => {
  const schedule = Schedule.parse("every day at 00:00 in UTC");
  const justBefore = zoned("0001-01-01T23:59:59.999999999+00:00[UTC]");

  it("matches is false one nanosecond before the range", () => {
    expect(schedule.matches(justBefore)).toBe(false);
  });

  it("nextFrom is null one nanosecond before the range", () => {
    expect(schedule.nextFrom(justBefore)).toBeNull();
  });
});
