import type {
  DayFilter,
  DayOfMonthSpec,
  MonthName,
  MonthTarget,
  OrdinalPosition,
  ScheduleData,
  ScheduleExpr,
  TimeOfDay,
  Weekday,
  YearTarget,
} from "./ast.js";
import {
  ALL_WEEKDAYS,
  ALL_WEEKEND,
  cronDowNumber,
  expandMonthTarget,
  monthNumber,
  newScheduleData,
} from "./ast.js";
import { HronError } from "./error.js";
import { intervalSlots } from "./eval.js";
import { MINUTES_PER_HOUR, minuteOfDay } from "./wall-clock.js";

const MAX_LISTED_TIMES = 24;
const BOTH_DAYS_RESTRICTED =
  "not expressible in hron: cron fires on either the day of month or the day of week";
const INTERVAL_DAYS =
  "not expressible in hron: an interval runs only on every day, weekdays, the weekend or listed days";
const MINUTES_PER_DAY = 24 * MINUTES_PER_HOUR;
const TRIMMED = " \t\r\n";

// Digit strings may be of any length. Every number at or above this cap is out
// of every field's range and steps past every range's end, so saturating at it
// keeps each comparison exact.
const NUMBER_CAP = 1000;

const MONTHS: readonly MonthName[] = [
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
const DAY_NAMES = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"];
const WEEKDAYS: readonly Weekday[] = [
  "sunday",
  "monday",
  "tuesday",
  "wednesday",
  "thursday",
  "friday",
  "saturday",
];
const ORDINALS: readonly OrdinalPosition[] = [
  "first",
  "second",
  "third",
  "fourth",
  "fifth",
];

interface Field {
  name: string;
  min: number;
  max: number;
  // In the day of week, 7 is Sunday only where written: `*` and `a/n` end at 6.
  starEnd: number;
  names: readonly string[];
}

const MINUTE: Field = {
  name: "minute",
  min: 0,
  max: 59,
  starEnd: 59,
  names: [],
};
const HOUR: Field = { name: "hour", min: 0, max: 23, starEnd: 23, names: [] };
const DAY_OF_MONTH: Field = {
  name: "day of month",
  min: 1,
  max: 31,
  starEnd: 31,
  names: [],
};
const MONTH: Field = {
  name: "month",
  min: 1,
  max: 12,
  starEnd: 12,
  names: MONTHS,
};
const DAY_OF_WEEK: Field = {
  name: "day of week",
  min: 0,
  max: 7,
  starEnd: 6,
  names: DAY_NAMES,
};

type Bounds =
  | { type: "star" }
  | { type: "value"; a: string }
  | { type: "range"; a: string; b: string };

interface Item {
  bounds: Bounds;
  step: string | null;
}

type MonthDays =
  | { type: "any" }
  | { type: "days"; days: number[] }
  | { type: "last" }
  | { type: "lastWeekday" }
  | { type: "nearest"; day: number };

type WeekDays =
  | { type: "any" }
  | { type: "days"; days: number[] }
  | { type: "nth"; weekday: Weekday; n: number }
  | { type: "last"; weekday: Weekday };

type Days =
  | { type: "ofWeek"; filter: DayFilter }
  | { type: "ofMonth"; target: MonthTarget };

export function fromCron(input: string): ScheduleData {
  const trimmed = trimCron(input);
  const text = trimmed.startsWith("@") ? shortcut(trimmed) : trimmed;
  const fields = text.split(/[ \t]/).filter((field) => field !== "");
  if (fields.length !== 5) {
    throw HronError.cron(`expected 5 cron fields, got ${fields.length}`);
  }
  const [minute, hour, dayOfMonth, month, dayOfWeek] = fields;

  const minutes = sorted(values(minute, MINUTE));
  const hours = sorted(values(hour, HOUR));
  const monthDays = parseDayOfMonth(dayOfMonth);
  const months = sorted(values(month, MONTH));
  const weekDays = parseDayOfWeek(dayOfWeek);
  const days = dayExpression(monthDays, weekDays);
  const times: TimeOfDay[] = hours.flatMap((hour) =>
    minutes.map((minute) => ({ hour, minute })),
  );

  const gap = equalGap(times);
  let expr: ScheduleExpr;
  if (days.type === "ofWeek" && gap !== null) {
    expr = interval(times, gap, days.filter);
  } else if (times.length > MAX_LISTED_TIMES) {
    throw tooManyTimes(times.length, gap);
  } else {
    const target = yearTarget(days, months);
    if (target !== null) {
      expr = { type: "yearRepeat", interval: 1, target, times };
    } else if (days.type === "ofWeek") {
      expr = { type: "dayRepeat", interval: 1, days: days.filter, times };
    } else {
      expr = { type: "monthRepeat", interval: 1, target: days.target, times };
    }
  }
  const schedule = newScheduleData(expr);
  if (expr.type !== "yearRepeat" && months.length < MONTHS.length) {
    schedule.during = months.map((m) => MONTHS[m - 1]);
  }
  return schedule;
}

// Exactly the characters the spec trims; String.prototype.trim also strips
// Unicode spaces such as NBSP.
function trimCron(text: string): string {
  let start = 0;
  let end = text.length;
  while (start < end && TRIMMED.includes(text[start])) start++;
  while (end > start && TRIMMED.includes(text[end - 1])) end--;
  return text.slice(start, end);
}

function shortcut(input: string): string {
  switch (asciiLowercase(input)) {
    case "@yearly":
    case "@annually":
      return "0 0 1 1 *";
    case "@monthly":
      return "0 0 1 * *";
    case "@weekly":
      return "0 0 * * 0";
    case "@daily":
    case "@midnight":
      return "0 0 * * *";
    case "@hourly":
      return "0 * * * *";
    default:
      throw HronError.cron(`unknown cron shortcut: ${input}`);
  }
}

function parseDayOfMonth(text: string): MonthDays {
  if (text === "*" || text === "?") {
    return { type: "any" };
  }
  if (equalsIgnoringAsciiCase(text, "L")) {
    return { type: "last" };
  }
  if (equalsIgnoringAsciiCase(text, "LW")) {
    return { type: "lastWeekday" };
  }
  const day = text.slice(0, -1);
  if ((text.endsWith("W") || text.endsWith("w")) && isNumber(day)) {
    return { type: "nearest", day: fieldValue(day, DAY_OF_MONTH) };
  }
  return { type: "days", days: values(text, DAY_OF_MONTH) };
}

function parseDayOfWeek(text: string): WeekDays {
  const field = DAY_OF_WEEK;
  if (text === "*" || text === "?") {
    return { type: "any" };
  }
  const hash = text.indexOf("#");
  if (hash >= 0) {
    const day = text.slice(0, hash);
    const nth = text.slice(hash + 1);
    if (isValue(day, field) && isNumber(nth)) {
      const weekday = WEEKDAYS[fieldValue(day, field) % 7];
      const n = number(nth);
      if (n < 1 || n > 5) {
        throw HronError.cron(`day of week ordinal must be 1-5, got ${nth}`);
      }
      return { type: "nth", weekday, n };
    }
  }
  const day = text.slice(0, -1);
  if ((text.endsWith("L") || text.endsWith("l")) && isValue(day, field)) {
    return { type: "last", weekday: WEEKDAYS[fieldValue(day, field) % 7] };
  }
  return { type: "days", days: values(text, field) };
}

// Keeps the order of first appearance, in which fromCron lists days of the week.
function values(text: string, field: Field): number[] {
  const parsed = items(text, field);
  if (parsed === null) {
    throw HronError.cron(`invalid ${field.name}: ${text}`);
  }
  const values: number[] = [];
  for (const item of parsed) {
    let first: number;
    let last: number;
    const { bounds } = item;
    if (bounds.type === "star") {
      first = field.min;
      last = field.starEnd;
    } else if (bounds.type === "value") {
      first = fieldValue(bounds.a, field);
      // `7/n` starts past the end of `*`, so it is Sunday alone.
      last = item.step === null ? first : Math.max(first, field.starEnd);
    } else {
      first = fieldValue(bounds.a, field);
      last = fieldValue(bounds.b, field);
      if (first > last) {
        throw HronError.cron(
          `${field.name} range must not run backwards: ${bounds.a}-${bounds.b}`,
        );
      }
    }
    const step = item.step === null ? 1 : number(item.step);
    if (step === 0) {
      throw HronError.cron(`${field.name} step must be at least 1`);
    }
    for (let n = first; n <= last; n += step) {
      const value = field === DAY_OF_WEEK ? n % 7 : n;
      if (!values.includes(value)) {
        values.push(value);
      }
    }
  }
  return values;
}

function items(text: string, field: Field): Item[] | null {
  const parsed: Item[] = [];
  for (const item of text.split(",")) {
    const slash = item.indexOf("/");
    const range = slash < 0 ? item : item.slice(0, slash);
    const step = slash < 0 ? null : item.slice(slash + 1);
    const dash = range.indexOf("-");
    let bounds: Bounds;
    if (range === "*") {
      bounds = { type: "star" };
    } else if (dash >= 0) {
      bounds = {
        type: "range",
        a: range.slice(0, dash),
        b: range.slice(dash + 1),
      };
    } else {
      bounds = { type: "value", a: range };
    }
    const valid =
      (step === null || isNumber(step)) &&
      (bounds.type === "star" ||
        (bounds.type === "value" && isValue(bounds.a, field)) ||
        (bounds.type === "range" &&
          isValue(bounds.a, field) &&
          isValue(bounds.b, field)));
    if (!valid) {
      return null;
    }
    parsed.push({ bounds, step });
  }
  return parsed;
}

function isNumber(text: string): boolean {
  return /^[0-9]+$/.test(text);
}

function isValue(text: string, field: Field): boolean {
  return isNumber(text) || nameValue(text, field) !== null;
}

function nameValue(text: string, field: Field): number | null {
  const index = field.names.findIndex((name) =>
    equalsIgnoringAsciiCase(name, text),
  );
  return index < 0 ? null : index + field.min;
}

// Never parseInt or Number: they accept signs, whitespace and exponents, and
// lose precision past 2^53.
function number(digits: string): number {
  let n = 0;
  for (let i = 0; i < digits.length; i++) {
    n = Math.min(n * 10 + digits.charCodeAt(i) - 48, NUMBER_CAP);
  }
  return n;
}

function fieldValue(text: string, field: Field): number {
  const value = nameValue(text, field) ?? number(text);
  if (value < field.min || value > field.max) {
    throw HronError.cron(
      `${field.name} must be ${field.min}-${field.max}, got ${text}`,
    );
  }
  return value;
}

// toLowerCase would also fold non-ASCII letters, so `ſ` (U+017F) or `K`
// (U+212A) could match an ASCII name.
function asciiLowercase(text: string): string {
  return text.replace(/[A-Z]/g, (c) =>
    String.fromCharCode(c.charCodeAt(0) + 32),
  );
}

function equalsIgnoringAsciiCase(a: string, b: string): boolean {
  return a.length === b.length && asciiLowercase(a) === asciiLowercase(b);
}

function dayExpression(monthDays: MonthDays, weekDays: WeekDays): Days {
  if (monthDays.type === "any") {
    switch (weekDays.type) {
      case "any":
        return { type: "ofWeek", filter: { type: "every" } };
      case "days":
        return { type: "ofWeek", filter: weekdayFilter(weekDays.days) };
      case "nth":
        return {
          type: "ofMonth",
          target: {
            type: "ordinalWeekday",
            ordinal: ORDINALS[weekDays.n - 1],
            weekday: weekDays.weekday,
          },
        };
      case "last":
        return {
          type: "ofMonth",
          target: {
            type: "ordinalWeekday",
            ordinal: "last",
            weekday: weekDays.weekday,
          },
        };
    }
  }
  if (weekDays.type !== "any") {
    throw HronError.cron(BOTH_DAYS_RESTRICTED);
  }
  switch (monthDays.type) {
    case "days": {
      if (monthDays.days.length === 31) {
        return { type: "ofWeek", filter: { type: "every" } };
      }
      const specs = runs(sorted(monthDays.days)).map(
        ([first, last]): DayOfMonthSpec =>
          first === last
            ? { type: "single", day: first }
            : { type: "range", start: first, end: last },
      );
      return { type: "ofMonth", target: { type: "days", specs } };
    }
    case "last":
      return { type: "ofMonth", target: { type: "lastDay" } };
    case "lastWeekday":
      return { type: "ofMonth", target: { type: "lastWeekday" } };
    case "nearest":
      return {
        type: "ofMonth",
        target: { type: "nearestWeekday", day: monthDays.day, direction: null },
      };
  }
}

function weekdayFilter(days: number[]): DayFilter {
  switch (sorted(days).join(",")) {
    case "0,1,2,3,4,5,6":
      return { type: "every" };
    case "1,2,3,4,5":
      return { type: "weekday" };
    case "0,6":
      return { type: "weekend" };
    default:
      return { type: "days", days: days.map((d) => WEEKDAYS[d]) };
  }
}

function equalGap(times: TimeOfDay[]): number | null {
  const minutes = times.map(minuteOfDay);
  if (minutes.length < 2) {
    return null;
  }
  const gap = minutes[1] - minutes[0];
  const equal =
    minutes.length >= 3 &&
    minutes.every((minute, i) => i === 0 || minute - minutes[i - 1] === gap);
  return equal ? gap : null;
}

function interval(
  times: TimeOfDay[],
  gap: number,
  days: DayFilter,
): ScheduleExpr {
  const from = times[0];
  const last = times[times.length - 1];
  const fromMidnight = from.hour === 0 && from.minute === 0;
  const to =
    fromMidnight && minuteOfDay(last) + gap >= MINUTES_PER_DAY
      ? { hour: 23, minute: 59 }
      : last;
  const hours = gap % MINUTES_PER_HOUR === 0;
  return {
    type: "intervalRepeat",
    interval: hours ? gap / MINUTES_PER_HOUR : gap,
    unit: hours ? "hours" : "min",
    from,
    to,
    dayFilter: days.type === "every" ? null : days,
  };
}

function tooManyTimes(count: number, gap: number | null): HronError {
  if (gap !== null) {
    return HronError.cron(INTERVAL_DAYS);
  }
  return HronError.cron(
    `not expressible in hron: ${count} times a day are too many to list`,
  );
}

function yearTarget(days: Days, months: number[]): YearTarget | null {
  if (days.type !== "ofMonth" || months.length !== 1) {
    return null;
  }
  const { target } = days;
  const month = MONTHS[months[0] - 1];
  switch (target.type) {
    case "days": {
      const [spec] = target.specs;
      if (
        target.specs.length === 1 &&
        spec.type === "single" &&
        spec.day <= maxDay(month)
      ) {
        return { type: "date", month, day: spec.day };
      }
      return null;
    }
    case "lastWeekday":
      return { type: "lastWeekday", month };
    case "ordinalWeekday":
      return {
        type: "ordinalWeekday",
        ordinal: target.ordinal,
        weekday: target.weekday,
        month,
      };
    default:
      return null;
  }
}

function maxDay(month: MonthName): number {
  switch (month) {
    case "feb":
      return 29;
    case "apr":
    case "jun":
    case "sep":
    case "nov":
      return 30;
    default:
      return 31;
  }
}

export function toCron(schedule: ScheduleData): string {
  if (schedule.except.length > 0) {
    throw notExpressible("except clauses not supported");
  }
  if (schedule.until) {
    throw notExpressible("until clauses not supported");
  }
  if (schedule.anchor) {
    throw notExpressible("starting clauses not supported");
  }
  const [dayOfMonth, dayOfWeek] = dayFields(schedule.expr);
  // ScheduleData built in code can hold an empty day list, which writes an empty field.
  if (dayOfMonth === "" || dayOfWeek === "") {
    throw notExpressible("schedule has no days");
  }
  const month = monthField(schedule);
  const [minute, hour] = timeFields(schedule.expr);
  return `${minute} ${hour} ${dayOfMonth} ${month} ${dayOfWeek}`;
}

function notExpressible(reason: string): HronError {
  return HronError.cron(`not expressible as cron: ${reason}`);
}

function repeatsOnce(interval: number, unit: string): void {
  if (interval > 1) {
    throw notExpressible(`multi-${unit} repeats not supported`);
  }
}

function dayFields(expr: ScheduleExpr): [string, string] {
  switch (expr.type) {
    case "intervalRepeat":
      return ["*", expr.dayFilter === null ? "*" : filterField(expr.dayFilter)];
    case "dayRepeat":
      repeatsOnce(expr.interval, "day");
      return ["*", filterField(expr.days)];
    case "weekRepeat":
      repeatsOnce(expr.interval, "week");
      return ["*", weekdaysField(expr.days)];
    case "monthRepeat": {
      repeatsOnce(expr.interval, "month");
      const { target } = expr;
      switch (target.type) {
        case "days":
          return [listField(sortedUnique(expandMonthTarget(target)), 31), "*"];
        case "lastDay":
          return ["L", "*"];
        case "lastWeekday":
          return ["LW", "*"];
        case "nearestWeekday":
          if (target.direction !== null) {
            throw notExpressible("directional nearest weekday not supported");
          }
          return [`${target.day}W`, "*"];
        case "ordinalWeekday":
          return ["*", ordinalField(target.ordinal, target.weekday)];
      }
      break;
    }
    case "yearRepeat": {
      repeatsOnce(expr.interval, "year");
      const { target } = expr;
      switch (target.type) {
        case "date":
        case "dayOfMonth":
          return [String(target.day), "*"];
        case "ordinalWeekday":
          return ["*", ordinalField(target.ordinal, target.weekday)];
        case "lastWeekday":
          return ["LW", "*"];
      }
      break;
    }
    case "singleDate":
      if (expr.date.type === "iso") {
        throw notExpressible("ISO dates do not repeat");
      }
      return [String(expr.date.day), "*"];
  }
}

function monthField(schedule: ScheduleData): string {
  const { during } = schedule;
  const month = ownMonth(schedule.expr);
  if (month !== null) {
    if (during.length > 0 && !during.includes(month)) {
      throw notExpressible("during excludes the schedule's month");
    }
    return String(monthNumber(month));
  }
  if (during.length === 0) {
    return "*";
  }
  return listField(sortedUnique(during.map(monthNumber)), 12);
}

function ownMonth(expr: ScheduleExpr): MonthName | null {
  if (expr.type === "yearRepeat") {
    return expr.target.month;
  }
  if (expr.type === "singleDate" && expr.date.type === "named") {
    return expr.date.month;
  }
  return null;
}

function timeFields(expr: ScheduleExpr): [string, string] {
  const times = dailyTimes(expr);
  const minutes = sortedUnique(times.map((t) => t % MINUTES_PER_HOUR));
  const hours = sortedUnique(
    times.map((t) => Math.floor(t / MINUTES_PER_HOUR)),
  );
  // ScheduleData built in code can hold no times, which no cron writes.
  if (times.length === 0) {
    throw notExpressible("schedule has no times");
  }
  if (minutes.length * hours.length !== times.length) {
    throw notExpressible(
      "times are not every combination of their minutes and hours",
    );
  }
  return [stepField(minutes, 60), stepField(hours, 24)];
}

function dailyTimes(expr: ScheduleExpr): number[] {
  if (expr.type === "intervalRepeat") {
    return sortedUnique(intervalSlots(expr));
  }
  return sortedUnique(expr.times.map(minuteOfDay));
}

function filterField(filter: DayFilter): string {
  switch (filter.type) {
    case "every":
      return "*";
    case "weekday":
      return weekdaysField(ALL_WEEKDAYS);
    case "weekend":
      return weekdaysField(ALL_WEEKEND);
    case "days":
      return weekdaysField(filter.days);
  }
}

function weekdaysField(days: Weekday[]): string {
  return listField(sortedUnique(days.map(cronDowNumber)), 7);
}

function ordinalField(ordinal: OrdinalPosition, weekday: Weekday): string {
  const day = cronDowNumber(weekday);
  const index = ORDINALS.indexOf(ordinal);
  return index < 0 ? `${day}L` : `${day}#${index + 1}`;
}

function stepField(values: number[], size: number): string {
  const first = values[0];
  const last = values[values.length - 1];
  const gap = values.length > 1 ? values[1] - first : null;
  const equalGaps =
    gap !== null &&
    values.every((value, i) => i === 0 || value - values[i - 1] === gap);
  if (values.length === size) {
    return "*";
  }
  if (gap === null) {
    return String(first);
  }
  if (equalGaps && first === 0 && last + gap === size) {
    return `*/${gap}`;
  }
  if (equalGaps && gap === 1) {
    return `${first}-${last}`;
  }
  if (equalGaps && values.length >= 3) {
    return `${first}-${last}/${gap}`;
  }
  return listField(values, size);
}

function listField(values: number[], size: number): string {
  if (values.length === size) {
    return "*";
  }
  return runs(values)
    .map(([first, last]) => (first === last ? `${first}` : `${first}-${last}`))
    .join(",");
}

function runs(sortedValues: number[]): [number, number][] {
  const runs: [number, number][] = [];
  for (const value of sortedValues) {
    const run = runs[runs.length - 1];
    if (run !== undefined && run[1] + 1 === value) {
      run[1] = value;
    } else {
      runs.push([value, value]);
    }
  }
  return runs;
}

function sorted(values: number[]): number[] {
  return [...values].sort((a, b) => a - b);
}

function sortedUnique(values: number[]): number[] {
  return sorted([...new Set(values)]);
}
