import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";
import { Schedule as TsSchedule } from "../../../ts/src/index.js";
import { Schedule, fromCron } from "../pkg/hron_wasm.js";

const spec = JSON.parse(
  readFileSync(resolve(__dirname, "../../../spec/tests.json"), "utf-8"),
);
const parseInputs: string[] = Object.entries(spec.parse)
  .filter(([section]) => section !== "description")
  .flatMap(([, data]: [string, any]) => data.tests.map((test: any) => test.input));
const crons: string[] = spec.cron.from_cron.tests.map((test: any) => test.cron);

const getters = ["timezone", "expression", "except", "until", "starting", "during"] as const;

function view(schedule: any) {
  return Object.fromEntries(getters.map((getter) => [getter, schedule[getter]]));
}

function unfrozen(value: unknown, path: string): string[] {
  if (typeof value !== "object" || value === null) return [];
  const own = Object.isFrozen(value) ? [] : [path];
  return own.concat(
    Object.entries(value).flatMap(([key, field]) => unfrozen(field, `${path}.${key}`)),
  );
}

function unfrozenGetters(schedule: any): string[] {
  return getters.flatMap((getter) => unfrozen(schedule[getter], getter));
}

describe("getters", () => {
  it("covers every parse input in spec/tests.json", () => {
    expect(parseInputs.length).toBeGreaterThan(100);
  });

  // JSON.stringify also compares the order of the keys, which console.log shows.
  it.each(parseInputs)("returns what hron-ts returns for %s", (input) => {
    const [wasm, ts] = [view(Schedule.parse(input)), view(TsSchedule.parse(input))];
    expect(wasm).toStrictEqual(ts);
    expect(JSON.stringify(wasm)).toBe(JSON.stringify(ts));
  });

  it.each(crons)("returns what hron-ts returns for fromCron(%s)", (cron) => {
    const [wasm, ts] = [view(fromCron(cron)), view(TsSchedule.fromCron(cron))];
    expect(wasm).toStrictEqual(ts);
    expect(JSON.stringify(wasm)).toBe(JSON.stringify(ts));
  });

  it("returns null, not undefined, for a clause that is absent", () => {
    const schedule = Schedule.parse("every day at 09:00");
    expect(schedule.timezone).toBeNull();
    expect(schedule.until).toBeNull();
    expect(schedule.starting).toBeNull();
    expect(schedule.except).toEqual([]);
    expect(schedule.during).toEqual([]);
  });

  it("reads like hron-ts's objects", () => {
    const expression = Schedule.parse("every 30 min from 09:00 to 17:00").expression;
    expect(expression.type === "intervalRepeat" && expression.from.hour).toBe(9);
    const times = Schedule.parse("every day at 09:00, 17:00").expression;
    expect(times.type === "dayRepeat" && times.times.length).toBe(2);
  });

  it.each(parseInputs)("freezes every object and array it returns for %s", (input) => {
    expect(unfrozenGetters(Schedule.parse(input))).toEqual([]);
  });

  it.each(crons)("freezes every object and array it returns for fromCron(%s)", (cron) => {
    expect(unfrozenGetters(fromCron(cron))).toEqual([]);
  });

  it("throws on a write to what it returns, and the schedule stays as it was", () => {
    const schedule = Schedule.parse("every day at 09:00 except dec 25");
    const expression: any = schedule.expression;
    expect(() => {
      expression.times[0].hour = 10;
    }).toThrow(TypeError);
    expect(() => (schedule.except as any[]).pop()).toThrow(TypeError);
    expect(schedule.toString()).toBe("every day at 09:00 except dec 25");
  });
});
