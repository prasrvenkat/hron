import { Temporal } from "@js-temporal/polyfill";
import type {
  DayFilter,
  MonthTarget,
  NearestDirection,
  OrdinalPosition,
  ScheduleData,
  ScheduleExpr,
  UntilSpec,
  Weekday,
  YearTarget,
} from "./ast.js";
import {
  expandMonthTarget,
  monthNumber,
  ordinalToN,
  weekdayNumber,
} from "./ast.js";

type ZDT = Temporal.ZonedDateTime;
type Direction = 1 | -1;
type IntervalRepeat = Extract<ScheduleExpr, { type: "intervalRepeat" }>;

// Dates are whole days since 1970-01-01 (proleptic Gregorian). A search can
// scan a full 400-year calendar cycle of periods (spec/README.md, "Search
// horizon"), and plain arithmetic keeps that fast where the Temporal polyfill
// costs microseconds per date.

function mod(a: number, b: number): number {
  return ((a % b) + b) % b;
}

function gcd(a: number, b: number): number {
  return b === 0 ? a : gcd(b, a % b);
}

function isLeapYear(year: number): boolean {
  return (year % 4 === 0 && year % 100 !== 0) || year % 400 === 0;
}

function daysInMonth(year: number, month: number): number {
  if (month === 2) return isLeapYear(year) ? 29 : 28;
  return [4, 6, 9, 11].includes(month) ? 30 : 31;
}

// days_from_civil and civil_from_days from
// https://howardhinnant.github.io/date_algorithms.html
function epochDay(year: number, month: number, day: number): number {
  const y = month <= 2 ? year - 1 : year;
  const era = Math.floor(y / 400);
  const yearOfEra = y - era * 400;
  const dayOfYear = Math.floor((153 * mod(month + 9, 12) + 2) / 5) + day - 1;
  const dayOfEra =
    yearOfEra * 365 +
    Math.floor(yearOfEra / 4) -
    Math.floor(yearOfEra / 100) +
    dayOfYear;
  return era * 146097 + dayOfEra - 719468;
}

function civil(epochDay: number): { year: number; month: number; day: number } {
  const z = epochDay + 719468;
  const era = Math.floor(z / 146097);
  const dayOfEra = z - era * 146097;
  const yearOfEra = Math.floor(
    (dayOfEra -
      Math.floor(dayOfEra / 1460) +
      Math.floor(dayOfEra / 36524) -
      Math.floor(dayOfEra / 146096)) /
      365,
  );
  const dayOfYear =
    dayOfEra -
    (365 * yearOfEra + Math.floor(yearOfEra / 4) - Math.floor(yearOfEra / 100));
  const mp = Math.floor((5 * dayOfYear + 2) / 153);
  const month = mp < 10 ? mp + 3 : mp - 9;
  return {
    year: yearOfEra + era * 400 + (month <= 2 ? 1 : 0),
    month,
    day: dayOfYear - Math.floor((153 * mp + 2) / 5) + 1,
  };
}

/** ISO day of week: Monday=1, Sunday=7. */
function weekdayOf(day: number): number {
  return mod(day + 3, 7) + 1;
}

function dayOf(date: { year: number; month: number; day: number }): number {
  return epochDay(date.year, date.month, date.day);
}

function isoDay(iso: string): number {
  const [year, month, day] = iso.split("-").map(Number);
  return epochDay(year, month, day);
}

function matchesDayFilter(day: number, filter: DayFilter): boolean {
  const dow = weekdayOf(day);
  switch (filter.type) {
    case "every":
      return true;
    case "weekday":
      return dow <= 5;
    case "weekend":
      return dow >= 6;
    case "days":
      return filter.days.some((d) => weekdayNumber(d) === dow);
  }
}

function lastDayOfMonth(year: number, month: number): number {
  return epochDay(year, month, daysInMonth(year, month));
}

function lastWeekdayOfMonth(year: number, month: number): number {
  const last = lastDayOfMonth(year, month);
  return last - Math.max(0, weekdayOf(last) - 5);
}

function ordinalWeekday(
  year: number,
  month: number,
  ordinal: OrdinalPosition,
  weekday: Weekday,
): number | null {
  const target = weekdayNumber(weekday);
  if (ordinal === "last") {
    const last = lastDayOfMonth(year, month);
    return last - mod(weekdayOf(last) - target, 7);
  }
  const first = epochDay(year, month, 1);
  const offset =
    mod(target - weekdayOf(first), 7) + 7 * (ordinalToN(ordinal) - 1);
  return offset < daysInMonth(year, month) ? first + offset : null;
}

