// Evaluator — computes next occurrences and matches for hron schedules.

import { Temporal } from "@js-temporal/polyfill";
import type {
  DayFilter,
  Exception,
  MonthName,
  MonthTarget,
  OrdinalPosition,
  ScheduleData,
  ScheduleExpr,
  TimeOfDay,
  UntilSpec,
  Weekday,
  YearTarget,
  DateSpec,
} from "./ast.js";
import {
  expandMonthTarget,
  monthNumber,
  ordinalToN,
  weekdayNumber,
} from "./ast.js";

type ZDT = Temporal.ZonedDateTime;
type PD = Temporal.PlainDate;

// --- Timezone resolution ---

function resolveTz(tz: string | null): string {
  if (tz) return tz;
  try {
    return Temporal.Now.timeZoneId();
  } catch {
    return "UTC";
  }
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

function lastWeekdayInMonth(
  year: number,
  month: number,
  weekday: Weekday,
): PD {
  const targetDow = weekdayNameToNumber(weekday);
  let d = lastDayOfMonth(year, month);
  while (d.dayOfWeek !== targetDow) {
    d = d.subtract({ days: 1 });
  }
  return d;
}

function epochMonday(): PD {
  return Temporal.PlainDate.from("1970-01-05");
}

function weeksBetween(a: PD, b: PD): number {
  const days = a.until(b, { largestUnit: "days" }).days;
  return Math.floor(days / 7);
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

function matchesDuring(date: PD, during: MonthName[]): boolean {
  if (during.length === 0) return true;
  return during.some((mn) => monthNumber(mn) === date.month);
}

function resolveUntil(until: UntilSpec, now: ZDT): PD {
  if (until.type === "iso") {
    return Temporal.PlainDate.from(until.date);
  }
  const year = now.toPlainDate().year;
  for (const y of [year, year + 1]) {
    try {
      const d = Temporal.PlainDate.from({
        year: y,
        month: monthNumber(until.month),
        day: until.day,
      }, { overflow: "reject" });
      if (Temporal.PlainDate.compare(d, now.toPlainDate()) >= 0) {
        return d;
      }
    } catch {
      // Invalid date, try next year
    }
  }
  return Temporal.PlainDate.from({
    year: year + 1,
    month: monthNumber(until.month),
    day: until.day,
  }, { overflow: "reject" });
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
      if (best === null || Temporal.ZonedDateTime.compare(candidate, best) < 0) {
        best = candidate;
      }
    }
  }
  return best;
}

// --- Public API ---

