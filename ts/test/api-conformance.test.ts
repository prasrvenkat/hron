// API conformance test — verifies TS exposes all methods from spec/api.json.

import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";
import { Schedule } from "../src/index.js";

const apiSpec = JSON.parse(
  readFileSync(resolve(__dirname, "../../spec/api.json"), "utf-8"),
);

describe("API conformance", () => {
  describe("static methods", () => {
    for (const method of apiSpec.schedule.staticMethods) {
      it(`static method: ${method.name}`, () => {
        // biome-ignore lint/suspicious/noExplicitAny: dynamic spec-driven check
        expect(typeof (Schedule as any)[method.name]).toBe("function");
      });
    }
  });

  describe("instance methods", () => {
    const instance = Schedule.parse("every day at 09:00");

    for (const method of apiSpec.schedule.instanceMethods) {
      it(`instance method: ${method.name}`, () => {
        // biome-ignore lint/suspicious/noExplicitAny: dynamic spec-driven check
        expect(typeof (instance as any)[method.name]).toBe("function");
      });
    }
  });

  describe("getters", () => {
    const instance = Schedule.parse("every day at 09:00 in America/New_York");

    for (const getter of apiSpec.schedule.getters) {
      it(`getter: ${getter.name}`, () => {
        expect(getter.name in instance).toBe(true);
      });
    }
  });
});
