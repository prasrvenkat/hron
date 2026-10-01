import type { Temporal } from "@js-temporal/polyfill";
import type { ScheduleData, ScheduleExpr, UntilSpec } from "./ast.js";
import { monthNumber, weekdayNumber } from "./ast.js";
import {
  civil,
  dateIn,
  epochDay,
  firstDateOfUnit,
  matchesDayFilter,
  mod,
  monthTargetDates,
  parseIsoDate,
  type Unit,
  unitIndex,
  yearAndMonth,
  yearTargetDate,
} from "./calendar.js";
import { DAY_MS, MINUTES_PER_HOUR, minuteOfDay, Zone } from "./wall-clock.js";

type ZDT = Temporal.ZonedDateTime;
type IntervalRepeat = Extract<ScheduleExpr, { type: "intervalRepeat" }>;

/** Default anchor for week intervals (spec/README.md, "WeekRepeat epoch alignment"). */
const EPOCH_MONDAY = epochDay(1970, 1, 5);

const EPOCH_DATE = epochDay(1970, 1, 1);

/** spec/README.md, "Supported range". */
const RANGE_START = epochDay(1, 1, 2) * DAY_MS;
const RANGE_END = epochDay(9999, 12, 30) * DAY_MS;

/** No date outside these holds an occurrence in the supported range. */
const FIRST_DATE = epochDay(1, 1, 1);
const LAST_DATE = epochDay(9999, 12, 31);

/**
 * Slack beyond the horizon for the period one behind the first date's, where a
 * search starts, and for a horizon that starts mid-period.
 */
const HORIZON_MARGIN_PERIODS = 2;

/**
 * How many dates past its scheduled date a fixed time can land: one shifted
 * out of a gap before midnight lands on the next date.
 */
const MAX_SHIFT_DAYS = 1;

/**
 * How many dates behind a date that has begun now's wall date can read: from
 * the second pass of a fall-back overlap that crosses midnight, one.
 */
const MAX_OVERLAP_DAYS = 1;

/** Feb 29 can be eight years away, as from 2096-03-01 to 2104-02-29. */
const NAMED_UNTIL_MAX_YEARS = 8;

/**
 * Dates whose instants a Search keeps before it starts over: an iterator's
 * next step revisits only the few dates around its last occurrence.
 */
const RESOLVED_DATES_KEPT = 8;

export function nextFrom(schedule: ScheduleData, now: ZDT): ZDT | null {
  if (!inSupportedRange(floorMs(now))) return null;
  return searchFrom(schedule, floorMs(now), Direction.Forward);
}

export function previousFrom(schedule: ScheduleData, now: ZDT): ZDT | null {
  if (!inSupportedRange(floorMs(now))) return null;
  return searchFrom(schedule, ceilMs(now), Direction.Backward);
}

function searchFrom(
  schedule: ScheduleData,
  now: number,
  direction: Direction,
): ZDT | null {
  const search = new Search(schedule);
  const nearest = search.nearest(now, direction);
  return nearest === null ? null : search.zone.zoned(nearest.instant);
}

/**
 * Defined through the forward search, so the two cannot disagree about what an
 * occurrence is.
 */
export function matches(schedule: ScheduleData, datetime: ZDT): boolean {
  const ms = floorMs(datetime);
  if (!inSupportedRange(ms)) return false;
  const search = new Search(schedule);
  const minute = search.zone.minuteStart(ms);
  // An occurrence never lands before the date it is scheduled on, so one at
  // this minute is scheduled on or before the minute's wall date.
  search.clauses.endOn(search.zone.localDate(minute));
  return search.nearest(minute - 1, Direction.Forward)?.instant === minute;
}

export function* occurrences(
  schedule: ScheduleData,
  from: ZDT,
): Generator<ZDT, void, unknown> {
  const fromMs = floorMs(from);
  if (!inSupportedRange(fromMs)) return;
  const search = new Search(schedule);
  let next = search.nearest(fromMs, Direction.Forward);
  while (next !== null) {
    yield search.zone.zoned(next.instant);
    next = search.nearest(next.instant, Direction.Forward, next.landing);
  }
}

