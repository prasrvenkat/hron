import type { Temporal } from "@js-temporal/polyfill";
import type {
  Exception,
  MonthName,
  ScheduleData,
  ScheduleExpr,
  UntilSpec,
} from "./ast.js";
import { fromCron, toCron } from "./cron.js";
import { display } from "./display.js";
import { HronError, text } from "./error.js";
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

/** `private` binds only the compiler, so JavaScript could otherwise call `new Schedule(parts)`. */
const BUILDER = Symbol("Schedule builder");

/**
 * Every timestamp argument must be a `Temporal.ZonedDateTime` or a
 * `Temporal.Instant`, native or polyfill, or the method throws a `TypeError`
 * when called; only its instant matters. Every returned timestamp is a
 * `Temporal.ZonedDateTime` in the schedule's timezone, or UTC when it has none.
 *
 * Built only through `Schedule.parse` and `Schedule.fromCron`; a schedule
 * cannot change afterwards.
 */
export class Schedule {
  readonly #data: ScheduleData;

  private constructor(builder: symbol, data: ScheduleData) {
    if (builder !== BUILDER) {
      throw new TypeError(
        "a Schedule is built only by Schedule.parse or Schedule.fromCron",
      );
    }
    this.#data = deepFreeze(data);
  }

  /**
   * Parse an hron expression string. Throws `HronError` if it is invalid, and
   * a `TypeError` if `input` is not a string.
   */
  static parse(input: string): Schedule {
    return new Schedule(BUILDER, parse(text(input, "input")));
  }

  /**
   * Convert a 5-field cron expression to a Schedule that fires at the same times.
   * Throws a `cron` `HronError` when the input is not valid cron or has no exact hron equivalent,
   * and a `TypeError` if `cronExpr` is not a string.
   */
  static fromCron(cronExpr: string): Schedule {
    return new Schedule(BUILDER, fromCron(text(cronExpr, "cronExpr")));
  }

  /**
   * False, rather than throwing, for anything `parse` rejects. Throws a
   * `TypeError` if `input` is not a string.
   */
  static validate(input: string): boolean {
    const checked = text(input, "input");
    try {
      parse(checked);
      return true;
    } catch (error) {
      if (error instanceof HronError) return false;
      throw error;
    }
  }

  /** Compute the next occurrence strictly after `now`, or null if there is none. */
  nextFrom(now: Timestamp): Temporal.ZonedDateTime | null {
    return nextFrom(this.#data, timestamp(now, "now"));
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
    return nextNFrom(this.#data, from, n);
  }

  /** Compute the most recent occurrence strictly before `now`, or null if there is none. */
  previousFrom(now: Timestamp): Temporal.ZonedDateTime | null {
    return previousFrom(this.#data, timestamp(now, "now"));
  }

  /** True when the minute containing `datetime` is an occurrence (seconds are ignored). */
  matches(datetime: Timestamp): boolean {
    return matches(this.#data, timestamp(datetime, "datetime"));
  }

  /**
   * Lazily yields occurrences strictly after `from`. Unbounded for repeating
   * schedules unless an `until` clause ends them.
   */
  occurrences(
    from: Timestamp,
  ): Generator<Temporal.ZonedDateTime, void, unknown> {
    return occurrences(this.#data, timestamp(from, "from"));
  }

  /** Yields occurrences where `from < occurrence <= to`. */
  between(
    from: Timestamp,
    to: Timestamp,
  ): Generator<Temporal.ZonedDateTime, void, unknown> {
    return between(this.#data, timestamp(from, "from"), timestamp(to, "to"));
  }

  /**
   * Convert this schedule to a 5-field cron expression that fires at the same times.
   * Throws a `cron` `HronError` when no cron does. The schedule's timezone is not part of the cron.
   */
  toCron(): string {
    return toCron(this.#data);
  }

  /** Render as canonical string (roundtrip-safe). */
  toString(): string {
    return display(this.#data);
  }

  /** The IANA timezone name with its canonical capitalization, if specified. */
  get timezone(): string | null {
    return this.#data.timezone;
  }

  /** The schedule's expression, frozen: a write to it throws in strict mode. */
  get expression(): ScheduleExpr {
    return this.#data.expression;
  }

  /** The except dates, frozen; empty without an except clause. */
  get except(): readonly Exception[] {
    return this.#data.except;
  }

  /** The until date, frozen, or null without an until clause. */
  get until(): UntilSpec | null {
    return this.#data.until;
  }

  /** The starting date as `YYYY-MM-DD`, or null without a starting clause. */
  get starting(): string | null {
    return this.#data.starting;
  }

  /** The during months, frozen; empty without a during clause. */
  get during(): readonly MonthName[] {
    return this.#data.during;
  }

  /**
   * True when `other` is a schedule with equal parts (spec/README.md,
   * "Equality"); false for anything else, `null` and `undefined` included.
   */
  equals(other: unknown): boolean {
    return (
      typeof other === "object" &&
      other !== null &&
      #data in other &&
      sameParts(this.#data, (other as Schedule).#data)
    );
  }
}

function sameParts(a: unknown, b: unknown): boolean {
  if (a === b) return true;
  if (typeof a !== "object" || typeof b !== "object") return false;
  if (a === null || b === null) return false;
  const keys = Object.keys(a);
  return (
    keys.length === Object.keys(b).length &&
    keys.every(
      (key) =>
        Object.hasOwn(b, key) &&
        sameParts(
          (a as Record<string, unknown>)[key],
          (b as Record<string, unknown>)[key],
        ),
    )
  );
}

function deepFreeze<T>(value: T): T {
  if (typeof value === "object" && value !== null) {
    for (const field of Object.values(value)) deepFreeze(field);
    Object.freeze(value);
  }
  return value;
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
  NearestDirection,
  OrdinalPosition,
  ScheduleExpr,
  TimeOfDay,
  UntilSpec,
  Weekday,
  YearTarget,
} from "./ast.js";
export type { HronErrorKind, Span } from "./error.js";
export { HronError } from "./error.js";