/**
 * spec/README.md, "Nearest weekday and `during`". Null when the month has no
 * such day.
 */
function nearestWeekday(
  year: number,
  month: number,
  dayOfMonth: number,
  direction: NearestDirection | null,
): number | null {
  const length = daysInMonth(year, month);
  if (dayOfMonth > length) return null;
  const day = epochDay(year, month, dayOfMonth);
  const dow = weekdayOf(day);
  if (dow <= 5) return day;
  const saturday = dow === 6;
  if (direction === "next") return day + (saturday ? 2 : 1);
  if (direction === "previous") return day - (saturday ? 1 : 2);
  if (saturday) return dayOfMonth === 1 ? day + 2 : day - 1;
  return dayOfMonth === length ? day - 2 : day + 1;
}

function monthTargetDays(
  year: number,
  month: number,
  target: MonthTarget,
): number[] {
  switch (target.type) {
    case "days": {
      const length = daysInMonth(year, month);
      const days = [...new Set(expandMonthTarget(target))]
        .filter((d) => d <= length)
        .sort((a, b) => a - b);
      return days.map((d) => epochDay(year, month, d));
    }
    case "lastDay":
      return [lastDayOfMonth(year, month)];
    case "lastWeekday":
      return [lastWeekdayOfMonth(year, month)];
    case "ordinalWeekday":
      return orNone(
        ordinalWeekday(year, month, target.ordinal, target.weekday),
      );
    case "nearestWeekday":
      return orNone(nearestWeekday(year, month, target.day, target.direction));
  }
}

function yearTargetDay(year: number, target: YearTarget): number | null {
  const month = monthNumber(target.month);
  switch (target.type) {
    case "date":
    case "dayOfMonth":
      return target.day <= daysInMonth(year, month)
        ? epochDay(year, month, target.day)
        : null;
    case "ordinalWeekday":
      return ordinalWeekday(year, month, target.ordinal, target.weekday);
    case "lastWeekday":
      return lastWeekdayOfMonth(year, month);
  }
}

function orNone(day: number | null): number[] {
  return day === null ? [] : [day];
}

/**
 * A calendar unit that intervals count in. `cycle` is how many units the
 * Gregorian calendar takes to repeat (400 years), and `epoch` is the day whose
 * period is the default interval anchor.
 */
interface Unit {
  cycle: number;
  epoch: number;
  periodOf(day: number): number;
}

const EPOCH_MONDAY = isoDay("1970-01-05");

const DAYS: Unit = { cycle: 146097, epoch: 0, periodOf: (day) => day };
const WEEKS: Unit = {
  cycle: 20871,
  epoch: EPOCH_MONDAY,
  periodOf: (day) => Math.floor((day - EPOCH_MONDAY) / 7),
};
const MONTHS: Unit = {
  cycle: 4800,
  epoch: 0,
  periodOf: (day) => {
    const { year, month } = civil(day);
    return year * 12 + month - 1;
  },
};
const YEARS: Unit = {
  cycle: 400,
  epoch: 0,
  periodOf: (day) => civil(day).year,
};
// An ISO date has a single period, so the search visits it and stops.
const ONCE: Unit = { cycle: 1, epoch: 0, periodOf: () => 0 };

/**
 * Where a schedule's occurrences can fall: every `interval`-th period of
 * `unit` counted from `anchor`, and the candidate days (ascending) inside each
 * period. `during` is already applied, to the target month of each period.
 */
interface Plan {
  unit: Unit;
  interval: number;
  anchor: number;
  daysIn(period: number): number[];
}