export function nextNFrom(schedule: ScheduleData, now: ZDT, n: number): ZDT[] {
  const results: ZDT[] = [];
  if (n <= 0) return results;
  for (const t of occurrences(schedule, now)) {
    results.push(t);
    if (results.length === n) break;
  }
  return results;
}

export function* between(
  schedule: ScheduleData,
  from: ZDT,
  to: ZDT,
): Generator<ZDT, void, unknown> {
  if (!inSupportedRange(floorMs(to))) return;
  const toNs = to.epochNanoseconds;
  for (const t of occurrences(schedule, from)) {
    if (t.epochNanoseconds > toNs) return;
    yield t;
  }
}

class Direction {
  static readonly Forward = new Direction(1);
  static readonly Backward = new Direction(-1);

  private constructor(readonly sign: 1 | -1) {}

  precedes(a: number, b: number): boolean {
    return this.sign > 0 ? a < b : a > b;
  }
}

interface Occurrence {
  readonly instant: number;
  readonly landing: number;
}

/**
 * Keeps the instants of the dates it resolves, so that iterator steps resolve
 * each date once.
 */
class Search {
  readonly zone: Zone;
  private readonly cadence: Cadence;
  private readonly candidatesInPeriod: (period: number) => Candidate[];
  private readonly times: DailyTimes;
  readonly clauses: Clauses;
  private readonly resolved = new Map<number, number[]>();

  constructor(schedule: ScheduleData) {
    this.zone = new Zone(schedule.timezone ?? "UTC");
    this.cadence = Cadence.of(schedule);
    this.times = dailyTimes(schedule.expr);
    this.clauses = new Clauses(schedule);
    this.candidatesInPeriod = candidatesInPeriod(schedule.expr);
  }

  /**
   * An iterator passes its last occurrence's landing date, now's wall date, as
   * `nowDate` to spare a zone lookup.
   */
  nearest(
    now: number,
    direction: Direction,
    nowDate = this.zone.localDate(now),
  ): Occurrence | null {
    const clamped = this.clauses.clamp(nowDate, direction);
    const firstDate = Math.min(Math.max(clamped, FIRST_DATE), LAST_DATE);
    // A nearest weekday or a DST shift can move an occurrence out of the
    // period it is scheduled in, so the search starts one period back.
    const firstPeriod = this.cadence.periodOf(firstDate) - direction.sign;
    const farthest = this.clauses.farthestExceptDate(direction);
    const reach =
      farthest === null ? firstPeriod : this.cadence.periodOf(farthest);
    const shift = maxShiftDays(this.times);
    let best: Occurrence | null = null;
    search: for (const period of this.cadence.periods(
      firstPeriod,
      reach,
      direction,
    )) {
      if (this.rejectsPeriod(period)) continue;
      for (const candidate of inOrder(
        this.candidatesInPeriod(period),
        direction,
      )) {
        const { date } = candidate;
        const beaten =
          best !== null && !couldBeat(date, best.landing, direction, shift);
        if (beaten || this.clauses.endsSearch(date, direction)) break search;
        if (
          isBehind(date, nowDate, direction, shift) ||
          !this.clauses.allows(candidate)
        ) {
          continue;
        }
        const instant = this.nearestOnDate(date, now, direction);
        if (
          instant !== null &&
          (best === null || direction.precedes(instant, best.instant))
        ) {
          best = { instant, landing: this.zone.landingDate(date, instant) };
        }
      }
    }
    return best !== null && inSupportedRange(best.instant) ? best : null;
  }

  /**
   * A day or month period's candidates all target its own month, so one whose
   * month `during` rejects holds nothing.
   */
  private rejectsPeriod(period: number): boolean {
    const month = this.cadence.monthOf(period);
    return month !== null && !this.clauses.allowsMonth(month);
  }

  private nearestOnDate(
    date: number,
    now: number,
    direction: Direction,
  ): number | null {
    const instants = this.instantsOn(date);
    if (direction === Direction.Forward) {
      const after = countLeading(instants, (t) => t <= now);
      return after < instants.length ? instants[after] : null;
    }
    const before = countLeading(instants, (t) => t < now);
    return before > 0 ? instants[before - 1] : null;
  }

