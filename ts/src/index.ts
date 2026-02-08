// hron-js — Public API

import { Temporal } from "@js-temporal/polyfill";
import type { ScheduleData, ScheduleExpr } from "./ast.js";
import { parse } from "./parser.js";
import { display } from "./display.js";
import { nextFrom, nextNFrom, matches } from "./eval.js";
import { toCron, fromCron } from "./cron.js";
import { HronError } from "./error.js";

export class Schedule {
  private data: ScheduleData;

  private constructor(data: ScheduleData) {
    this.data = data;
  }

  /** Parse an hron expression string. */
  static parse(input: string): Schedule {
    return new Schedule(parse(input));
  }

  /** Convert a 5-field cron expression to a Schedule. */
  static fromCron(cronExpr: string): Schedule {
    return new Schedule(fromCron(cronExpr));
  }

  /** Check if an input string is a valid hron expression. */
  static validate(input: string): boolean {
    try {
      parse(input);
      return true;
    } catch {
      return false;
    }
  }

  /** Compute the next occurrence after `now`. */
  nextFrom(now: Temporal.ZonedDateTime): Temporal.ZonedDateTime | null {
    return nextFrom(this.data, now);
  }

  /** Compute the next `n` occurrences after `now`. */
  nextNFrom(
    now: Temporal.ZonedDateTime,
    n: number,
  ): Temporal.ZonedDateTime[] {
    return nextNFrom(this.data, now, n);
  }

  /** Check if a datetime matches this schedule. */
  matches(datetime: Temporal.ZonedDateTime): boolean {
    return matches(this.data, datetime);
  }

  /** Convert this schedule to a 5-field cron expression. */
  toCron(): string {
    return toCron(this.data);
  }

  /** Render as canonical string (roundtrip-safe). */
  toString(): string {
    return display(this.data);
  }

  /** Get the timezone, if specified. */
  get timezone(): string | null {
    return this.data.timezone;
  }

  /** Get the underlying schedule expression. */
  get expression(): ScheduleExpr {
    return this.data.expr;
  }
}

// Re-exports
export { HronError } from "./error.js";
export type { Span, HronErrorKind } from "./error.js";
export type {
  ScheduleData,
  ScheduleExpr,
  TimeOfDay,
  DayFilter,
  DayOfMonthSpec,
  MonthTarget,
  YearTarget,
  DateSpec,
  Exception,
  UntilSpec,
  Weekday,
  MonthName,
  IntervalUnit,
  OrdinalPosition,
} from "./ast.js";
export { Temporal } from "@js-temporal/polyfill";
