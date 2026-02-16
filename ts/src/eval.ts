// Evaluator — computes next occurrences and matches for hron schedules.

import { Temporal } from "@js-temporal/polyfill";
import type {
  DateSpec,
  DayFilter,
  Exception,
  MonthName,
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
type PD = Temporal.PlainDate;

// =============================================================================
// Iteration Safety Limits
// =============================================================================
// MAX_ITERATIONS (1000): Maximum iterations for nextFrom/previousFrom loops.
// Prevents infinite loops when searching for valid occurrences.
//
// Expression-specific limits:
// - Day repeat: 8 days (covers one week + margin)
// - Week repeat: 54 weeks (covers one year + margin)
// - Month repeat: 24 * interval months (covers 2 years scaled by interval)
// - Year repeat: 8 * interval years (covers reasonable future horizon)
//
// These limits are generous safety bounds. In practice, valid schedules
// find occurrences within the first few iterations.
// =============================================================================

// =============================================================================
// DST (Daylight Saving Time) Handling
// =============================================================================
// When resolving a wall-clock time to an instant:
//
// 1. DST Gap (Spring Forward):
//    - Time doesn't exist (e.g., 2:30 AM during spring forward)
//    - Solution: Push forward to the next valid time after the gap
//    - Example: 2:30 AM -> 3:00 AM (or 3:30 AM depending on gap size)
//
// 2. DST Fold (Fall Back):
//    - Time is ambiguous (e.g., 1:30 AM occurs twice)
//    - Solution: Use first occurrence (fold=0 / pre-transition time)
//    - This matches user expectation for scheduling
//
// All implementations use the same algorithm for cross-language consistency.
// =============================================================================

// =============================================================================
// Interval Alignment (Anchor Date)
// =============================================================================
// For schedules with interval > 1 (e.g., "every 3 days"), we need to
// determine which dates are valid based on alignment with an anchor.
//
// Formula: (date_offset - anchor_offset) mod interval == 0
//
// Where:
//   - date_offset: days/weeks/months from epoch to candidate date
//   - anchor_offset: days/weeks/months from epoch to anchor date
//   - interval: the repeat interval (e.g., 3 for "every 3 days")
//
// Default anchor: Epoch (1970-01-01)
// Custom anchor: Set via "starting YYYY-MM-DD" clause
//
// For week repeats, we use epoch Monday (1970-01-05) as the reference
// point to align week boundaries correctly.
// =============================================================================

// --- Timezone resolution ---

/** Resolve timezone, defaulting to UTC for deterministic behavior. */
function resolveTz(tz: string | null): string {
  return tz ?? "UTC";
}

// --- Helpers ---

function toPlainTime(tod: TimeOfDay): Temporal.PlainTime {
  return Temporal.PlainTime.from({ hour: tod.hour, minute: tod.minute });
}

function atTimeOnDate(date: PD, time: Temporal.PlainTime, tz: string): ZDT {
  return date.toPlainDateTime(time).toZonedDateTime(tz, {
    disambiguation: "compatible",
  });
}

function weekdayNameToNumber(day: Weekday): number {
  return weekdayNumber(day);
}

function matchesDayFilter(date: PD, filter: DayFilter): boolean {
  const dow = date.dayOfWeek; // 1=Monday ... 7=Sunday
  switch (filter.type) {
    case "every":
      return true;
    case "weekday":
      return dow >= 1 && dow <= 5;
    case "weekend":
      return dow === 6 || dow === 7;
    case "days":
      return filter.days.some((d) => weekdayNameToNumber(d) === dow);
  }
}

function lastDayOfMonth(year: number, month: number): PD {
  return Temporal.PlainDate.from({ year, month, day: 1 })
    .add({ months: 1 })
    .subtract({ days: 1 });
}

function lastWeekdayOfMonth(year: number, month: number): PD {
  let d = lastDayOfMonth(year, month);
  while (d.dayOfWeek === 6 || d.dayOfWeek === 7) {
    d = d.subtract({ days: 1 });
  }
  return d;
}

/**
 * Get the nearest weekday to a given day in a month.
 * - direction=null: standard cron W behavior (never crosses month boundary)
 * - direction="next": always prefer following weekday (can cross to next month)
 * - direction="previous": always prefer preceding weekday (can cross to prev month)
 * Returns null if the target_day doesn't exist in the month (e.g., day 31 in February).
 */
function nearestWeekday(
  year: number,
  month: number,
  targetDay: number,
  direction: NearestDirection | null,
): PD | null {
  const last = lastDayOfMonth(year, month);
  const lastDay = last.day;

  // If target day doesn't exist in this month, return null (skip this month)
  if (targetDay > lastDay) {
    return null;
  }

  const date = Temporal.PlainDate.from({ year, month, day: targetDay });
  const dow = date.dayOfWeek; // 1=Monday, 7=Sunday

  // Already a weekday (Monday=1 through Friday=5)
  if (dow >= 1 && dow <= 5) {
    return date;
  }

  // Saturday (dow === 6)
  if (dow === 6) {
    if (direction === null) {
      // Standard: prefer Friday, but if at month start, use Monday
      if (targetDay === 1) {
        // Can't go to previous month, use Monday (day 3)
        return date.add({ days: 2 });
      }
      // Friday
      return date.subtract({ days: 1 });
    }
    if (direction === "next") {
      // Always Monday (may cross month)
      return date.add({ days: 2 });
    }
    // direction === "previous"
    // Always Friday (may cross month if day==1)
    return date.subtract({ days: 1 });
  }

  // Sunday (dow === 7)
  if (direction === null) {
    // Standard: prefer Monday, but if at month end, use Friday
    if (targetDay >= lastDay) {
      // Can't go to next month, use Friday (day - 2)
      return date.subtract({ days: 2 });
    }
    // Monday
    return date.add({ days: 1 });
  }
  if (direction === "next") {
    // Always Monday (may cross month)
    return date.add({ days: 1 });
  }
  // direction === "previous"
  // Always Friday (go back 2 days, may cross month)
  return date.subtract({ days: 2 });
}

function nthWeekdayOfMonth(
  year: number,
  month: number,
  weekday: Weekday,
  n: number,
): PD | null {
  const targetDow = weekdayNameToNumber(weekday);
  let d = Temporal.PlainDate.from({ year, month, day: 1 });
  while (d.dayOfWeek !== targetDow) {
    d = d.add({ days: 1 });
  }
  for (let i = 1; i < n; i++) {
    d = d.add({ days: 7 });
  }
  if (d.month !== month) return null;
  return d;
}

function lastWeekdayInMonth(year: number, month: number, weekday: Weekday): PD {
  const targetDow = weekdayNameToNumber(weekday);
  let d = lastDayOfMonth(year, month);
  while (d.dayOfWeek !== targetDow) {
    d = d.subtract({ days: 1 });
  }
  return d;
}

const EPOCH_MONDAY: PD = Temporal.PlainDate.from("1970-01-05");
const EPOCH_DATE: PD = Temporal.PlainDate.from("1970-01-01");
const MIDNIGHT: Temporal.PlainTime = Temporal.PlainTime.from({
  hour: 0,
  minute: 0,
});

function weeksBetween(a: PD, b: PD): number {
  const days = a.until(b, { largestUnit: "days" }).days;
  return Math.floor(days / 7);
}

function daysBetween(a: PD, b: PD): number {
  return a.until(b, { largestUnit: "days" }).days;
}

function monthsBetweenYM(a: PD, b: PD): number {
  return b.year * 12 + b.month - (a.year * 12 + a.month);
}

/** Euclidean modulo (always non-negative). */
function euclideanMod(a: number, b: number): number {
  return ((a % b) + b) % b;
}

function isExcepted(date: PD, exceptions: Exception[]): boolean {
  for (const exc of exceptions) {
    if (exc.type === "named") {
      if (date.month === monthNumber(exc.month) && date.day === exc.day) {
        return true;
      }
    } else {
      const excDate = Temporal.PlainDate.from(exc.date);
      if (Temporal.PlainDate.compare(date, excDate) === 0) {
        return true;
      }
    }
  }
  return false;
}

interface ParsedExceptions {
  named: Array<{ month: number; day: number }>;
  isoDates: PD[];
}

function parseExceptions(exceptions: Exception[]): ParsedExceptions {
  const named: Array<{ month: number; day: number }> = [];
  const isoDates: PD[] = [];
  for (const exc of exceptions) {
    if (exc.type === "named") {
      named.push({ month: monthNumber(exc.month), day: exc.day });
    } else {
      isoDates.push(Temporal.PlainDate.from(exc.date));
    }
  }
  return { named, isoDates };
}

function isExceptedParsed(date: PD, parsed: ParsedExceptions): boolean {
  for (const n of parsed.named) {
    if (date.month === n.month && date.day === n.day) return true;
  }
  for (const d of parsed.isoDates) {
    if (Temporal.PlainDate.compare(date, d) === 0) return true;
  }
  return false;
}

function matchesDuring(date: PD, during: MonthName[]): boolean {
  if (during.length === 0) return true;
  return during.some((mn) => monthNumber(mn) === date.month);
}

/** Find the 1st of the next valid `during` month after `date`. */
function nextDuringMonth(date: PD, during: MonthName[]): PD {
  const currentMonth = date.month;
  const months = during.map((mn) => monthNumber(mn)).sort((a, b) => a - b);

  for (const m of months) {
    if (m > currentMonth) {
      return Temporal.PlainDate.from({ year: date.year, month: m, day: 1 });
    }
  }
  // Wrap to first month of next year
  return Temporal.PlainDate.from({
    year: date.year + 1,
    month: months[0],
    day: 1,
  });
}

function resolveUntil(until: UntilSpec, now: ZDT): PD {
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

function earliestFutureAtTimes(
  date: PD,
  times: TimeOfDay[],
  tz: string,
  now: ZDT,
): ZDT | null {
  let best: ZDT | null = null;
  for (const tod of times) {
    const t = toPlainTime(tod);
    const candidate = atTimeOnDate(date, t, tz);
    if (Temporal.ZonedDateTime.compare(candidate, now) > 0) {
      if (
        best === null ||
        Temporal.ZonedDateTime.compare(candidate, best) < 0
      ) {
        best = candidate;
      }
    }
  }
  return best;
}

// --- Public API ---

export function nextFrom(schedule: ScheduleData, now: ZDT): ZDT | null {
  const tz = resolveTz(schedule.timezone);

  const untilDate = schedule.until ? resolveUntil(schedule.until, now) : null;

  const parsedExceptions = parseExceptions(schedule.except);
  const hasExceptions = schedule.except.length > 0;
  const hasDuring = schedule.during.length > 0;

  // Check if expression is NearestWeekday with direction (can cross month boundaries)
  const handlesDuringInternally =
    schedule.expr.type === "monthRepeat" &&
    schedule.expr.target.type === "nearestWeekday" &&
    schedule.expr.target.direction !== null;

  let current = now;
  for (let i = 0; i < 1000; i++) {
    const candidate = nextExpr(
      schedule.expr,
      tz,
      schedule.anchor,
      current,
      schedule.during,
    );

    if (candidate === null) return null;

    // Convert to target tz once for all filter checks
    const cDate = candidate.withTimeZone(tz).toPlainDate();

    // Apply until filter
    if (untilDate) {
      if (Temporal.PlainDate.compare(cDate, untilDate) > 0) {
        return null;
      }
    }

    // Apply during filter
    // Skip this check for expressions that handle during internally (NearestWeekday with direction)
    if (
      hasDuring &&
      !handlesDuringInternally &&
      !matchesDuring(cDate, schedule.during)
    ) {
      // Skip ahead to 1st of next valid during month
      const skipTo = nextDuringMonth(cDate, schedule.during);
      current = atTimeOnDate(skipTo, MIDNIGHT, tz).subtract({ seconds: 1 });
      continue;
    }

    // Apply except filter
    if (hasExceptions && isExceptedParsed(cDate, parsedExceptions)) {
      const nextDay = cDate.add({ days: 1 });
      current = atTimeOnDate(nextDay, MIDNIGHT, tz).subtract({ seconds: 1 });
      continue;
    }

    return candidate;
  }

  return null;
}

function nextExpr(
  expr: ScheduleExpr,
  tz: string,
  anchor: string | null,
  now: ZDT,
  during: MonthName[],
): ZDT | null {
  switch (expr.type) {
    case "dayRepeat":
      return nextDayRepeat(
        expr.interval,
        expr.days,
        expr.times,
        tz,
        anchor,
        now,
      );
    case "intervalRepeat":
      return nextIntervalRepeat(
        expr.interval,
        expr.unit,
        expr.from,
        expr.to,
        expr.dayFilter,
        tz,
        now,
      );
    case "weekRepeat":
      return nextWeekRepeat(
        expr.interval,
        expr.days,
        expr.times,
        tz,
        anchor,
        now,
      );
    case "monthRepeat":
      return nextMonthRepeat(
        expr.interval,
        expr.target,
        expr.times,
        tz,
        anchor,
        now,
        during,
      );
    case "singleDate":
      return nextSingleDate(expr.date, expr.times, tz, now);
    case "yearRepeat":
      return nextYearRepeat(
        expr.interval,
        expr.target,
        expr.times,
        tz,
        anchor,
        now,
      );
  }
}

export function nextNFrom(schedule: ScheduleData, now: ZDT, n: number): ZDT[] {
  const results: ZDT[] = [];
  let current = now;
  for (let i = 0; i < n; i++) {
    const next = nextFrom(schedule, current);
    if (next === null) break;
    current = next.add({ minutes: 1 });
    results.push(next);
  }
  return results;
}

export function matches(schedule: ScheduleData, datetime: ZDT): boolean {
  const tz = resolveTz(schedule.timezone);
  const zdt = datetime.withTimeZone(tz);
  const date = zdt.toPlainDate();

  if (!matchesDuring(date, schedule.during)) return false;
  if (isExcepted(date, schedule.except)) return false;

  if (schedule.until) {
    const untilDate = resolveUntil(schedule.until, datetime);
    if (Temporal.PlainDate.compare(date, untilDate) > 0) return false;
  }

  // DST-aware time matching: a time matches if either the wall-clock matches
  // directly, or the scheduled time falls in a DST gap and resolves to the
  // candidate's instant (e.g., scheduled 2:00 AM during spring-forward → 3:00 AM).
  const timeMatchesWithDst = (times: TimeOfDay[]) =>
    times.some((tod) => {
      if (zdt.hour === tod.hour && zdt.minute === tod.minute) return true;
      const t = toPlainTime(tod);
      const resolved = atTimeOnDate(date, t, tz);
      return resolved.epochNanoseconds === datetime.epochNanoseconds;
    });

  switch (schedule.expr.type) {
    case "dayRepeat": {
      if (!matchesDayFilter(date, schedule.expr.days)) return false;
      if (!timeMatchesWithDst(schedule.expr.times)) return false;
      if (schedule.expr.interval > 1) {
        const anchorDate = schedule.anchor
          ? Temporal.PlainDate.from(schedule.anchor)
          : EPOCH_DATE;
        const dayOffset = daysBetween(anchorDate, date);
        return dayOffset >= 0 && dayOffset % schedule.expr.interval === 0;
      }
      return true;
    }
    case "intervalRepeat": {
      const { interval, unit, from, to, dayFilter } = schedule.expr;
      if (dayFilter && !matchesDayFilter(date, dayFilter)) return false;
      const fromMinutes = from.hour * 60 + from.minute;
      const toMinutes = to.hour * 60 + to.minute;
      const currentMinutes = zdt.hour * 60 + zdt.minute;
      if (currentMinutes < fromMinutes || currentMinutes > toMinutes)
        return false;
      const diff = currentMinutes - fromMinutes;
      const step = unit === "min" ? interval : interval * 60;
      return diff >= 0 && diff % step === 0;
    }
    case "weekRepeat": {
      const { interval, days, times } = schedule.expr;
      const dow = date.dayOfWeek;
      if (!days.some((d) => weekdayNameToNumber(d) === dow)) return false;
      if (!timeMatchesWithDst(times)) return false;
      const anchorDate = schedule.anchor
        ? Temporal.PlainDate.from(schedule.anchor)
        : EPOCH_MONDAY;
      const weeks = weeksBetween(anchorDate, date);
      return weeks >= 0 && weeks % interval === 0;
    }
    case "monthRepeat": {
      if (!timeMatchesWithDst(schedule.expr.times)) return false;
      if (schedule.expr.interval > 1) {
        const anchorDate = schedule.anchor
          ? Temporal.PlainDate.from(schedule.anchor)
          : EPOCH_DATE;
        const monthOffset = monthsBetweenYM(anchorDate, date);
        if (monthOffset < 0 || monthOffset % schedule.expr.interval !== 0) {
          return false;
        }
      }
      const { target } = schedule.expr;
      if (target.type === "days") {
        const expanded = expandMonthTarget(target);
        return expanded.includes(date.day);
      }
      if (target.type === "lastDay") {
        const last = lastDayOfMonth(date.year, date.month);
        return Temporal.PlainDate.compare(date, last) === 0;
      }
      if (target.type === "lastWeekday") {
        const lastWd = lastWeekdayOfMonth(date.year, date.month);
        return Temporal.PlainDate.compare(date, lastWd) === 0;
      }
      if (target.type === "ordinalWeekday") {
        let targetDate: PD | null;
        if (target.ordinal === "last") {
          targetDate = lastWeekdayInMonth(
            date.year,
            date.month,
            target.weekday,
          );
        } else {
          targetDate = nthWeekdayOfMonth(
            date.year,
            date.month,
            target.weekday,
            ordinalToN(target.ordinal),
          );
        }
        if (!targetDate) return false;
        return Temporal.PlainDate.compare(date, targetDate) === 0;
      }
      // nearestWeekday
      const targetDate = nearestWeekday(
        date.year,
        date.month,
        target.day,
        target.direction,
      );
      if (!targetDate) return false;
      return Temporal.PlainDate.compare(date, targetDate) === 0;
    }
    case "singleDate": {
      if (!timeMatchesWithDst(schedule.expr.times)) return false;
      const { date: dateSpec } = schedule.expr;
      if (dateSpec.type === "iso") {
        const target = Temporal.PlainDate.from(dateSpec.date);
        return Temporal.PlainDate.compare(date, target) === 0;
      }
      if (dateSpec.type === "named") {
        return (
          date.month === monthNumber(dateSpec.month) &&
          date.day === dateSpec.day
        );
      }
      return false;
    }
    case "yearRepeat": {
      if (!timeMatchesWithDst(schedule.expr.times)) return false;
      if (schedule.expr.interval > 1) {
        const anchorYear = schedule.anchor
          ? Temporal.PlainDate.from(schedule.anchor).year
          : EPOCH_DATE.year;
        const yearOffset = date.year - anchorYear;
        if (yearOffset < 0 || yearOffset % schedule.expr.interval !== 0) {
          return false;
        }
      }
      return matchesYearTarget(schedule.expr.target, date);
    }
  }
}

function matchesYearTarget(target: YearTarget, date: PD): boolean {
  switch (target.type) {
    case "date":
      return (
        date.month === monthNumber(target.month) && date.day === target.day
      );
    case "ordinalWeekday": {
      if (date.month !== monthNumber(target.month)) return false;
      let targetDate: PD | null;
      if (target.ordinal === "last") {
        targetDate = lastWeekdayInMonth(date.year, date.month, target.weekday);
      } else {
        targetDate = nthWeekdayOfMonth(
          date.year,
          date.month,
          target.weekday,
          ordinalToN(target.ordinal),
        );
      }
      if (!targetDate) return false;
      return Temporal.PlainDate.compare(date, targetDate) === 0;
    }
    case "dayOfMonth":
      return (
        date.month === monthNumber(target.month) && date.day === target.day
      );
    case "lastWeekday": {
      if (date.month !== monthNumber(target.month)) return false;
      const lwd = lastWeekdayOfMonth(date.year, date.month);
      return Temporal.PlainDate.compare(date, lwd) === 0;
    }
  }
}

// --- Per-variant next functions ---

function nextDayRepeat(
  interval: number,
  days: DayFilter,
  times: TimeOfDay[],
  tz: string,
  anchor: string | null,
  now: ZDT,
): ZDT | null {
  const nowInTz = now.withTimeZone(tz);
  let date = nowInTz.toPlainDate();

  if (interval <= 1) {
    // Original behavior for interval=1
    if (matchesDayFilter(date, days)) {
      const candidate = earliestFutureAtTimes(date, times, tz, now);
      if (candidate) return candidate;
    }

    for (let i = 0; i < 8; i++) {
      date = date.add({ days: 1 });
      if (matchesDayFilter(date, days)) {
        const candidate = earliestFutureAtTimes(date, times, tz, now);
        if (candidate) return candidate;
      }
    }

    return null;
  }

  // Interval > 1: day intervals only apply to DayFilter::Every
  const anchorDate = anchor ? Temporal.PlainDate.from(anchor) : EPOCH_DATE;

  // Find the next aligned day >= today
  const offset = daysBetween(anchorDate, date);
  const remainder = euclideanMod(offset, interval);
  let alignedDate =
    remainder === 0 ? date : date.add({ days: interval - remainder });

  for (let i = 0; i < 400; i++) {
    const candidate = earliestFutureAtTimes(alignedDate, times, tz, now);
    if (candidate) return candidate;
    alignedDate = alignedDate.add({ days: interval });
  }

  return null;
}

function nextIntervalRepeat(
  interval: number,
  unit: string,
  from: TimeOfDay,
  to: TimeOfDay,
  dayFilter: DayFilter | null,
  tz: string,
  now: ZDT,
): ZDT | null {
  const nowInTz = now.withTimeZone(tz);
  const stepMinutes = unit === "min" ? interval : interval * 60;
  const fromMinutes = from.hour * 60 + from.minute;
  const toMinutes = to.hour * 60 + to.minute;

  let date = nowInTz.toPlainDate();

  for (let d = 0; d < 400; d++) {
    if (dayFilter && !matchesDayFilter(date, dayFilter)) {
      date = date.add({ days: 1 });
      continue;
    }

    const sameDay =
      Temporal.PlainDate.compare(date, nowInTz.toPlainDate()) === 0;
    const nowMinutes = sameDay ? nowInTz.hour * 60 + nowInTz.minute : -1;

    let nextSlot: number;
    if (nowMinutes < fromMinutes) {
      nextSlot = fromMinutes;
    } else {
      const elapsed = nowMinutes - fromMinutes;
      nextSlot =
        fromMinutes + (Math.floor(elapsed / stepMinutes) + 1) * stepMinutes;
    }

    if (nextSlot <= toMinutes) {
      const h = Math.floor(nextSlot / 60);
      const m = nextSlot % 60;
      const t = Temporal.PlainTime.from({ hour: h, minute: m });
      const candidate = atTimeOnDate(date, t, tz);
      if (Temporal.ZonedDateTime.compare(candidate, now) > 0) {
        return candidate;
      }
    }

    date = date.add({ days: 1 });
  }

  return null;
}

function nextWeekRepeat(
  interval: number,
  days: Weekday[],
  times: TimeOfDay[],
  tz: string,
  anchor: string | null,
  now: ZDT,
): ZDT | null {
  const nowInTz = now.withTimeZone(tz);
  const anchorDate = anchor ? Temporal.PlainDate.from(anchor) : EPOCH_MONDAY;

  const date = nowInTz.toPlainDate();

  // Sort target DOWs by number for earliest-first matching
  const sortedDays = [...days].sort(
    (a, b) => weekdayNameToNumber(a) - weekdayNameToNumber(b),
  );

  // Find Monday of current week and Monday of anchor week
  const dowOffset = date.dayOfWeek - 1;
  let currentMonday = date.subtract({ days: dowOffset });

  const anchorDowOffset = anchorDate.dayOfWeek - 1;
  const anchorMonday = anchorDate.subtract({ days: anchorDowOffset });

  // Loop up to 54 iterations (covers >1 year for any interval)
  for (let i = 0; i < 54; i++) {
    const weeks = weeksBetween(anchorMonday, currentMonday);

    // Skip weeks before anchor - anchor Monday is always the first aligned week
    if (weeks < 0) {
      currentMonday = anchorMonday;
      continue;
    }

    if (weeks % interval === 0) {
      // Aligned week — try each target DOW
      for (const wd of sortedDays) {
        const dayOffset = weekdayNameToNumber(wd) - 1;
        const targetDate = currentMonday.add({ days: dayOffset });
        const candidate = earliestFutureAtTimes(targetDate, times, tz, now);
        if (candidate) return candidate;
      }
    }

    // Skip to next aligned week
    const remainder = weeks % interval;
    const skipWeeks = remainder === 0 ? interval : interval - remainder;
    currentMonday = currentMonday.add({ days: skipWeeks * 7 });
  }

  return null;
}

function nextMonthRepeat(
  interval: number,
  target: MonthTarget,
  times: TimeOfDay[],
  tz: string,
  anchor: string | null,
  now: ZDT,
  during: MonthName[],
): ZDT | null {
  const nowInTz = now.withTimeZone(tz);
  let year = nowInTz.year;
  let month = nowInTz.month;

  const anchorDate = anchor ? Temporal.PlainDate.from(anchor) : EPOCH_DATE;
  const maxIter = interval > 1 ? 24 * interval : 24;

  // For NearestWeekday with direction, we need to apply the during filter here
  // because the result can cross month boundaries
  const applyDuringFilter =
    during.length > 0 &&
    target.type === "nearestWeekday" &&
    target.direction !== null;

  for (let i = 0; i < maxIter; i++) {
    // Check during filter for NearestWeekday with direction
    if (applyDuringFilter && !during.some((mn) => monthNumber(mn) === month)) {
      month++;
      if (month > 12) {
        month = 1;
        year++;
      }
      continue;
    }

    // Check interval alignment
    if (interval > 1) {
      const cur = Temporal.PlainDate.from({ year, month, day: 1 });
      const monthOffset = monthsBetweenYM(anchorDate, cur);
      if (monthOffset < 0 || euclideanMod(monthOffset, interval) !== 0) {
        month++;
        if (month > 12) {
          month = 1;
          year++;
        }
        continue;
      }
    }

    const dateCandidates: PD[] = [];

    if (target.type === "days") {
      const expanded = expandMonthTarget(target);
      for (const dayNum of expanded) {
        const last = lastDayOfMonth(year, month);
        if (dayNum <= last.day) {
          try {
            dateCandidates.push(
              Temporal.PlainDate.from({ year, month, day: dayNum }),
            );
          } catch {
            // skip invalid
          }
        }
      }
    } else if (target.type === "lastDay") {
      dateCandidates.push(lastDayOfMonth(year, month));
    } else if (target.type === "lastWeekday") {
      dateCandidates.push(lastWeekdayOfMonth(year, month));
    } else if (target.type === "ordinalWeekday") {
      let owDate: PD | null;
      if (target.ordinal === "last") {
        owDate = lastWeekdayInMonth(year, month, target.weekday);
      } else {
        owDate = nthWeekdayOfMonth(
          year,
          month,
          target.weekday,
          ordinalToN(target.ordinal),
        );
      }
      if (owDate) {
        dateCandidates.push(owDate);
      }
    } else {
      // nearestWeekday
      const nwDate = nearestWeekday(year, month, target.day, target.direction);
      if (nwDate) {
        dateCandidates.push(nwDate);
      }
    }

    let best: ZDT | null = null;
    for (const date of dateCandidates) {
      const candidate = earliestFutureAtTimes(date, times, tz, now);
      if (candidate) {
        if (
          best === null ||
          Temporal.ZonedDateTime.compare(candidate, best) < 0
        ) {
          best = candidate;
        }
      }
    }
    if (best) return best;

    month++;
    if (month > 12) {
      month = 1;
      year++;
    }
  }

  return null;
}

function nextSingleDate(
  dateSpec: DateSpec,
  times: TimeOfDay[],
  tz: string,
  now: ZDT,
): ZDT | null {
  const nowInTz = now.withTimeZone(tz);

  if (dateSpec.type === "iso") {
    const date = Temporal.PlainDate.from(dateSpec.date);
    return earliestFutureAtTimes(date, times, tz, now);
  }

  if (dateSpec.type === "named") {
    const startYear = nowInTz.year;
    for (let y = 0; y < 8; y++) {
      const year = startYear + y;
      try {
        const date = Temporal.PlainDate.from(
          {
            year,
            month: monthNumber(dateSpec.month),
            day: dateSpec.day,
          },
          { overflow: "reject" },
        );
        const candidate = earliestFutureAtTimes(date, times, tz, now);
        if (candidate) return candidate;
      } catch {
        // invalid date
      }
    }
    return null;
  }

  return null;
}

function nextYearRepeat(
  interval: number,
  target: YearTarget,
  times: TimeOfDay[],
  tz: string,
  anchor: string | null,
  now: ZDT,
): ZDT | null {
  const nowInTz = now.withTimeZone(tz);
  const startYear = nowInTz.year;
  const anchorYear = anchor
    ? Temporal.PlainDate.from(anchor).year
    : EPOCH_DATE.year;

  const maxIter = interval > 1 ? 8 * interval : 8;

  for (let y = 0; y < maxIter; y++) {
    const year = startYear + y;

    // Check interval alignment
    if (interval > 1) {
      const yearOffset = year - anchorYear;
      if (yearOffset < 0 || euclideanMod(yearOffset, interval) !== 0) {
        continue;
      }
    }

    let targetDate: PD | null = null;

    switch (target.type) {
      case "date":
        try {
          targetDate = Temporal.PlainDate.from(
            {
              year,
              month: monthNumber(target.month),
              day: target.day,
            },
            { overflow: "reject" },
          );
        } catch {
          continue;
        }
        break;
      case "ordinalWeekday":
        if (target.ordinal === "last") {
          targetDate = lastWeekdayInMonth(
            year,
            monthNumber(target.month),
            target.weekday,
          );
        } else {
          targetDate = nthWeekdayOfMonth(
            year,
            monthNumber(target.month),
            target.weekday,
            ordinalToN(target.ordinal),
          );
        }
        break;
      case "dayOfMonth":
        try {
          targetDate = Temporal.PlainDate.from(
            {
              year,
              month: monthNumber(target.month),
              day: target.day,
            },
            { overflow: "reject" },
          );
        } catch {
          continue;
        }
        break;
      case "lastWeekday":
        targetDate = lastWeekdayOfMonth(year, monthNumber(target.month));
        break;
    }

    if (targetDate) {
      const candidate = earliestFutureAtTimes(targetDate, times, tz, now);
      if (candidate) return candidate;
    }
  }

  return null;
}

/**
 * Compute the most recent occurrence strictly before `now`.
 * Returns null if no previous occurrence exists (e.g., before a starting anchor
 * or for single dates in the future).
 */
export function previousFrom(schedule: ScheduleData, now: ZDT): ZDT | null {
  const tz = resolveTz(schedule.timezone);
  const anchor = schedule.anchor;

  // Parse exceptions once
  const parsedExceptions = parseExceptions(schedule.except);
  const hasExceptions = schedule.except.length > 0;
  const hasDuring = schedule.during.length > 0;

  // Retry loop for exceptions and during filter
  let current = now;
  for (let i = 0; i < 1000; i++) {
    const candidate = prevExpr(schedule, tz, anchor, current);

    if (candidate === null) return null;

    const cDate = candidate.withTimeZone(tz).toPlainDate();

    // Check starting anchor - if before anchor, no previous occurrence
    if (anchor) {
      const anchorDate = Temporal.PlainDate.from(anchor);
      if (Temporal.PlainDate.compare(cDate, anchorDate) < 0) {
        return null;
      }
    }

    // Apply until filter for previousFrom:
    // If candidate is after until, search earlier
    if (schedule.until) {
      const untilDate = resolveUntil(schedule.until, now);
      if (Temporal.PlainDate.compare(cDate, untilDate) > 0) {
        const endOfDay = toPlainTime({ hour: 23, minute: 59 });
        const skipTo = atTimeOnDate(untilDate, endOfDay, tz);
        current = skipTo.add({ seconds: 1 });
        continue;
      }
    }

    // Apply during filter
    if (hasDuring && !matchesDuring(cDate, schedule.during)) {
      const skipTo = prevDuringMonth(cDate, schedule.during);
      const endOfDay = toPlainTime({ hour: 23, minute: 59 });
      current = atTimeOnDate(skipTo, endOfDay, tz).add({
        seconds: 1,
      });
      continue;
    }

    // Apply except filter
    if (hasExceptions && isExceptedParsed(cDate, parsedExceptions)) {
      const prevDay = cDate.subtract({ days: 1 });
      const endOfDay = toPlainTime({ hour: 23, minute: 59 });
      current = atTimeOnDate(prevDay, endOfDay, tz).add({
        seconds: 1,
      });
      continue;
    }

    return candidate;
  }

  return null;
}

/**
 * Compute previous occurrence for the expression part.
 */
function prevExpr(
  schedule: ScheduleData,
  tz: string,
  anchor: string | null,
  now: ZDT,
): ZDT | null {
  const expr = schedule.expr;

  switch (expr.type) {
    case "dayRepeat":
      return prevDayRepeat(expr, tz, anchor, now);
    case "intervalRepeat":
      return prevIntervalRepeat(expr, tz, now);
    case "weekRepeat":
      return prevWeekRepeat(expr, tz, anchor, now);
    case "monthRepeat":
      return prevMonthRepeat(expr, tz, anchor, now);
    case "singleDate":
      return prevSingleDate(expr, tz, now);
    case "yearRepeat":
      return prevYearRepeat(expr, tz, anchor, now);
    default:
      return null;
  }
}

function prevDayRepeat(
  expr: Extract<ScheduleExpr, { type: "dayRepeat" }>,
  tz: string,
  anchor: string | null,
  now: ZDT,
): ZDT | null {
  const nowInTz = now.withTimeZone(tz);
  let date = nowInTz.toPlainDate();
  const { interval, days, times } = expr;

  if (interval <= 1) {
    // Check today for times that have passed
    if (matchesDayFilter(date, days)) {
      const candidate = latestPastAtTimes(date, times, tz, now);
      if (candidate !== null) return candidate;
    }
    // Go back day by day
    for (let i = 0; i < 8; i++) {
      date = date.subtract({ days: 1 });
      if (matchesDayFilter(date, days)) {
        const candidate = latestAtTimes(date, times, tz);
        if (candidate !== null) return candidate;
      }
    }
    return null;
  }

  // Interval > 1
  const anchorDate = anchor ? Temporal.PlainDate.from(anchor) : EPOCH_DATE;
  const offset = daysBetween(anchorDate, date);
  const remainder = ((offset % interval) + interval) % interval;
  const alignedDate =
    remainder === 0 ? date : date.subtract({ days: remainder });

  for (let i = 0; i < 2; i++) {
    const checkDate = alignedDate.subtract({ days: i * interval });
    const candidate = latestPastAtTimes(checkDate, times, tz, now);
    if (candidate !== null) return candidate;
    const latest = latestAtTimes(checkDate, times, tz);
    if (latest !== null && Temporal.ZonedDateTime.compare(latest, now) < 0) {
      return latest;
    }
  }

  return null;
}

function prevIntervalRepeat(
  expr: Extract<ScheduleExpr, { type: "intervalRepeat" }>,
  tz: string,
  now: ZDT,
): ZDT | null {
  const nowInTz = now.withTimeZone(tz);
  let date = nowInTz.toPlainDate();
  const { interval, unit, from, to, dayFilter } = expr;

  const stepMinutes = unit === "min" ? interval : interval * 60;
  const fromMinutes = from.hour * 60 + from.minute;
  const toMinutes = to.hour * 60 + to.minute;

  for (let d = 0; d < 8; d++) {
    if (dayFilter && !matchesDayFilter(date, dayFilter)) {
      date = date.subtract({ days: 1 });
      continue;
    }

    const nowMinutes =
      d === 0 ? nowInTz.hour * 60 + nowInTz.minute : toMinutes + 1;
    const searchUntil = Math.min(nowMinutes, toMinutes);

    if (searchUntil >= fromMinutes) {
      const slotsInRange = Math.floor(
        (searchUntil - fromMinutes) / stepMinutes,
      );
      let lastSlotMinutes = fromMinutes + slotsInRange * stepMinutes;

      if (d === 0 && lastSlotMinutes >= nowMinutes) {
        lastSlotMinutes -= stepMinutes;
      }

      if (lastSlotMinutes >= fromMinutes) {
        const h = Math.floor(lastSlotMinutes / 60);
        const m = lastSlotMinutes % 60;
        return atTimeOnDate(date, toPlainTime({ hour: h, minute: m }), tz);
      }
    }

    date = date.subtract({ days: 1 });
  }

  return null;
}

function prevWeekRepeat(
  expr: Extract<ScheduleExpr, { type: "weekRepeat" }>,
  tz: string,
  anchor: string | null,
  now: ZDT,
): ZDT | null {
  const nowInTz = now.withTimeZone(tz);
  const date = nowInTz.toPlainDate();
  const { interval, days, times } = expr;

  const dayOfWeek = date.dayOfWeek; // 1=Mon, 7=Sun
  const currentMonday = date.subtract({ days: dayOfWeek - 1 });

  const anchorDate = anchor ? Temporal.PlainDate.from(anchor) : EPOCH_MONDAY;
  const anchorDayOfWeek = anchorDate.dayOfWeek;
  const anchorMonday = anchorDate.subtract({ days: anchorDayOfWeek - 1 });

  // Sort days descending (latest first)
  const sortedDays = [...days].sort((a, b) => dayToNumber(b) - dayToNumber(a));

  let checkMonday = currentMonday;

  for (let w = 0; w < 54; w++) {
    const weeks = weeksBetween(anchorMonday, checkMonday);

    if (weeks < 0) {
      return null; // Before anchor
    }

    if (weeks % interval === 0) {
      for (const wd of sortedDays) {
        const dayNum = dayToNumber(wd);
        const targetDate = checkMonday.add({ days: dayNum - 1 });

        if (Temporal.PlainDate.compare(targetDate, date) < 0) {
          const candidate = latestAtTimes(targetDate, times, tz);
          if (candidate !== null) return candidate;
        } else if (Temporal.PlainDate.compare(targetDate, date) === 0) {
          const candidate = latestPastAtTimes(targetDate, times, tz, now);
          if (candidate !== null) return candidate;
        }
      }
    }

    checkMonday = checkMonday.subtract({ days: interval * 7 });
  }

  return null;
}

function prevMonthRepeat(
  expr: Extract<ScheduleExpr, { type: "monthRepeat" }>,
  tz: string,
  anchor: string | null,
  now: ZDT,
): ZDT | null {
  const nowInTz = now.withTimeZone(tz);
  const startDate = nowInTz.toPlainDate();
  const { interval, target, times } = expr;

  const anchorDate = anchor ? Temporal.PlainDate.from(anchor) : EPOCH_DATE;

  let year = startDate.year;
  let month = startDate.month;

  const maxIter = interval > 1 ? 24 * interval : 24;

  for (let i = 0; i < maxIter; i++) {
    if (interval > 1) {
      const monthOffset = monthsBetweenYM(
        anchorDate,
        Temporal.PlainDate.from({ year, month, day: 1 }),
      );
      if (monthOffset < 0 || monthOffset % interval !== 0) {
        ({ year, month } = prevMonth(year, month));
        continue;
      }
    }

    const targetDates = getMonthTargetDates(year, month, target);

    for (const d of targetDates.sort((a, b) =>
      Temporal.PlainDate.compare(b, a),
    )) {
      if (Temporal.PlainDate.compare(d, startDate) > 0) continue;
      if (Temporal.PlainDate.compare(d, startDate) === 0) {
        const candidate = latestPastAtTimes(d, times, tz, now);
        if (candidate !== null) return candidate;
      } else {
        const candidate = latestAtTimes(d, times, tz);
        if (candidate !== null) return candidate;
      }
    }

    ({ year, month } = prevMonth(year, month));
  }

  return null;
}

function prevSingleDate(
  expr: Extract<ScheduleExpr, { type: "singleDate" }>,
  tz: string,
  now: ZDT,
): ZDT | null {
  const nowInTz = now.withTimeZone(tz);
  const nowDate = nowInTz.toPlainDate();
  const { date: dateSpec, times } = expr;

  let targetDate: Temporal.PlainDate;

  if (dateSpec.type === "iso") {
    targetDate = Temporal.PlainDate.from(dateSpec.date);
    if (Temporal.PlainDate.compare(targetDate, nowDate) > 0) {
      return null; // Future date
    }
    if (Temporal.PlainDate.compare(targetDate, nowDate) === 0) {
      return latestPastAtTimes(targetDate, times, tz, now);
    }
    return latestAtTimes(targetDate, times, tz);
  } else {
    // Named date - find most recent occurrence
    const { month, day } = dateSpec;
    const monthNum = monthNumber(month);

    const thisYear = Temporal.PlainDate.from({
      year: nowDate.year,
      month: monthNum,
      day,
    });
    const lastYear = Temporal.PlainDate.from({
      year: nowDate.year - 1,
      month: monthNum,
      day,
    });

    if (Temporal.PlainDate.compare(thisYear, nowDate) < 0) {
      targetDate = thisYear;
    } else if (Temporal.PlainDate.compare(thisYear, nowDate) === 0) {
      const candidate = latestPastAtTimes(thisYear, times, tz, now);
      if (candidate !== null) return candidate;
      targetDate = lastYear;
    } else {
      targetDate = lastYear;
    }

    return latestAtTimes(targetDate, times, tz);
  }
}

function prevYearRepeat(
  expr: Extract<ScheduleExpr, { type: "yearRepeat" }>,
  tz: string,
  anchor: string | null,
  now: ZDT,
): ZDT | null {
  const nowInTz = now.withTimeZone(tz);
  const startDate = nowInTz.toPlainDate();
  const startYear = startDate.year;
  const { interval, target, times } = expr;

  const anchorYear = anchor
    ? Temporal.PlainDate.from(anchor).year
    : EPOCH_DATE.year;

  const maxIter = interval > 1 ? 8 * interval : 8;

  for (let y = 0; y < maxIter; y++) {
    const year = startYear - y;

    if (interval > 1) {
      const yearOffset = year - anchorYear;
      if (yearOffset < 0 || yearOffset % interval !== 0) {
        continue;
      }
    }

    const targetDate = getYearTargetDate(year, target);

    if (targetDate !== null) {
      if (Temporal.PlainDate.compare(targetDate, startDate) > 0) {
        continue; // Future
      }
      if (Temporal.PlainDate.compare(targetDate, startDate) === 0) {
        const candidate = latestPastAtTimes(targetDate, times, tz, now);
        if (candidate !== null) return candidate;
      } else {
        const candidate = latestAtTimes(targetDate, times, tz);
        if (candidate !== null) return candidate;
      }
    }
  }

  return null;
}

// Helper functions for prev*

function latestPastAtTimes(
  date: Temporal.PlainDate,
  times: TimeOfDay[],
  tz: string,
  now: ZDT,
): ZDT | null {
  const sortedTimes = [...times].sort(
    (a, b) => b.hour * 60 + b.minute - (a.hour * 60 + a.minute),
  );

  for (const tod of sortedTimes) {
    const t = toPlainTime(tod);
    const candidate = atTimeOnDate(date, t, tz);
    if (Temporal.ZonedDateTime.compare(candidate, now) < 0) {
      return candidate;
    }
  }
  return null;
}

function latestAtTimes(
  date: Temporal.PlainDate,
  times: TimeOfDay[],
  tz: string,
): ZDT | null {
  const sortedTimes = [...times].sort(
    (a, b) => a.hour * 60 + a.minute - (b.hour * 60 + b.minute),
  );

  if (sortedTimes.length === 0) return null;
  const latest = sortedTimes[sortedTimes.length - 1];
  return atTimeOnDate(date, toPlainTime(latest), tz);
}

function prevMonth(
  year: number,
  month: number,
): { year: number; month: number } {
  if (month === 1) {
    return { year: year - 1, month: 12 };
  }
  return { year, month: month - 1 };
}

function prevDuringMonth(
  date: Temporal.PlainDate,
  during: MonthName[],
): Temporal.PlainDate {
  let { year, month } = prevMonth(date.year, date.month);

  for (let i = 0; i < 12; i++) {
    const monthName = numberToMonthName(month);
    if (during.includes(monthName)) {
      return lastDayOfMonth(year, month);
    }
    ({ year, month } = prevMonth(year, month));
  }

  return date.subtract({ days: 1 });
}

function numberToMonthName(n: number): MonthName {
  const names: MonthName[] = [
    "jan",
    "feb",
    "mar",
    "apr",
    "may",
    "jun",
    "jul",
    "aug",
    "sep",
    "oct",
    "nov",
    "dec",
  ];
  return names[n - 1];
}

function getMonthTargetDates(
  year: number,
  month: number,
  target: MonthTarget,
): Temporal.PlainDate[] {
  switch (target.type) {
    case "days": {
      const expanded = expandMonthTarget(target);
      return expanded
        .map((d) => {
          try {
            return Temporal.PlainDate.from({ year, month, day: d });
          } catch {
            return null;
          }
        })
        .filter((d): d is Temporal.PlainDate => d !== null);
    }
    case "lastDay":
      return [lastDayOfMonth(year, month)];
    case "lastWeekday":
      return [lastWeekdayOfMonth(year, month)];
    case "nearestWeekday": {
      const d = nearestWeekday(year, month, target.day, target.direction);
      return d ? [d] : [];
    }
    case "ordinalWeekday": {
      const d = getOrdinalWeekday(year, month, target.ordinal, target.weekday);
      return d ? [d] : [];
    }
    default:
      return [];
  }
}

function getYearTargetDate(
  year: number,
  target: YearTarget,
): Temporal.PlainDate | null {
  switch (target.type) {
    case "date": {
      const monthNum = monthNumber(target.month);
      try {
        return Temporal.PlainDate.from({
          year,
          month: monthNum,
          day: target.day,
        });
      } catch {
        return null;
      }
    }
    case "ordinalWeekday": {
      const monthNum = monthNumber(target.month);
      return getOrdinalWeekday(year, monthNum, target.ordinal, target.weekday);
    }
    case "dayOfMonth": {
      const monthNum = monthNumber(target.month);
      try {
        return Temporal.PlainDate.from({
          year,
          month: monthNum,
          day: target.day,
        });
      } catch {
        return null;
      }
    }
    case "lastWeekday": {
      const monthNum = monthNumber(target.month);
      return lastWeekdayOfMonth(year, monthNum);
    }
    default:
      return null;
  }
}

function getOrdinalWeekday(
  year: number,
  month: number,
  ordinal: OrdinalPosition,
  day: Weekday,
): Temporal.PlainDate | null {
  if (ordinal === "last") {
    return lastWeekdayInMonth(year, month, day);
  }
  return nthWeekdayOfMonth(year, month, day, ordinalToN(ordinal));
}

function dayToNumber(day: Weekday): number {
  const map: Record<Weekday, number> = {
    monday: 1,
    tuesday: 2,
    wednesday: 3,
    thursday: 4,
    friday: 5,
    saturday: 6,
    sunday: 7,
  };
  return map[day];
}

// --- Iterator functions ---

/**
 * Returns a lazy iterator of occurrences starting after `from`.
 * The iterator is unbounded for repeating schedules (will iterate forever unless limited),
 * but respects the `until` clause if specified in the schedule.
 */
export function* occurrences(
  schedule: ScheduleData,
  from: ZDT,
): Generator<ZDT, void, unknown> {
  let current = from;
  for (;;) {
    const next = nextFrom(schedule, current);
    if (next === null) return;
    // Advance cursor by 1 minute to avoid returning same occurrence
    current = next.add({ minutes: 1 });
    yield next;
  }
}

/**
 * Returns a bounded iterator of occurrences where `from < occurrence <= to`.
 * The iterator yields occurrences strictly after `from` and up to and including `to`.
 */
export function* between(
  schedule: ScheduleData,
  from: ZDT,
  to: ZDT,
): Generator<ZDT, void, unknown> {
  for (const dt of occurrences(schedule, from)) {
    if (Temporal.ZonedDateTime.compare(dt, to) > 0) return;
    yield dt;
  }
}
