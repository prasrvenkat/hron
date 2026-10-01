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

type Timestamp = Temporal.ZonedDateTime | Temporal.Instant;

/**
 * Every timestamp argument must be a `Temporal.ZonedDateTime` or a
 * `Temporal.Instant`, native or polyfill, or the method throws a `TypeError`
 * when called; only its instant matters. Every returned timestamp is a
 * `Temporal.ZonedDateTime` in the schedule's timezone, or UTC when it has none.
 */
export class Schedule {
  private data: ScheduleData;

  private constructor(data: ScheduleData) {
    this.data = data;
  }

  /** Parse an hron expression string. Throws `HronError` if it is invalid. */
  static parse(input: string): Schedule {
    return new Schedule(parse(input));
  }

  /**
   * Convert a 5-field cron expression to a Schedule that fires at the same times.
   * Throws a `cron` `HronError` when the input is not valid cron or has no exact hron equivalent.
   */
  static fromCron(cronExpr: string): Schedule {
    return new Schedule(fromCron(cronExpr));
  }

  /** False, rather than throwing, for anything `parse` rejects. */
  static validate(input: string): boolean {
    try {
      parse(input);
      return true;
    } catch {
      return false;
    }
  }

  /** Compute the next occurrence strictly after `now`, or null if there is none. */
  nextFrom(now: Timestamp): Temporal.ZonedDateTime | null {
    return nextFrom(this.data, timestamp(now, "now"));
  }

  /**
   * Up to `n` occurrences strictly after `now`; fewer if the schedule ends
   * first, and none when `n <= 0`. Throws a `TypeError` when `n` is not a
   * number and a `RangeError` when it is not an integer.
   */
  nextNFrom(now: Timestamp, n: number): Temporal.ZonedDateTime[] {
    const from = timestamp(now, "now");
    if (typeof n !== "number") throw new TypeError("n must be a number");
    if (!Number.isInteger(n)) throw new RangeError("n must be an integer");
    return nextNFrom(this.data, from, n);
  }

  /** Compute the most recent occurrence strictly before `now`, or null if there is none. */
  previousFrom(now: Timestamp): Temporal.ZonedDateTime | null {
    return previousFrom(this.data, timestamp(now, "now"));
  }

  /** True when the minute containing `datetime` is an occurrence (seconds are ignored). */
  matches(datetime: Timestamp): boolean {
    return matches(this.data, timestamp(datetime, "datetime"));
  }

  /**
   * Lazily yields occurrences strictly after `from`. Unbounded for repeating
   * schedules unless an `until` clause ends them.
   */
  occurrences(
    from: Timestamp,
  ): Generator<Temporal.ZonedDateTime, void, unknown> {
    return occurrences(this.data, timestamp(from, "from"));
  }

  /** Yields occurrences where `from < occurrence <= to`. */
  between(
    from: Timestamp,
    to: Timestamp,
  ): Generator<Temporal.ZonedDateTime, void, unknown> {
    return between(this.data, timestamp(from, "from"), timestamp(to, "to"));
  }

  /**
   * Convert this schedule to a 5-field cron expression that fires at the same times.
   * Throws a `cron` `HronError` when no cron does. The schedule's timezone is not part of the cron.
   */
  toCron(): string {
    return toCron(this.data);
  }

  /** Render as canonical string (roundtrip-safe). */
  toString(): string {
    return display(this.data);
  }

  /** The IANA timezone name with its canonical capitalization, if specified. */
  get timezone(): string | null {
    return this.data.timezone;
  }

  get expression(): ScheduleExpr {
    return this.data.expr;
  }
}

const TIMESTAMP_TAGS = [
  "[object Temporal.ZonedDateTime]",
  "[object Temporal.Instant]",
];

/**
 * Checked by its tag rather than `instanceof`, which a native Temporal object
 * fails against the polyfill's class.
 */
function timestamp(value: unknown, name: string): Timestamp {
  if (!TIMESTAMP_TAGS.includes(Object.prototype.toString.call(value))) {
    throw new TypeError(
      `${name} must be a Temporal.ZonedDateTime or Temporal.Instant`,
    );
  }
  return value as Timestamp;
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
