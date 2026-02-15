// hron-js — Public API

import type { Temporal } from "@js-temporal/polyfill";
import type { ScheduleData, ScheduleExpr } from "./ast.js";
import { fromCron, toCron } from "./cron.js";
import { display } from "./display.js";
import { between, matches, nextFrom, nextNFrom, occurrences, previousFrom } from "./eval.js";
import { parse } from "./parser.js";

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
  nextNFrom(now: Temporal.ZonedDateTime, n: number): Temporal.ZonedDateTime[] {
    return nextNFrom(this.data, now, n);
  }

  /** Compute the most recent occurrence strictly before `now`. */
  previousFrom(now: Temporal.ZonedDateTime): Temporal.ZonedDateTime | null {
    return previousFrom(this.data, now);
  }

  /** Check if a datetime matches this schedule. */
  matches(datetime: Temporal.ZonedDateTime): boolean {
    return matches(this.data, datetime);
  }

  /**
   * Returns a lazy iterator of occurrences starting after `from`.
   * The iterator is unbounded for repeating schedules (will iterate forever unless limited),
   * but respects the `until` clause if specified in the schedule.
   */
  *occurrences(
    from: Temporal.ZonedDateTime,
  ): Generator<Temporal.ZonedDateTime, void, unknown> {
    yield* occurrences(this.data, from);
  }

  /**
   * Returns a bounded iterator of occurrences where `from < occurrence <= to`.
   * The iterator yields occurrences strictly after `from` and up to and including `to`.
   */
  *between(
    from: Temporal.ZonedDateTime,
    to: Temporal.ZonedDateTime,
  ): Generator<Temporal.ZonedDateTime, void, unknown> {
    yield* between(this.data, from, to);
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

export { Temporal } from "@js-temporal/polyfill";
export type {
  DateSpec,
  DayFilter,
  DayOfMonthSpec,
  Exception,
  IntervalUnit,
  MonthName,
  MonthTarget,
  OrdinalPosition,
  ScheduleData,
  ScheduleExpr,
  TimeOfDay,
  UntilSpec,
  Weekday,
  YearTarget,
} from "./ast.js";
export type { HronErrorKind, Span } from "./error.js";
// Re-exports
export { HronError } from "./error.js";
