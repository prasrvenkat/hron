import { describe, it, expect } from "vitest";
import { Schedule } from "../pkg/hron_wasm.js";

// spec/README.md "Supported range": an instant beyond it returns nothing, while a
// malformed timestamp still throws.
describe("timestamp inputs", () => {
  const schedule = Schedule.parse("every day at 00:00 in UTC");

  it("returns nothing for an instant outside the supported range", () => {
    expect(schedule.nextFrom("9999-12-31T12:00:00+00:00[UTC]")).toBeUndefined();
    expect(schedule.previousFrom("0001-01-01T00:00:00+14:00[Etc/GMT-14]")).toBeUndefined();
    expect(schedule.between("2026-01-01T00:00:00+00:00[UTC]", "9999-12-31T12:00:00+00:00[UTC]")).toEqual([]);
    expect(schedule.nextFrom("-009999-01-01T00:00:00+00:00[UTC]")).toBeUndefined();
  });

  it("throws for an unknown zone at the range edge", () => {
    expect(() => schedule.nextFrom("9999-06-01T00:00:00+00:00[Nope/Zone]")).toThrow();
    expect(() => schedule.nextFrom("9999-12-31T12:00:00+00:00[Nope/Zone]")).toThrow();
  });

  it("throws for an offset that conflicts with its zone inside jiff's range", () => {
    expect(() =>
      schedule.between("2026-01-01T00:00:00+00:00[UTC]", "9999-12-30T12:00:00+05:00[America/New_York]"),
    ).toThrow();
  });
});