  private instantsOn(date: number): number[] {
    let instants = this.resolved.get(date);
    if (instants === undefined) {
      if (this.resolved.size >= RESOLVED_DATES_KEPT) this.resolved.clear();
      instants = this.resolve(date);
      this.resolved.set(date, instants);
    }
    return instants;
  }

  private resolve(date: number): number[] {
    const { times, zone } = this;
    const instants: number[] = [];
    if (times.kind === "slots") {
      // Slots resolve in wall-clock order.
      for (const minute of times.minutes) {
        const instant = zone.slotOn(date, minute);
        if (instant !== null) instants.push(instant);
      }
      return instants;
    }
    for (const minute of times.minutes) {
      instants.push(zone.fixedTimeOn(date, minute));
    }
    // A time shifted out of a gap can land after a later wall time.
    return instants.sort((a, b) => a - b);
  }
}

function inOrder<T>(items: readonly T[], direction: Direction): readonly T[] {
  return direction === Direction.Forward ? items : items.slice().reverse();
}

/**
 * An occurrence lands from its scheduled date to `shift` dates after it, on a
 * first pass, and first passes keep wall-clock order.
 */
function couldBeat(
  date: number,
  landing: number,
  direction: Direction,
  shift: number,
): boolean {
  return direction === Direction.Forward
    ? date <= landing
    : landing - date <= shift;
}

function isBehind(
  date: number,
  nowDate: number,
  direction: Direction,
  shift: number,
): boolean {
  return direction === Direction.Forward
    ? nowDate - date > shift
    : date - nowDate > MAX_OVERLAP_DAYS;
}

/** `test` must hold for a prefix of `items`. */
function countLeading<T>(
  items: readonly T[],
  test: (item: T) => boolean,
): number {
  let lo = 0;
  let hi = items.length;
  while (lo < hi) {
    const mid = (lo + hi) >> 1;
    if (test(items[mid])) lo = mid + 1;
    else hi = mid;
  }
  return lo;
}

function inSupportedRange(ms: number): boolean {
  return ms >= RANGE_START && ms < RANGE_END;
}

const NS_PER_MS = 1_000_000n;

// Occurrences fall on whole milliseconds, so one is after `t` exactly when it
// is after floorMs(t), and before `t` exactly when it is before ceilMs(t).

function floorMs(t: ZDT): number {
  const ns = t.epochNanoseconds;
  const ms = ns / NS_PER_MS;
  return Number(ns % NS_PER_MS < 0n ? ms - 1n : ms);
}

function ceilMs(t: ZDT): number {
  const ns = t.epochNanoseconds;
  const ms = ns / NS_PER_MS;
  return Number(ns % NS_PER_MS > 0n ? ms + 1n : ms);
}

type DailyTimes =
  /** Fixed times, each shifted out of a gap. */
  | { kind: "fixed"; minutes: number[] }
  /** Interval slots, each skipped in a gap. */
  | { kind: "slots"; minutes: number[] };

/** A gap pushes a fixed time forward, and skips a slot. */
function maxShiftDays(times: DailyTimes): number {
  return times.kind === "fixed" ? MAX_SHIFT_DAYS : 0;
}

function dailyTimes(expr: ScheduleExpr): DailyTimes {
  if (expr.type === "intervalRepeat") {
    return { kind: "slots", minutes: intervalSlots(expr) };
  }
  return { kind: "fixed", minutes: expr.times.map(minuteOfDay) };
}

function intervalSlots({ interval, unit, from, to }: IntervalRepeat): number[] {
  const step = unit === "min" ? interval : interval * MINUTES_PER_HOUR;
  const last = minuteOfDay(to);
  const slots: number[] = [];
  for (let minute = minuteOfDay(from); minute <= last; minute += step) {
    slots.push(minute);
  }
  return slots;
}

/**
 * `during` applies to a candidate's target month; `except`, `until` and
 * `starting` to its date (spec/README.md, "Nearest weekday and `during`", "The
 * `starting` clause").
 */
class Clauses {
  private readonly during: number[];
  private readonly exceptMonthDays: { month: number; day: number }[] = [];
  private readonly exceptDates: number[] = [];
  private readonly earliestExceptDate: number | null;
  private readonly latestExceptDate: number | null;
  private until: number | null;
  private readonly starting: number | null;

