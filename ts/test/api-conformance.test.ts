import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";
import { HronError, Schedule } from "../src/index.js";

// TypeScript uses api.json's names unchanged (its note in spec/api.json).
const apiSpec = JSON.parse(
  readFileSync(resolve(__dirname, "../../spec/api.json"), "utf-8"),
);

type Method = { name: string; params: unknown[] };
type Named = { name: string };

function members(value: unknown): Record<string, unknown> {
  return value as Record<string, unknown>;
}

function hronError(build: () => unknown): HronError {
  try {
    build();
  } catch (error) {
    if (error instanceof HronError) return error;
    throw error;
  }
  throw new Error("no error");
}

const instance = Schedule.parse("every day at 09:00 in America/New_York");
const lexError = hronError(() => Schedule.parse("every day at 09:00 \u0001"));
const parseError = hronError(() =>
  Schedule.parse("every weekday at 09:00 until dec 31"),
);
const cronError = hronError(() => Schedule.fromCron("0 9 15 * 1"));
const realErrors = [lexError, parseError, cronError];

function isMethod(target: unknown, method: Method): boolean {
  const member = members(target)[method.name];
  return typeof member === "function" && member.length === method.params.length;
}

function isReadOnlyGetter(name: string): boolean {
  const descriptor = Object.getOwnPropertyDescriptor(Schedule.prototype, name);
  return (
    typeof descriptor?.get === "function" &&
    descriptor.set === undefined &&
    members(instance)[name] !== undefined
  );
}

function hasProperty(property: Named & { required: boolean }): boolean {
  const errors = property.required ? realErrors : [parseError];
  return errors.every((error) => members(error)[property.name] !== undefined);
}

function buildsKind(kind: string): boolean {
  const build = members(HronError)[kind];
  if (typeof build !== "function") return false;
  const built = build.call(HronError, "message", { start: 0, end: 1 }, "x");
  return built instanceof HronError && built.kind === kind;
}

function gaps(spec: typeof apiSpec): string[] {
  const out: string[] = [];
  const check = (section: string, name: string, present: boolean) => {
    if (!present) out.push(`${section}.${name}`);
  };
  for (const method of spec.schedule.staticMethods as Method[]) {
    check("staticMethods", method.name, isMethod(Schedule, method));
  }
  for (const method of spec.schedule.instanceMethods as Method[]) {
    check("instanceMethods", method.name, isMethod(instance, method));
  }
  for (const getter of spec.schedule.getters as Named[]) {
    check("getters", getter.name, isReadOnlyGetter(getter.name));
  }
  for (const property of spec.error.properties) {
    check("properties", property.name, hasProperty(property));
  }
  for (const name of spec.error.constructors as string[]) {
    check("constructors", name, buildsKind(name));
  }
  for (const kind of spec.error.kinds as string[]) {
    const thrown = realErrors.some((error) => error.kind === kind);
    check("kinds", kind, thrown || buildsKind(kind));
  }
  for (const method of spec.error.methods as Method[]) {
    check("methods", method.name, isMethod(parseError, method));
  }
  return out;
}

describe("API conformance", () => {
  it("knows every section of api.json", () => {
    expect(Object.keys(apiSpec).sort()).toEqual([
      "casing",
      "description",
      "error",
      "notes",
      "parts",
      "schedule",
      "version",
    ]);
    expect(Object.keys(apiSpec.schedule).sort()).toEqual([
      "getters",
      "instanceMethods",
      "staticMethods",
    ]);
    expect(Object.keys(apiSpec.error).sort()).toEqual([
      "constructors",
      "description",
      "kinds",
      "methods",
      "properties",
    ]);
  });

  it("has every name in api.json", () => {
    expect(gaps(apiSpec)).toEqual([]);
  });

  it("throws errors of the kinds of api.json", () => {
    expect(realErrors.map((error) => error.kind)).toEqual([
      "lex",
      "parse",
      "cron",
    ]);
  });

  it("renders a real error with displayRich", () => {
    expect(parseError.displayRich()).toBe(
      'error: until dec 31 has no year: add a starting date, or use an ISO date\n  every weekday at 09:00 until dec 31\n                         ^^^^^^^^^^^^ try: "until dec 31 starting YYYY-MM-DD"',
    );
  });

  const fakes: [string, (spec: typeof apiSpec) => void][] = [
    ["staticMethods", (s) => s.schedule.staticMethods.push(fakeMethod())],
    ["instanceMethods", (s) => s.schedule.instanceMethods.push(fakeMethod())],
    ["getters", (s) => s.schedule.getters.push({ name: "fake" })],
    [
      "properties",
      (s) => s.error.properties.push({ name: "fake", required: true }),
    ],
    ["constructors", (s) => s.error.constructors.push("fake")],
    ["kinds", (s) => s.error.kinds.push("fake")],
    ["methods", (s) => s.error.methods.push(fakeMethod())],
  ];
  for (const [section, addFake] of fakes) {
    it(`fails for a name in ${section} that this package lacks`, () => {
      const copy = structuredClone(apiSpec);
      addFake(copy);
      expect(newGaps(copy)).toEqual([`${section}.fake`]);
    });
  }

  it("fails for a method whose parameters differ from api.json", () => {
    const copy = structuredClone(apiSpec);
    copy.schedule.instanceMethods
      .find((method: Named) => method.name === "equals")
      .params.push({ name: "extra", type: "int" });
    expect(newGaps(copy)).toEqual(["instanceMethods.equals"]);
  });
});

function newGaps(spec: typeof apiSpec): string[] {
  const known = gaps(apiSpec);
  return gaps(spec).filter((gap) => !known.includes(gap));
}

function fakeMethod(): Method {
  return { name: "fake", params: [] };
}
