import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, it, expect } from "vitest";
import { Schedule, fromCron } from "../pkg/hron_wasm.js";

// spec/api.json's names map to WebAssembly's as its wasm note says.

const apiSpec = JSON.parse(
  readFileSync(resolve(__dirname, "../../../spec/api.json"), "utf-8"),
);
const declarations = readFileSync(resolve(__dirname, "../pkg/hron_wasm.d.ts"), "utf-8");
const hronErrorDeclaration = declarations.match(/export interface HronError [^}]*\}/)?.[0] ?? "";

function thrown(action: () => unknown): any {
  try {
    action();
  } catch (error) {
    return error;
  }
  throw new Error("expected a throw");
}

const lexError = () => thrown(() => Schedule.parse("every day at 09:00 #"));
const parseError = () => thrown(() => Schedule.parse("every weekday at 09:00 until dec 31"));
const cronError = () => thrown(() => fromCron("0 9 15 * 1"));

const isStaticMethod = (name: string) => () =>
  expect(typeof (Schedule as any)[name]).toBe("function");

const isInstanceMethod = (name: string) => () =>
  expect(typeof (Schedule.prototype as any)[name]).toBe("function");

const isGetter = (name: string, type: string) => () => {
  const descriptor = Object.getOwnPropertyDescriptor(Schedule.prototype, name);
  expect(typeof descriptor?.get).toBe("function");
  expect(descriptor?.set).toBeUndefined();
  expect(declarations).toContain(`readonly ${name}: ${type};`);
};

const isErrorProperty = (name: string, presentOn: (() => any)[], absentFrom: (() => any)[]) =>
  () => {
    expect(hronErrorDeclaration).toMatch(new RegExp(`readonly ${name}\\??: `));
    for (const error of presentOn) expect(error()[name]).toBeDefined();
    for (const error of absentFrom) expect(error()[name]).toBeUndefined();
  };

const throwsKind = (kind: string, error: () => any) => () => {
  expect(hronErrorDeclaration).toContain("readonly kind: HronErrorKind;");
  expect(declarations).toMatch(new RegExp(`export type HronErrorKind = [^;]*"${kind}"`));
  expect(error().kind).toBe(kind);
};

const noErrorConstructors = () =>
  expect(apiSpec.notes.wasm).toContain("there are no error constructors");

const members: Record<string, Record<string, () => void>> = {
  "schedule.staticMethods": {
    parse: isStaticMethod("parse"),
    fromCron: () => expect(fromCron("0 9 * * *")).toBeInstanceOf(Schedule),
    validate: isStaticMethod("validate"),
  },
  "schedule.instanceMethods": {
    nextFrom: isInstanceMethod("nextFrom"),
    nextNFrom: isInstanceMethod("nextNFrom"),
    previousFrom: isInstanceMethod("previousFrom"),
    matches: isInstanceMethod("matches"),
    occurrences: isInstanceMethod("occurrences"),
    between: isInstanceMethod("between"),
    toCron: isInstanceMethod("toCron"),
    toString: () => expect(Object.hasOwn(Schedule.prototype, "toString")).toBe(true),
    equals: isInstanceMethod("equals"),
  },
  "schedule.getters": {
    timezone: isGetter("timezone", "string | null"),
    expression: isGetter("expression", "ScheduleExpr"),
    except: isGetter("except", "Exception[]"),
    until: isGetter("until", "UntilSpec | null"),
    starting: isGetter("starting", "string | null"),
    during: isGetter("during", "MonthName[]"),
  },
  "error.kinds": {
    lex: throwsKind("lex", lexError),
    parse: throwsKind("parse", parseError),
    cron: throwsKind("cron", cronError),
    // WebAssembly builds a schedule only with parse and fromCron, and eval
    // errors come only from building one from its parts.
    eval: () =>
      expect(declarations).toMatch(/export type HronErrorKind = [^;]*"eval"/),
  },
  "error.properties": {
    kind: isErrorProperty("kind", [lexError, parseError, cronError], []),
    message: () => {
      expect(hronErrorDeclaration).toContain("extends Error");
      expect(parseError().message).toBe(
        "until dec 31 has no year: add a starting date, or use an ISO date",
      );
    },
    span: isErrorProperty("span", [lexError, parseError], [cronError]),
    input: isErrorProperty("input", [lexError, parseError], [cronError]),
    suggestion: isErrorProperty("suggestion", [parseError], [lexError, cronError]),
  },
  "error.methods": {
    displayRich: () => {
      expect(hronErrorDeclaration).toContain("displayRich(): string;");
      for (const error of [lexError(), parseError(), cronError()]) {
        expect(typeof error.displayRich()).toBe("string");
      }
    },
  },
  "error.constructors": {
    lex: noErrorConstructors,
    parse: noErrorConstructors,
    eval: noErrorConstructors,
    cron: noErrorConstructors,
  },
};

/** Every name in every list under `schedule` and `error`, so a list added to api.json is checked too. */
function specNames(spec: any): [string, string][] {
  return ["schedule", "error"].flatMap((part) =>
    Object.entries(spec[part])
      .filter(([, entries]) => Array.isArray(entries))
      .flatMap(([list, entries]: [string, any]) =>
        entries.map((entry: any): [string, string] => [
          `${part}.${list}`,
          typeof entry === "string" ? entry : entry.name,
        ]),
      ),
  );
}

const unmapped = (spec: any) =>
  specNames(spec).filter(([list, name]) => !Object.hasOwn(members[list] ?? {}, name));

describe("WASM API conformance", () => {
  for (const [list, name] of specNames(apiSpec)) {
    it(`${list}.${name}`, () => {
      expect(Object.hasOwn(members[list] ?? {}, name), "no entry in members").toBe(true);
      members[list][name]();
    });
  }

  it("maps nothing api.json lacks", () => {
    const names = new Set(specNames(apiSpec).map(([list, name]) => `${list}.${name}`));
    const stale = Object.entries(members)
      .flatMap(([list, entries]) => Object.keys(entries).map((name) => `${list}.${name}`))
      .filter((name) => !names.has(name));
    expect(stale).toEqual([]);
  });

  it("fails on a name added to api.json", () => {
    const spec = structuredClone(apiSpec);
    spec.schedule.instanceMethods.push({ name: "nextWeekFrom" });
    spec.error.kinds.push("timeout");
    spec.schedule.properties = [{ name: "id" }];
    expect(unmapped(spec)).toEqual([
      ["schedule.instanceMethods", "nextWeekFrom"],
      ["schedule.properties", "id"],
      ["error.kinds", "timeout"],
    ]);
  });
});
