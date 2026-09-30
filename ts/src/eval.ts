import { Temporal } from "@js-temporal/polyfill";
import type {
  DayFilter,
  Exception,
  MonthTarget,
  NearestDirection,
  OrdinalPosition,
  ScheduleData,
  ScheduleExpr,
  TimeOfDay,
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

function plainDate(day: number): Temporal.PlainDate {
  return Temporal.PlainDate.from(civil(day));
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
 * A plain nearest weekday (cron W) stays inside the month; `next` always moves
 * a weekend forward and `previous` always moves it back, possibly into the
 * adjacent month. Null when the month has no such day.
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
  firstPeriod: number | null;
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
    const anchor = unit.periodOf(anchorDay);
    // With `starting`, aligned repeats and weekly repeats wait for its period.
    const bounded =
      schedule.anchor !== null && (interval > 1 || unit === WEEKS);
    return {
      unit,
      interval,
      anchor,
      firstPeriod: bounded ? anchor : null,
      daysIn,
    };
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
 * Candidate days from `start` (inclusive) in `direction`, up to one full
 * calendar cycle of aligned periods and within the supported years 1-9999.
 */
function* candidateDays(
  plan: Plan,
  start: number,
  direction: Direction,
): Generator<number> {
  const { unit, interval } = plan;
  // Begin one period early: a directional nearest weekday can land in the
  // period before or after the one it belongs to.
  let period = unit.periodOf(start) - direction;
  period += direction * mod(direction * (plan.anchor - period), interval);
  const periods = unit.cycle / gcd(unit.cycle, interval);
  const end = direction > 0 ? LAST_DAY : FIRST_DAY;
  for (let i = 0; i <= periods; i++, period += direction * interval) {
    if (plan.firstPeriod !== null && period < plan.firstPeriod) {
      if (direction < 0) return;
      period = plan.firstPeriod;
    }
    const days = plan.daysIn(period);
    if (direction < 0) days.reverse();
    for (const day of days) {
      if (direction * (day - end) > 0) return;
      if (direction * (day - start) >= 0) yield day;
    }
  }
}

function isBefore(a: ZDT, b: ZDT): boolean {
  return Temporal.ZonedDateTime.compare(a, b) < 0;
}

function toPlainTime(tod: TimeOfDay): Temporal.PlainTime {
  return Temporal.PlainTime.from({ hour: tod.hour, minute: tod.minute });
}

// Temporal's "compatible" disambiguation is the spec's rule for fixed times:
// a time in a spring-forward gap shifts forward by the gap length, and a
// repeated fall-back time resolves to its first pass.
function fixedTimesOn(day: number, times: TimeOfDay[], tz: string): ZDT[] {
  const date = plainDate(day);
  const resolved = times
    .map((tod) =>
      date
        .toPlainDateTime(toPlainTime(tod))
        .toZonedDateTime(tz, { disambiguation: "compatible" }),
    )
    .sort(Temporal.ZonedDateTime.compare);
  return resolved.filter((t, i) => i === 0 || isBefore(resolved[i - 1], t));
}

/** Slot `k` of an interval repeat, or null when its wall time is in a gap. */
function intervalSlot(
  expr: IntervalRepeat,
  date: Temporal.PlainDate,
  k: number,
  tz: string,
): ZDT | null {
  const minutes = minutesOf(expr.from) + k * slotStep(expr);
  const wall = date.toPlainDateTime({
    hour: Math.floor(minutes / 60),
    minute: minutes % 60,
  });
  const t = wall.toZonedDateTime(tz, { disambiguation: "compatible" });
  return Temporal.PlainDateTime.compare(t.toPlainDateTime(), wall) === 0
    ? t
    : null;
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

/** The slot index at `now`'s wall time on `day`, as a fraction of a step. */
function slotPosition(
  expr: IntervalRepeat,
  day: number,
  now: ZDT,
  tz: string,
): number {
  const local = now.withTimeZone(tz);
  const today = dayOf(local);
  if (day !== today) return day < today ? Infinity : -Infinity;
  return (minutesOf(local) - minutesOf(expr.from)) / slotStep(expr);
}

function firstSlotAfter(
  expr: IntervalRepeat,
  day: number,
  now: ZDT,
  tz: string,
): ZDT | null {
  const date = plainDate(day);
  const start = Math.max(0, Math.ceil(slotPosition(expr, day, now, tz)));
  for (let k = start; k <= lastSlot(expr); k++) {
    const t = intervalSlot(expr, date, k, tz);
    if (t !== null && isBefore(now, t)) return t;
  }
  return null;
}

function lastSlotBefore(
  expr: IntervalRepeat,
  day: number,
  now: ZDT,
  tz: string,
): ZDT | null {
  const date = plainDate(day);
  const last = lastSlot(expr);
  let k = Math.max(
    -1,
    Math.min(last, Math.floor(slotPosition(expr, day, now, tz))),
  );
  // Inside a fall-back overlap, first-pass slots later in wall time than `now`
  // are still earlier instants.
  while (k < last) {
    const t = intervalSlot(expr, date, k + 1, tz);
    if (t === null || !isBefore(t, now)) break;
    k++;
  }
  for (; k >= 0; k--) {
    const t = intervalSlot(expr, date, k, tz);
    if (t !== null && isBefore(t, now)) return t;
  }
  return null;
}

function firstAfter(
  expr: ScheduleExpr,
  day: number,
  now: ZDT,
  tz: string,
): ZDT | null {
  if (expr.type === "intervalRepeat") {
    return firstSlotAfter(expr, day, now, tz);
  }
  return (
    fixedTimesOn(day, expr.times, tz).find((t) => isBefore(now, t)) ?? null
  );
}

function lastBefore(
  expr: ScheduleExpr,
  day: number,
  now: ZDT,
  tz: string,
): ZDT | null {
  if (expr.type === "intervalRepeat") {
    return lastSlotBefore(expr, day, now, tz);
  }
  const times = fixedTimesOn(day, expr.times, tz).reverse();
  return times.find((t) => isBefore(t, now)) ?? null;
}

function isExcepted(day: number, exceptions: Exception[]): boolean {
  if (exceptions.length === 0) return false;
  const date = civil(day);
  return exceptions.some((exc) =>
    exc.type === "named"
      ? monthNumber(exc.month) === date.month && exc.day === date.day
      : isoDay(exc.date) === day,
  );
}

function resolveUntil(until: UntilSpec, now: ZDT): Temporal.PlainDate {
  if (until.type === "iso") {
    return Temporal.PlainDate.from(until.date);
  }
  const year = now.toPlainDate().year;
  for (const y of [year, year + 1]) {
    try {
      const d = Temporal.PlainDate.from(
        {
          year: y,
          month: monthNumber(until.month),
          day: until.day,
        },
        { overflow: "reject" },
      );
      if (Temporal.PlainDate.compare(d, now.toPlainDate()) >= 0) {
        return d;
      }
    } catch {
      // Invalid date, try next year
    }
  }
  return Temporal.PlainDate.from(
    {
      year: year + 1,
      month: monthNumber(until.month),
      day: until.day,
    },
    { overflow: "reject" },
  );
}

function resolveTz(tz: string | null): string {
  return tz ?? "UTC";
}

// A fixed time in a spring-forward gap at midnight shifts onto the next date
// but keeps its scheduled date for every clause, so the searches key on the
// scheduled day and keep looking until no later day can land on a nearer
// instant: a day's occurrences land on that date or the next.

export function nextFrom(schedule: ScheduleData, now: ZDT): ZDT | null {
  const tz = resolveTz(schedule.timezone);
  const today = dayOf(now.withTimeZone(tz));
  const until =
    schedule.until === null ? null : dayOf(resolveUntil(schedule.until, now));
  let best: ZDT | null = null;
  for (const day of candidateDays(planFor(schedule), today - 1, 1)) {
    if (best !== null && day > dayOf(best)) break;
    if (until !== null && day > until) break;
    if (isExcepted(day, schedule.except)) continue;
    const t = firstAfter(schedule.expr, day, now, tz);
    if (t !== null && (best === null || isBefore(t, best))) best = t;
  }
  return best;
}

/** The most recent occurrence strictly before `now`, or null if there is none. */
export function previousFrom(schedule: ScheduleData, now: ZDT): ZDT | null {
  const tz = resolveTz(schedule.timezone);
  const anchor = schedule.anchor === null ? null : isoDay(schedule.anchor);
  let start = dayOf(now.withTimeZone(tz));
  if (schedule.until !== null) {
    start = Math.min(start, dayOf(resolveUntil(schedule.until, now)));
  }
  let best: ZDT | null = null;
  for (const day of candidateDays(planFor(schedule), start, -1)) {
    if (best !== null && day + 1 < dayOf(best)) break;
    if (anchor !== null && day < anchor) break;
    if (isExcepted(day, schedule.except)) continue;
    const t = lastBefore(schedule.expr, day, now, tz);
    if (t !== null && (best === null || isBefore(best, t))) best = t;
  }
  return best;
}

/** True when the minute containing `datetime` is an occurrence. */
export function matches(schedule: ScheduleData, datetime: ZDT): boolean {
  const minute = datetime
    .withTimeZone(resolveTz(schedule.timezone))
    .round({ smallestUnit: "minute", roundingMode: "floor" });
  const next = nextFrom(schedule, minute.subtract({ nanoseconds: 1 }));
  return next !== null && next.epochNanoseconds === minute.epochNanoseconds;
}

/**
 * Lazily yields occurrences strictly after `from`. Unbounded for repeating
 * schedules unless an `until` clause ends them.
 */
export function* occurrences(
  schedule: ScheduleData,
  from: ZDT,
): Generator<ZDT, void, unknown> {
  for (
    let t = nextFrom(schedule, from);
    t !== null;
    t = nextFrom(schedule, t)
  ) {
    yield t;
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
  for (const t of occurrences(schedule, from)) {
    if (Temporal.ZonedDateTime.compare(t, to) > 0) return;
    yield t;
  }
}
