import type { Temporal } from "@js-temporal/polyfill";
import type { ScheduleData, ScheduleExpr } from "./ast.js";
import { fromCron, toCron } from "./cron.js";
import { display } from "./display.js";
import {
  between,
  matches,
  nextFrom,
  nextNFrom,
  occurrences,
  previousFrom,
} from "./eval.js";
import { parse } from "./parser.js";

export class Schedule {
  private data: ScheduleData;

  private constructor(data: ScheduleData) {
    this.data = data;
  }

  /** Parse an hron expression string. Throws `HronError` if it is invalid. */
  static parse(input: string): Schedule {
    return new Schedule(parse(input));
  }

  /** Convert a 5-field cron expression to a Schedule. Throws `HronError` if it is invalid. */
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

  /** Compute the next occurrence strictly after `now`, or null if there is none. */
  nextFrom(now: Temporal.ZonedDateTime): Temporal.ZonedDateTime | null {
    return nextFrom(this.data, now);
  }

  /** Compute up to `n` occurrences strictly after `now`; fewer if the schedule ends first. */
  nextNFrom(now: Temporal.ZonedDateTime, n: number): Temporal.ZonedDateTime[] {
    return nextNFrom(this.data, now, n);
  }

  /** Compute the most recent occurrence strictly before `now`, or null if there is none. */
  previousFrom(now: Temporal.ZonedDateTime): Temporal.ZonedDateTime | null {
    return previousFrom(this.data, now);
  }

  /** True when the minute containing `datetime` is an occurrence (seconds are ignored). */
  matches(datetime: Temporal.ZonedDateTime): boolean {
    return matches(this.data, datetime);
  }

  /**
   * Lazily yields occurrences strictly after `from`. Unbounded for repeating
   * schedules unless an `until` clause ends them.
   */
  *occurrences(
    from: Temporal.ZonedDateTime,
  ): Generator<Temporal.ZonedDateTime, void, unknown> {
    yield* occurrences(this.data, from);
  }

  /** Yields occurrences where `from < occurrence <= to`. */
  *between(
    from: Temporal.ZonedDateTime,
    to: Temporal.ZonedDateTime,
  ): Generator<Temporal.ZonedDateTime, void, unknown> {
    yield* between(this.data, from, to);
  }

  /** Convert this schedule to a 5-field cron expression. Throws `HronError` if it has no cron equivalent. */
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
export { HronError } from "./error.js";