function planFor(schedule: ScheduleData): Plan {
  const { expr } = schedule;
  const during = schedule.during.map(monthNumber);
  const inDuring = (month: number) =>
    during.length === 0 || during.includes(month);
  const dayIfInDuring = (day: number) =>
    inDuring(civil(day).month) ? [day] : [];

  const repeat = (
    unit: Unit,
    interval: number,
    daysIn: (period: number) => number[],
  ): Plan => {
    const anchorDay =
      schedule.anchor === null ? unit.epoch : isoDay(schedule.anchor);
    return { unit, interval, anchor: unit.periodOf(anchorDay), daysIn };
  };

  switch (expr.type) {
    case "dayRepeat":
      return repeat(DAYS, expr.interval, (day) =>
        matchesDayFilter(day, expr.days) ? dayIfInDuring(day) : [],
      );
    case "intervalRepeat": {
      const hasSlots = lastSlot(expr) >= 0;
      return repeat(DAYS, 1, (day) =>
        hasSlots &&
        (expr.dayFilter === null || matchesDayFilter(day, expr.dayFilter))
          ? dayIfInDuring(day)
          : [],
      );
    }
    case "weekRepeat": {
      const offsets = expr.days.map((d) => weekdayNumber(d) - 1);
      offsets.sort((a, b) => a - b);
      return repeat(WEEKS, expr.interval, (week) =>
        offsets.flatMap((o) => dayIfInDuring(EPOCH_MONDAY + 7 * week + o)),
      );
    }
    case "monthRepeat":
      return repeat(MONTHS, expr.interval, (period) => {
        const month = mod(period, 12) + 1;
        return inDuring(month)
          ? monthTargetDays(Math.floor(period / 12), month, expr.target)
          : [];
      });
    case "yearRepeat": {
      const { target } = expr;
      return repeat(YEARS, expr.interval, (year) =>
        inDuring(monthNumber(target.month))
          ? orNone(yearTargetDay(year, target))
          : [],
      );
    }
    case "singleDate": {
      const { date } = expr;
      if (date.type === "iso") {
        const day = isoDay(date.date);
        return repeat(ONCE, 1, (period) =>
          period === 0 ? dayIfInDuring(day) : [],
        );
      }
      const month = monthNumber(date.month);
      return repeat(YEARS, 1, (year) =>
        date.day <= daysInMonth(year, month)
          ? dayIfInDuring(epochDay(year, month, date.day))
          : [],
      );
    }
  }
}

const FIRST_DAY = epochDay(1, 1, 1);
const LAST_DAY = epochDay(9999, 12, 31);

/**
 * Candidate days from `start` (inclusive) in `direction`, over one full
 * calendar cycle of aligned periods, and never outside years 1-9999.
 */
function* candidateDays(
  plan: Plan,
  from: number,
  direction: Direction,
): Generator<number> {
  const { unit, interval } = plan;
  const start = Math.min(Math.max(from, FIRST_DAY), LAST_DAY);
  // Begin one period early: a directional nearest weekday can land in the
  // period before or after the one it belongs to.
  let period = unit.periodOf(start) - direction;
  period += direction * mod(direction * (plan.anchor - period), interval);
  const periods = unit.cycle / gcd(unit.cycle, interval);
  for (let i = 0; i <= periods; i++, period += direction * interval) {
    const days = plan.daysIn(period);
    if (direction < 0) days.reverse();
    for (const day of days) {
      if (direction * (day - start) < 0) continue;
      if (day < FIRST_DAY || day > LAST_DAY) return;
      yield day;
    }
  }
}

function minutesOf(time: { hour: number; minute: number }): number {
  return time.hour * 60 + time.minute;
}

function slotStep(expr: IntervalRepeat): number {
  return expr.unit === "min" ? expr.interval : expr.interval * 60;
}

function lastSlot(expr: IntervalRepeat): number {
  return Math.floor(
    (minutesOf(expr.to) - minutesOf(expr.from)) / slotStep(expr),
  );
}

const DAY_MS = 86_400_000;
const MINUTE_MS = 60_000;
const RANGE_START_MS = epochDay(1, 1, 2) * DAY_MS;
const RANGE_END_MS = epochDay(9999, 12, 30) * DAY_MS;

function epochMs(t: ZDT): number {
  return Number(t.epochNanoseconds / 1_000_000n);
}

function inRange(t: ZDT): boolean {
  const ms = epochMs(t);
  return ms >= RANGE_START_MS && ms < RANGE_END_MS;
}

/**
 * Resolves wall-clock times in one timezone. The Temporal polyfill costs
 * microseconds per call, so offsets are looked up once per day and wall times
 * are resolved with plain arithmetic.
 */
class Zone {
  private midnightOffsets = new Map<number, number>();
  private transitions = new Map<number, number>();

  constructor(readonly id: string) {}

  zoned(ms: number): ZDT {
    return Temporal.Instant.fromEpochMilliseconds(ms).toZonedDateTimeISO(
      this.id,
    );
  }

  offsetAt(ms: number): number {
    return this.zoned(ms).offsetNanoseconds / 1e6;
  }

  localDay(ms: number): number {
    return Math.floor((ms + this.offsetAt(ms)) / DAY_MS);
  }

