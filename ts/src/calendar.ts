// Date arithmetic on the proleptic Gregorian calendar: no time zones, no
// schedules. A date is an epoch day, the whole days since 1970-01-01: a search
// can walk a 400-year calendar cycle (spec/README.md, "Search horizon"), and
// integer arithmetic keeps that fast where the Temporal polyfill costs
// microseconds per date.

import type {
  DayFilter,
  MonthTarget,
  NearestDirection,
  OrdinalPosition,
  Weekday,
  YearTarget,
} from "./ast.js";
import {
  expandMonthTarget,
  monthNumber,
  ordinalToN,
  weekdayNumber,
} from "./ast.js";

/** The remainder of `a / b` with the sign of `b`. */
export function mod(a: number, b: number): number {
  return ((a % b) + b) % b;
}

// epochDay and civil are days_from_civil and civil_from_days from
// https://howardhinnant.github.io/date_algorithms.html

export function epochDay(year: number, month: number, day: number): number {
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

export function civil(date: number): {
  year: number;
  month: number;
  day: number;
} {
  const z = date + 719468;
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

/** The date of a `YYYY-MM-DD` string the parser has validated. */
export function parseIsoDate(iso: string): number {
  const [year, month, day] = iso.split("-").map(Number);
  return epochDay(year, month, day);
}

/** ISO day of week of epoch day 0: 1970-01-01 was a Thursday. */
const EPOCH_WEEKDAY = 4;

/** ISO day of week: Monday=1, Sunday=7. */
function weekdayOf(date: number): number {
  return mod(date + EPOCH_WEEKDAY - 1, 7) + 1;
}

/** The year and month of a month index, the months since January of year 0. */
export function yearAndMonth(index: number): { year: number; month: number } {
  return { year: Math.floor(index / 12), month: mod(index, 12) + 1 };
}

/**
 * The Monday that starts week 0. Any Monday would do, since a cadence aligns
 * weeks to its own anchor; this is the first after the epoch.
 */
const WEEK_ZERO = epochDay(1970, 1, 5);

/** A unit of the calendar that periods count in. */
export type Unit = "day" | "week" | "month" | "year";

/**
 * The index of the `unit` holding `date`: its epoch day, weeks since Monday
 * 1970-01-05, months since January of year 0, or its year.
 */
export function unitIndex(unit: Unit, date: number): number {
  switch (unit) {
    case "day":
      return date;
    case "week":
      return Math.floor((date - WEEK_ZERO) / 7);
    case "month": {
      const { year, month } = civil(date);
      return year * 12 + month - 1;
    }
    case "year":
      return civil(date).year;
  }
}

/** The first date of the `unit` with `index`, the inverse of unitIndex. */
export function firstDateOfUnit(unit: Unit, index: number): number {
  switch (unit) {
    case "day":
      return index;
    case "week":
      return WEEK_ZERO + 7 * index;
    case "month": {
      const { year, month } = yearAndMonth(index);
      return epochDay(year, month, 1);
    }
    case "year":
      return epochDay(index, 1, 1);
  }
}

function isLeapYear(year: number): boolean {
  return (year % 4 === 0 && year % 100 !== 0) || year % 400 === 0;
}

function daysInMonth(year: number, month: number): number {
  if (month === 2) return isLeapYear(year) ? 29 : 28;
  return [4, 6, 9, 11].includes(month) ? 30 : 31;
}

export function matchesDayFilter(date: number, filter: DayFilter): boolean {
  const weekday = weekdayOf(date);
  switch (filter.type) {
    case "every":
      return true;
    case "weekday":
      return weekday <= 5;
    case "weekend":
      return weekday >= 6;
    case "days":
      return filter.days.some((d) => weekdayNumber(d) === weekday);
  }
}

/** The dates a monthly target names in a month, earliest first. */
export function monthTargetDates(
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

/** The date a yearly target names in a year, or null when that year lacks it. */
export function yearTargetDate(
  year: number,
  target: YearTarget,
): number | null {
  const month = monthNumber(target.month);
  switch (target.type) {
    case "date":
    case "dayOfMonth":
      return dateIn(year, month, target.day);
    case "ordinalWeekday":
      return ordinalWeekday(year, month, target.ordinal, target.weekday);
    case "lastWeekday":
      return lastWeekdayOfMonth(year, month);
  }
}

/** The date of `day` in a month, or null when the month is shorter. */
export function dateIn(
  year: number,
  month: number,
  day: number,
): number | null {
  return day <= daysInMonth(year, month) ? epochDay(year, month, day) : null;
}

function orNone(date: number | null): number[] {
  return date === null ? [] : [date];
}

function lastDayOfMonth(year: number, month: number): number {
  return epochDay(year, month, daysInMonth(year, month));
}

/** The last Monday to Friday of a month. */
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
 * The weekday nearest `day` of a month, or null when the month is shorter.
 * Without a direction it stays in the month, as cron's `W` does; with one it
 * can cross into the adjacent month (spec/README.md, "Nearest weekday and
 * `during`").
 */
function nearestWeekday(
  year: number,
  month: number,
  day: number,
  toward: NearestDirection | null,
): number | null {
  const length = daysInMonth(year, month);
  if (day > length) return null;
  const date = epochDay(year, month, day);
  const weekday = weekdayOf(date);
  if (weekday <= 5) return date;
  const saturday = weekday === 6;
  if (toward === "next") return date + (saturday ? 2 : 1);
  if (toward === "previous") return date - (saturday ? 1 : 2);
  if (saturday) return day === 1 ? date + 2 : date - 1;
  return day === length ? date - 2 : date + 1;
}