  constructor(schedule: ScheduleData) {
    this.during = schedule.during.map(monthNumber);
    for (const exception of schedule.except) {
      if (exception.type === "named") {
        const month = monthNumber(exception.month);
        this.exceptMonthDays.push({ month, day: exception.day });
      } else {
        this.exceptDates.push(parseIsoDate(exception.date));
      }
    }
    const any = this.exceptDates.length > 0;
    this.earliestExceptDate = any ? Math.min(...this.exceptDates) : null;
    this.latestExceptDate = any ? Math.max(...this.exceptDates) : null;
    this.starting =
      schedule.anchor === null ? null : parseIsoDate(schedule.anchor);
    this.until =
      schedule.until === null
        ? null
        : resolveUntil(schedule.until, this.starting ?? EPOCH_DATE);
  }

  allows({ date, targetMonth }: Candidate): boolean {
    return (
      this.allowsMonth(targetMonth) &&
      !this.exceptDates.includes(date) &&
      !this.isExceptMonthDay(date) &&
      (this.until === null || date <= this.until) &&
      (this.starting === null || date >= this.starting)
    );
  }

  allowsMonth(month: number): boolean {
    return this.during.length === 0 || this.during.includes(month);
  }

  endOn(date: number): void {
    this.until = this.until === null ? date : Math.min(this.until, date);
  }

  /**
   * The one-off except date farthest along `direction`: the calendar repeats
   * only beyond it (spec/README.md, "Search horizon").
   */
  farthestExceptDate(direction: Direction): number | null {
    return direction === Direction.Forward
      ? this.latestExceptDate
      : this.earliestExceptDate;
  }

  clamp(date: number, direction: Direction): number {
    if (direction === Direction.Forward) {
      return this.starting === null ? date : Math.max(date, this.starting);
    }
    return this.until === null ? date : Math.min(date, this.until);
  }

  endsSearch(date: number, direction: Direction): boolean {
    if (direction === Direction.Forward) {
      return this.until !== null && date > this.until;
    }
    return this.starting !== null && date < this.starting;
  }

  private isExceptMonthDay(date: number): boolean {
    if (this.exceptMonthDays.length === 0) return false;
    const { month, day } = civil(date);
    return this.exceptMonthDays.some((e) => e.month === month && e.day === day);
  }
}

/**
 * spec/README.md, "Named `until`". The parser requires `starting` for a named
 * date; schedule data built otherwise counts from the epoch, as the reference
 * evaluator does.
 */
function resolveUntil(until: UntilSpec, starting: number): number | null {
  if (until.type === "iso") return parseIsoDate(until.date);
  const month = monthNumber(until.month);
  const year = civil(starting).year;
  for (let k = 0; k <= NAMED_UNTIL_MAX_YEARS; k++) {
    const date = dateIn(year + k, month, until.day);
    if (date !== null && date >= starting) return date;
  }
  return null;
}

/** Units in 400 years, after which the proleptic Gregorian calendar repeats. */
const PER_400_YEARS: Record<Unit, number> = {
  day: 146_097,
  week: 20_871,
  month: 4_800,
  year: 400,
};

class Cadence {
  private readonly earliest: number;
  private readonly latest: number;

  private constructor(
    private readonly unit: Unit,
    private readonly origin: number,
    private readonly interval: number,
    private readonly single = false,
  ) {
    // A nearest weekday can move a candidate into the calendar from the
    // period on either side of it.
    this.earliest = unitIndex(unit, FIRST_DATE) - 1;
    this.latest = unitIndex(unit, LAST_DATE) + 1;
  }

  static of({ expr, anchor }: ScheduleData): Cadence {
    if (expr.type === "singleDate" && expr.date.type === "iso") {
      return new Cadence("day", parseIsoDate(expr.date.date), 1, true);
    }
    const [unit, interval] = repetition(expr);
    const defaultAnchor = unit === "week" ? EPOCH_MONDAY : EPOCH_DATE;
    const start = anchor === null ? defaultAnchor : parseIsoDate(anchor);
    return new Cadence(unit, unitIndex(unit, start), interval);
  }

  periodOf(date: number): number {
    return unitIndex(this.unit, date);
  }