  /**
   * The instant of `minute` on `day` by the spec's rules: a repeated time
   * takes its first pass, and a time in a gap shifts forward by the gap length,
   * or is null when `skipGap` is set (interval slots).
   */
  resolve(day: number, minute: number, skipGap: boolean): number | null {
    const local = day * DAY_MS + minute * MINUTE_MS;
    // Every wall time on `day`, and a time shifted from it onto the next day,
    // lies between UTC midnight of the day before and of the day after next.
    // tz data never has two offset changes within those three days (the
    // closest pair is ten days apart), so equal offsets at both ends mean no
    // change, and otherwise there is exactly one.
    const before = this.offsetAtMidnight(day - 1);
    const after = this.offsetAtMidnight(day + 2);
    if (before === after) return local - before;
    const at = this.transitionAfter(day - 1);
    if (local - before < at) return local - before;
    if (local - after >= at) return local - after;
    return skipGap ? null : local - before;
  }

  private offsetAtMidnight(day: number): number {
    let offset = this.midnightOffsets.get(day);
    if (offset === undefined) {
      if (this.midnightOffsets.size > 64) this.midnightOffsets.clear();
      offset = this.offsetAt(day * DAY_MS);
      this.midnightOffsets.set(day, offset);
    }
    return offset;
  }

  private transitionAfter(day: number): number {
    let at = this.transitions.get(day);
    if (at === undefined) {
      if (this.transitions.size > 64) this.transitions.clear();
      const next = this.zoned(day * DAY_MS).getTimeZoneTransition("next");
      at = next === null ? Number.POSITIVE_INFINITY : epochMs(next);
      this.transitions.set(day, at);
    }
    return at;
  }
}

/** Index of the first element of ascending `times` greater than `ms`. */
function firstAfter(times: number[], ms: number): number {
  let lo = 0;
  let hi = times.length;
  while (lo < hi) {
    const mid = (lo + hi) >> 1;
    if (times[mid] > ms) hi = mid;
    else lo = mid + 1;
  }
  return lo;
}

interface Occurrence {
  ms: number;
  day: number;
}

/**
 * One schedule evaluated from one `now`: its plan, its clauses resolved to
 * days, and the occurrences of each scheduled day, cached so that iterators
 * resolve each day once.
 */
class Evaluation {
  readonly zone: Zone;
  private readonly plan: Plan;
  private readonly until: number | null;
  private readonly starting: number | null;
  private readonly named: { month: number; day: number }[];
  private readonly isoExceptions: number[];
  private readonly days = new Map<number, number[]>();

  constructor(
    private readonly schedule: ScheduleData,
    now: ZDT,
  ) {
    this.zone = new Zone(schedule.timezone ?? "UTC");
    this.plan = planFor(schedule);
    this.until =
      schedule.until === null ? null : resolveUntil(schedule.until, now);
    this.starting = schedule.anchor === null ? null : isoDay(schedule.anchor);
    this.named = [];
    this.isoExceptions = [];
    for (const exc of schedule.except) {
      if (exc.type === "named") {
        this.named.push({ month: monthNumber(exc.month), day: exc.day });
      } else {
        this.isoExceptions.push(isoDay(exc.date));
      }
    }
  }

  // A time shifted by a spring-forward gap keeps its scheduled day for every
  // clause but can land on the next date, after that date's early times. So
  // the searches key on scheduled days and look one day beyond the best so
  // far; occurrences two scheduled days apart are always in order.

  /** The first occurrence after `afterMs`, scanning scheduled days from `fromDay`. */
  next(
    afterMs: number,
    fromDay = this.zone.localDay(afterMs) - 1,
  ): Occurrence | null {
    let best: Occurrence | null = null;
    const start = Math.max(fromDay, this.starting ?? fromDay);
    for (const day of candidateDays(this.plan, start, 1)) {
      if (best !== null && day > best.day + 1) break;
      if (this.until !== null && day > this.until) break;
      if (this.isExcepted(day)) continue;
      const times = this.occurrencesOn(day);
      const ms = times[firstAfter(times, afterMs)];
      if (ms !== undefined && (best === null || ms < best.ms)) {
        best = { ms, day };
      }
    }
    return best !== null && best.ms < RANGE_END_MS ? best : null;
  }

  /** The last occurrence before `beforeMs`. */
  previous(beforeMs: number): Occurrence | null {
    // A fall-back across midnight can put `now` on the previous date after
    // the first pass of the next date's times.
    let start = this.zone.localDay(beforeMs) + 1;
    if (this.until !== null) start = Math.min(start, this.until);
    let best: Occurrence | null = null;
    for (const day of candidateDays(this.plan, start, -1)) {
      if (best !== null && day < best.day - 1) break;
      if (this.starting !== null && day < this.starting) break;
      if (this.isExcepted(day)) continue;
      const times = this.occurrencesOn(day);
      const ms = times[firstAfter(times, beforeMs - 1) - 1];
      if (ms !== undefined && (best === null || ms > best.ms)) {
        best = { ms, day };
      }
    }
    return best !== null && best.ms >= RANGE_START_MS ? best : null;
  }