export function nextFrom(
  schedule: ScheduleData,
  now: ZDT,
): ZDT | null {
  const tz = resolveTz(schedule.timezone);

  const untilDate = schedule.until ? resolveUntil(schedule.until, now) : null;

  const hasExceptions = schedule.except.length > 0;
  const hasDuring = schedule.during.length > 0;

  let current = now;
  for (let i = 0; i < 1000; i++) {
    const candidate = nextExpr(schedule.expr, tz, schedule.anchor, current);

    if (candidate === null) return null;

    // Apply until filter
    if (untilDate) {
      const candidateInTz = candidate.withTimeZone(tz);
      if (
        Temporal.PlainDate.compare(candidateInTz.toPlainDate(), untilDate) > 0
      ) {
        return null;
      }
    }

    // Apply during filter
    if (hasDuring) {
      const candidateInTz = candidate.withTimeZone(tz);
      if (!matchesDuring(candidateInTz.toPlainDate(), schedule.during)) {
        const nextDay = candidateInTz.toPlainDate().add({ days: 1 });
        current = atTimeOnDate(
          nextDay,
          Temporal.PlainTime.from({ hour: 0, minute: 0 }),
          tz,
        ).subtract({ seconds: 1 });
        continue;
      }
    }

    // Apply except filter
    if (hasExceptions) {
      const candidateInTz = candidate.withTimeZone(tz);
      if (isExcepted(candidateInTz.toPlainDate(), schedule.except)) {
        const nextDay = candidateInTz.toPlainDate().add({ days: 1 });
        current = atTimeOnDate(
          nextDay,
          Temporal.PlainTime.from({ hour: 0, minute: 0 }),
          tz,
        ).subtract({ seconds: 1 });
        continue;
      }
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
): ZDT | null {
  switch (expr.type) {
    case "dayRepeat":
      return nextDayRepeat(expr.days, expr.times, tz, now);
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
      return nextWeekRepeat(expr.interval, expr.days, expr.times, tz, anchor, now);
    case "monthRepeat":
      return nextMonthRepeat(expr.target, expr.times, tz, now);
    case "ordinalRepeat":
      return nextOrdinalRepeat(expr.ordinal, expr.day, expr.times, tz, now);
    case "singleDate":
      return nextSingleDate(expr.date, expr.times, tz, now);
    case "yearRepeat":
      return nextYearRepeat(expr.target, expr.times, tz, now);
  }
}

export function nextNFrom(
  schedule: ScheduleData,
  now: ZDT,
  n: number,
): ZDT[] {
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

  const timeMatches = (times: TimeOfDay[]) =>
    times.some((tod) => zdt.hour === tod.hour && zdt.minute === tod.minute);

  switch (schedule.expr.type) {
    case "dayRepeat": {
      if (!matchesDayFilter(date, schedule.expr.days)) return false;
      return timeMatches(schedule.expr.times);
    }
    case "intervalRepeat": {
      const { interval, unit, from, to, dayFilter } = schedule.expr;
      if (dayFilter && !matchesDayFilter(date, dayFilter)) return false;
      const fromMinutes = from.hour * 60 + from.minute;
      const toMinutes = to.hour * 60 + to.minute;
      const currentMinutes = zdt.hour * 60 + zdt.minute;
      if (currentMinutes < fromMinutes || currentMinutes > toMinutes) return false;
      const diff = currentMinutes - fromMinutes;
      const step = unit === "min" ? interval : interval * 60;
      return diff >= 0 && diff % step === 0;
    }
    case "weekRepeat": {
      const { interval, days, times } = schedule.expr;
      const dow = date.dayOfWeek;
      if (!days.some((d) => weekdayNameToNumber(d) === dow)) return false;
      if (!timeMatches(times)) return false;
      const anchorDate = schedule.anchor
        ? Temporal.PlainDate.from(schedule.anchor)
        : epochMonday();
      const weeks = weeksBetween(anchorDate, date);
      return weeks >= 0 && weeks % interval === 0;
    }
    case "monthRepeat": {
      if (!timeMatches(schedule.expr.times)) return false;
      const { target } = schedule.expr;
      if (target.type === "days") {
        const expanded = expandMonthTarget(target);
        return expanded.includes(date.day);
      }
      if (target.type === "lastDay") {
        const last = lastDayOfMonth(date.year, date.month);
        return Temporal.PlainDate.compare(date, last) === 0;
      }
      const lastWd = lastWeekdayOfMonth(date.year, date.month);
      return Temporal.PlainDate.compare(date, lastWd) === 0;
    }
    case "ordinalRepeat": {
      if (!timeMatches(schedule.expr.times)) return false;
      const { ordinal, day } = schedule.expr;
      let targetDate: PD | null;
      if (ordinal === "last") {
        targetDate = lastWeekdayInMonth(date.year, date.month, day);
      } else {
        targetDate = nthWeekdayOfMonth(
          date.year,
          date.month,
          day,
          ordinalToN(ordinal),
        );
      }
      if (!targetDate) return false;
      return Temporal.PlainDate.compare(date, targetDate) === 0;
    }
    case "singleDate": {
      if (!timeMatches(schedule.expr.times)) return false;
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
      if (!timeMatches(schedule.expr.times)) return false;
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
  days: DayFilter,
  times: TimeOfDay[],
  tz: string,
  now: ZDT,
): ZDT | null {
  const nowInTz = now.withTimeZone(tz);
  let date = nowInTz.toPlainDate();

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

  let date = nowInTz.toPlainDate();

  for (let d = 0; d < 400; d++) {
    if (dayFilter && !matchesDayFilter(date, dayFilter)) {
      date = date.add({ days: 1 });
      continue;
    }

    const fromMinutes = from.hour * 60 + from.minute;
    const toMinutes = to.hour * 60 + to.minute;
    let currentMinutes = fromMinutes;

    while (currentMinutes <= toMinutes) {
      const h = Math.floor(currentMinutes / 60);
      const m = currentMinutes % 60;
      const t = Temporal.PlainTime.from({ hour: h, minute: m });
      const candidate = atTimeOnDate(date, t, tz);
      if (Temporal.ZonedDateTime.compare(candidate, now) > 0) {
        return candidate;
      }
      currentMinutes += stepMinutes;
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
  const anchorDate = anchor
    ? Temporal.PlainDate.from(anchor)
    : epochMonday();

  let date = nowInTz.toPlainDate();

  for (let d = 0; d < 1000; d++) {
    const dow = date.dayOfWeek;
    if (days.some((day) => weekdayNameToNumber(day) === dow)) {
      const weeks = weeksBetween(anchorDate, date);
      if (weeks >= 0 && weeks % interval === 0) {
        const candidate = earliestFutureAtTimes(date, times, tz, now);
        if (candidate) return candidate;
      }
    }
    date = date.add({ days: 1 });
  }

  return null;
}

function nextMonthRepeat(
  target: MonthTarget,
  times: TimeOfDay[],
  tz: string,
  now: ZDT,
): ZDT | null {
  const nowInTz = now.withTimeZone(tz);
  let year = nowInTz.year;
  let month = nowInTz.month;

  for (let i = 0; i < 24; i++) {
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
    } else {
      dateCandidates.push(lastWeekdayOfMonth(year, month));
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

function nextOrdinalRepeat(
  ordinal: OrdinalPosition,
  day: Weekday,
  times: TimeOfDay[],
  tz: string,
  now: ZDT,
): ZDT | null {
  const nowInTz = now.withTimeZone(tz);
  let year = nowInTz.year;
  let month = nowInTz.month;

  for (let i = 0; i < 24; i++) {
    let targetDate: PD | null;
    if (ordinal === "last") {
      targetDate = lastWeekdayInMonth(year, month, day);
    } else {
      targetDate = nthWeekdayOfMonth(year, month, day, ordinalToN(ordinal));
    }

    if (targetDate) {
      const candidate = earliestFutureAtTimes(targetDate, times, tz, now);
      if (candidate) return candidate;
    }

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
        const date = Temporal.PlainDate.from({
          year,
          month: monthNumber(dateSpec.month),
          day: dateSpec.day,
        }, { overflow: "reject" });
        const candidate = earliestFutureAtTimes(date, times, tz, now);
        if (candidate) return candidate;
      } catch {
        // invalid date
      }
    }
    return null;
  }

  // relative
  const targetDow = weekdayNameToNumber(dateSpec.weekday);
  let date = nowInTz.toPlainDate().add({ days: 1 });
  for (let i = 0; i < 7; i++) {
    if (date.dayOfWeek === targetDow) {
      return earliestFutureAtTimes(date, times, tz, now);
    }
    date = date.add({ days: 1 });
  }
  return null;
}

function nextYearRepeat(
  target: YearTarget,
  times: TimeOfDay[],
  tz: string,
  now: ZDT,
): ZDT | null {
  const nowInTz = now.withTimeZone(tz);
  const startYear = nowInTz.year;

  for (let y = 0; y < 8; y++) {
    const year = startYear + y;
    let targetDate: PD | null = null;

    switch (target.type) {
      case "date":
        try {
          targetDate = Temporal.PlainDate.from({
            year,
            month: monthNumber(target.month),
            day: target.day,
          }, { overflow: "reject" });
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
          targetDate = Temporal.PlainDate.from({
            year,
            month: monthNumber(target.month),
            day: target.day,
          }, { overflow: "reject" });
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