  /**
   * The month of a day or month period, which all its candidates target; null
   * for a week or year, whose candidates need not fall in its first month.
   */
  monthOf(period: number): number | null {
    switch (this.unit) {
      case "day":
        return civil(period).month;
      case "month":
        return yearAndMonth(period).month;
      default:
        return null;
    }
  }

  /**
   * Through one search horizon beyond whichever of `first` and `reach` is
   * farther along `direction` (spec/README.md, "Search horizon").
   */
  *periods(
    first: number,
    reach: number,
    direction: Direction,
  ): Generator<number> {
    let from = this.origin;
    let count = 1;
    if (!this.single) {
      from = this.align(first, direction);
      const beyond = direction.sign * (this.align(reach, direction) - from);
      count =
        this.horizonPeriods() +
        HORIZON_MARGIN_PERIODS +
        Math.max(0, beyond) / this.interval;
    }
    const step = direction.sign * this.interval;
    const [start, end] =
      direction === Direction.Forward
        ? [this.earliest, this.latest]
        : [this.latest, this.earliest];
    for (let i = 0; i < count; i++) {
      const period = from + i * step;
      // The period a search starts from, behind the first date's, can lie
      // before the calendar's start in `direction`.
      if (direction.precedes(period, start)) continue;
      if (direction.precedes(end, period)) return;
      yield period;
    }
  }

  private align(period: number, direction: Direction): number {
    return direction === Direction.Forward
      ? period + mod(this.origin - period, this.interval)
      : period - mod(period - this.origin, this.interval);
  }

  /**
   * Aligned periods in lcm(400 years, interval units), after which both the
   * calendar and the alignment repeat.
   */
  private horizonPeriods(): number {
    const cycle = PER_400_YEARS[this.unit];
    return cycle / gcd(cycle, this.interval);
  }
}

function repetition(expr: ScheduleExpr): [Unit, number] {
  switch (expr.type) {
    case "intervalRepeat":
      return ["day", 1];
    case "dayRepeat":
      return ["day", expr.interval];
    case "weekRepeat":
      return ["week", expr.interval];
    case "monthRepeat":
      return ["month", expr.interval];
    case "yearRepeat":
      return ["year", expr.interval];
    case "singleDate":
      return ["year", 1];
  }
}

/**
 * `targetMonth` differs from the month of `date` only when a directional
 * nearest weekday crosses into the adjacent month.
 */
interface Candidate {
  readonly date: number;
  readonly targetMonth: number;
}

function candidatesInPeriod(
  expr: ScheduleExpr,
): (period: number) => Candidate[] {
  switch (expr.type) {
    case "intervalRepeat": {
      const { dayFilter } = expr;
      return (date) =>
        dayFilter === null || matchesDayFilter(date, dayFilter)
          ? [candidateOn(date)]
          : [];
    }
    case "dayRepeat":
      return (date) =>
        matchesDayFilter(date, expr.days) ? [candidateOn(date)] : [];
    case "weekRepeat": {
      const offsets = expr.days.map((day) => weekdayNumber(day) - 1);
      offsets.sort((a, b) => a - b);
      return (week) => {
        const monday = firstDateOfUnit("week", week);
        return offsets.map((offset) => candidateOn(monday + offset));
      };
    }
    case "monthRepeat":
      return (index) => {
        const { year, month } = yearAndMonth(index);
        return monthTargetDates(year, month, expr.target).map((date) =>
          candidateOn(date, month),
        );
      };
    case "yearRepeat": {
      const { target } = expr;
      const month = monthNumber(target.month);
      return (year) => candidatesOn(yearTargetDate(year, target), month);
    }
    case "singleDate": {
      const { date } = expr;
      if (date.type === "iso") return (iso) => [candidateOn(iso)];
      const month = monthNumber(date.month);
      return (year) => candidatesOn(dateIn(year, month, date.day), month);
    }
  }
}

function candidateOn(date: number, targetMonth = civil(date).month): Candidate {
  return { date, targetMonth };
}

function candidatesOn(date: number | null, targetMonth: number): Candidate[] {
  return date === null ? [] : [{ date, targetMonth }];
}

function gcd(a: number, b: number): number {
  return b === 0 ? a : gcd(b, a % b);
}