  private isExcepted(day: number): boolean {
    if (this.isoExceptions.includes(day)) return true;
    if (this.named.length === 0) return false;
    const date = civil(day);
    return this.named.some((n) => n.month === date.month && n.day === date.day);
  }

  /** The instants of `day`'s occurrences, ascending and without repeats. */
  private occurrencesOn(day: number): number[] {
    let times = this.days.get(day);
    if (times === undefined) {
      if (this.days.size > 8) this.days.clear();
      times = this.resolveDay(day);
      this.days.set(day, times);
    }
    return times;
  }

  private resolveDay(day: number): number[] {
    const { expr } = this.schedule;
    const times: number[] = [];
    if (expr.type === "intervalRepeat") {
      const first = minutesOf(expr.from);
      for (let k = 0; k <= lastSlot(expr); k++) {
        const ms = this.zone.resolve(day, first + k * slotStep(expr), true);
        if (ms !== null) times.push(ms);
      }
      return times;
    }
    for (const time of expr.times) {
      const ms = this.zone.resolve(day, minutesOf(time), false);
      if (ms !== null) times.push(ms);
    }
    times.sort((a, b) => a - b);
    return times.filter((t, i) => i === 0 || times[i - 1] < t);
  }
}

function resolveUntil(until: UntilSpec, now: ZDT): number {
  if (until.type === "iso") return isoDay(until.date);
  const today = dayOf(now.toPlainDate());
  const month = monthNumber(until.month);
  const { year } = civil(today);
  for (const y of [year, year + 1]) {
    if (until.day <= daysInMonth(y, month)) {
      const day = epochDay(y, month, until.day);
      if (day >= today) return day;
    }
  }
  throw new RangeError(
    `no ${until.month} ${until.day} in ${year} or ${year + 1}`,
  );
}

// spec/README.md, "Supported range": a `now` outside it has no occurrences.

export function nextFrom(schedule: ScheduleData, now: ZDT): ZDT | null {
  if (!inRange(now)) return null;
  const evaluation = new Evaluation(schedule, now);
  const next = evaluation.next(epochMs(now));
  return next === null ? null : evaluation.zone.zoned(next.ms);
}

/** The most recent occurrence strictly before `now`, or null if there is none. */
export function previousFrom(schedule: ScheduleData, now: ZDT): ZDT | null {
  if (!inRange(now)) return null;
  const evaluation = new Evaluation(schedule, now);
  const nowMs = epochMs(now);
  const beforeMs = now.epochNanoseconds % 1_000_000n === 0n ? nowMs : nowMs + 1;
  const previous = evaluation.previous(beforeMs);
  return previous === null ? null : evaluation.zone.zoned(previous.ms);
}

/** True when the minute containing `datetime` is an occurrence. */
export function matches(schedule: ScheduleData, datetime: ZDT): boolean {
  if (!inRange(datetime)) return false;
  const evaluation = new Evaluation(schedule, datetime);
  const ms = epochMs(datetime);
  const offset = evaluation.zone.offsetAt(ms);
  const minuteMs = Math.floor((ms + offset) / MINUTE_MS) * MINUTE_MS - offset;
  return evaluation.next(minuteMs - 1)?.ms === minuteMs;
}

/**
 * Lazily yields occurrences strictly after `from`. Unbounded for repeating
 * schedules unless an `until` clause ends them.
 */
export function* occurrences(
  schedule: ScheduleData,
  from: ZDT,
): Generator<ZDT, void, unknown> {
  if (!inRange(from)) return;
  const evaluation = new Evaluation(schedule, from);
  let next = evaluation.next(epochMs(from));
  while (next !== null) {
    yield evaluation.zone.zoned(next.ms);
    next = evaluation.next(next.ms, next.day - 1);
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

/** Yields occurrences where `from < occurrence <= to`. */
export function* between(
  schedule: ScheduleData,
  from: ZDT,
  to: ZDT,
): Generator<ZDT, void, unknown> {
  const toNs = to.epochNanoseconds;
  for (const t of occurrences(schedule, from)) {
    if (t.epochNanoseconds > toNs) return;
    yield t;
  }
}
