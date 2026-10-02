import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";
import { Schedule, fromCron } from "../pkg/hron_wasm.js";

// spec/README.md, "Equality".

const spec = JSON.parse(
  readFileSync(resolve(__dirname, "../../../spec/tests.json"), "utf-8"),
);
const parseInputs: string[] = Object.entries(spec.parse)
  .filter(([section]) => section !== "description")
  .flatMap(([, data]: [string, any]) => data.tests.map((test: any) => test.input));
const crons: string[] = spec.cron.from_cron.tests.map((test: any) => test.cron);

describe("equals", () => {
  it("is true for schedules with equal parts", () => {
    const nine = Schedule.parse("every day at 9:00");
    expect(nine.equals(Schedule.parse("every day at 09:00"))).toBe(true);
    expect(Schedule.parse("every day at 09:00").equals(nine)).toBe(true);
    expect(nine.equals(nine)).toBe(true);
  });

  it.each(parseInputs)("holds between %s and the parse of its toString", (input) => {
    const schedule = Schedule.parse(input);
    expect(schedule.equals(Schedule.parse(schedule.toString()))).toBe(true);
  });

  it.each(crons)("holds between fromCron(%s) and the parse of its toString", (cron) => {
    const schedule = fromCron(cron);
    expect(schedule.equals(Schedule.parse(schedule.toString()))).toBe(true);
  });

  it("compares lists in order, duplicates included", () => {
    const parse = Schedule.parse;
    expect(parse("every day at 09:00, 17:00").equals(parse("every day at 17:00, 09:00"))).toBe(false);
    expect(parse("every day at 09:00, 09:00").equals(parse("every day at 09:00"))).toBe(false);
    expect(parse("every day at 09:00").equals(parse("every day at 09:01"))).toBe(false);
    expect(parse("every day at 09:00").equals(parse("every day at 09:00 in UTC"))).toBe(false);
  });

  it.each([
    ["null", null],
    ["undefined", undefined],
    ["a number", 42],
    ["the schedule's text", "every day at 09:00"],
    ["a plain object", {}],
    ["an object whose toString gives the same text", { toString: () => "every day at 09:00" }],
    ["an object made from Schedule.prototype", Object.create(Schedule.prototype)],
    ["a revoked proxy", (() => {
      const { proxy, revoke } = Proxy.revocable({}, {});
      revoke();
      return proxy;
    })()],
  ])("is false, without a throw, for %s", (_, other) => {
    expect(Schedule.parse("every day at 09:00").equals(other)).toBe(false);
  });

  // Each holds the pointer of a live schedule, so only the prototype check
  // tells it apart from one.
  it("is false for an object that copies a schedule's pointer without its prototype", () => {
    const schedule: any = Schedule.parse("every day at 09:00");
    const prototypeless = Object.assign(Object.create(null), { __wbg_ptr: schedule.__wbg_ptr });
    expect(schedule.equals({ __wbg_ptr: schedule.__wbg_ptr })).toBe(false);
    expect(schedule.equals(prototypeless)).toBe(false);
  });

  it("is false for a schedule whose memory was freed", () => {
    const freed = Schedule.parse("every day at 09:00");
    freed.free();
    expect(Schedule.parse("every day at 09:00").equals(freed)).toBe(false);
  });
});
