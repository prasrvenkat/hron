// Cron conversion — to_cron / from_cron for hron schedules.

import type {
  DayFilter,
  DayOfMonthSpec,
  MonthName,
  MonthTarget,
  OrdinalPosition,
  ScheduleData,
  TimeOfDay,
  Weekday,
} from "./ast.js";
import {
  ALL_WEEKDAYS,
  ALL_WEEKEND,
  cronDowNumber,
  monthNumber,
  newScheduleData,
  parseMonthName,
  weekdayNumber,
} from "./ast.js";
import { HronError } from "./error.js";

/** Convert a Schedule to a 5-field cron expression. */
export function toCron(schedule: ScheduleData): string {
  if (schedule.except.length > 0) {
    throw HronError.cron(
      "not expressible as cron (except clauses not supported)",
    );
  }
  if (schedule.until) {
    throw HronError.cron(
      "not expressible as cron (until clauses not supported)",
    );
  }
  if (schedule.during.length > 0) {
    throw HronError.cron(
      "not expressible as cron (during clauses not supported)",
    );
  }

  const expr = schedule.expr;

  switch (expr.type) {
    case "dayRepeat": {
      if (expr.interval > 1) {
        throw HronError.cron(
          "not expressible as cron (multi-day intervals not supported)",
        );
      }
      if (expr.times.length !== 1) {
        throw HronError.cron(
          "not expressible as cron (multiple times not supported)",
        );
      }
      const time = expr.times[0];
      const dow = dayFilterToCronDow(expr.days);
      return `${time.minute} ${time.hour} * * ${dow}`;
    }

    case "intervalRepeat": {
      const fullDay =
        expr.from.hour === 0 &&
        expr.from.minute === 0 &&
        expr.to.hour === 23 &&
        expr.to.minute === 59;
      if (!fullDay) {
        throw HronError.cron(
          "not expressible as cron (partial-day interval windows not supported)",
        );
      }
      if (expr.dayFilter) {
        throw HronError.cron(
          "not expressible as cron (interval with day filter not supported)",
        );
      }

      if (expr.unit === "min") {
        if (60 % expr.interval !== 0) {
          throw HronError.cron(
            `not expressible as cron (*/${expr.interval} breaks at hour boundaries)`,
          );
        }
        return `*/${expr.interval} * * * *`;
      }
      // hours
      return `0 */${expr.interval} * * *`;
    }

    case "weekRepeat":
      throw HronError.cron(
        "not expressible as cron (multi-week intervals not supported)",
      );

    case "monthRepeat": {
      if (expr.interval > 1) {
        throw HronError.cron(
          "not expressible as cron (multi-month intervals not supported)",
        );
      }
      if (expr.times.length !== 1) {
        throw HronError.cron(
          "not expressible as cron (multiple times not supported)",
        );
      }
      const time = expr.times[0];
      const { target } = expr;
      if (target.type === "days") {
        const expanded = target.specs.flatMap((s) => {
          if (s.type === "single") return [s.day];
          const r: number[] = [];
          for (let d = s.start; d <= s.end; d++) r.push(d);
          return r;
        });
        const dom = expanded.join(",");
        return `${time.minute} ${time.hour} ${dom} * *`;
      }
      if (target.type === "lastDay") {
        throw HronError.cron(
          "not expressible as cron (last day of month not supported)",
        );
      }
      if (target.type === "lastWeekday") {
        throw HronError.cron(
          "not expressible as cron (last weekday of month not supported)",
        );
      }
      // nearestWeekday
      if (target.direction !== null) {
        throw HronError.cron(
          "not expressible as cron (directional nearest weekday not supported)",
        );
      }
      return `${time.minute} ${time.hour} ${target.day}W * *`;
    }

    case "ordinalRepeat":
      throw HronError.cron(
        "not expressible as cron (ordinal weekday of month not supported)",
      );

    case "singleDate":
      throw HronError.cron(
        "not expressible as cron (single dates are not repeating)",
      );

    case "yearRepeat":
      throw HronError.cron(
        "not expressible as cron (yearly schedules not supported in 5-field cron)",
      );
  }
}

function dayFilterToCronDow(filter: DayFilter): string {
  switch (filter.type) {
    case "every":
      return "*";
    case "weekday":
      return "1-5";
    case "weekend":
      return "0,6";
    case "days": {
      const nums = filter.days.map((d) => cronDowNumber(d));
      nums.sort((a, b) => a - b);
      return nums.join(",");
    }
  }
}

// ============================================================================
// fromCron: Parse 5-field cron expressions (and @ shortcuts)
// ============================================================================

/** Parse a 5-field cron expression into a ScheduleData. */
export function fromCron(cron: string): ScheduleData {
  const trimmed = cron.trim();

  // Handle @ shortcuts first
  if (trimmed.startsWith("@")) {
    return parseCronShortcut(trimmed);
  }

  const fields = trimmed.split(/\s+/);
  if (fields.length !== 5) {
    throw HronError.cron(`expected 5 cron fields, got ${fields.length}`);
  }

  const [minuteField, hourField, domFieldRaw, monthField, dowFieldRaw] = fields;

  // Normalize ? to * (semantically equivalent for our purposes)
  const domField = domFieldRaw === "?" ? "*" : domFieldRaw;
  const dowField = dowFieldRaw === "?" ? "*" : dowFieldRaw;

  // Parse month field into during clause
  const during = parseMonthField(monthField);

  // Check for special DOW patterns: nth weekday (#), last weekday (5L)
  const nthWeekdayResult = tryParseNthWeekday(
    minuteField,
    hourField,
    domField,
    dowField,
    during,
  );
  if (nthWeekdayResult) return nthWeekdayResult;

  // Check for L (last day) or LW (last weekday) in DOM
  const lastDayResult = tryParseLastDay(
    minuteField,
    hourField,
    domField,
    dowField,
    during,
  );
  if (lastDayResult) return lastDayResult;

  // Check for W (nearest weekday): e.g., 15W, 1W
  if (domField.endsWith("W") && domField !== "LW") {
    const nearestWeekdayResult = tryParseNearestWeekday(
      minuteField,
      hourField,
      domField,
      dowField,
      during,
    );
    if (nearestWeekdayResult) return nearestWeekdayResult;
  }

  // Check for interval patterns: */N or range/N
  const intervalResult = tryParseInterval(
    minuteField,
    hourField,
    domField,
    dowField,
    during,
  );
  if (intervalResult) return intervalResult;

  // Standard time-based cron
  const minute = parseSingleValue(minuteField, "minute", 0, 59);
  const hour = parseSingleValue(hourField, "hour", 0, 23);
  const time: TimeOfDay = { hour, minute };

  // DOM-based (monthly) - when DOM is specified and DOW is *
  if (domField !== "*" && dowField === "*") {
    const target = parseDomField(domField);
    const schedule = newScheduleData({
      type: "monthRepeat",
      interval: 1,
      target,
      times: [time],
    });
    schedule.during = during;
    return schedule;
  }

  // DOW-based (day repeat)
  const days = parseCronDow(dowField);
  const schedule = newScheduleData({
    type: "dayRepeat",
    interval: 1,
    days,
    times: [time],
  });
  schedule.during = during;
  return schedule;
}

/** Parse @ shortcuts like @daily, @hourly, etc. */
function parseCronShortcut(cron: string): ScheduleData {
  switch (cron.toLowerCase()) {
    case "@yearly":
    case "@annually":
      return newScheduleData({
        type: "yearRepeat",
        interval: 1,
        target: { type: "date", month: "jan", day: 1 },
        times: [{ hour: 0, minute: 0 }],
      });
    case "@monthly":
      return newScheduleData({
        type: "monthRepeat",
        interval: 1,
        target: { type: "days", specs: [{ type: "single", day: 1 }] },
        times: [{ hour: 0, minute: 0 }],
      });
    case "@weekly":
      return newScheduleData({
        type: "dayRepeat",
        interval: 1,
        days: { type: "days", days: ["sunday"] },
        times: [{ hour: 0, minute: 0 }],
      });
    case "@daily":
    case "@midnight":
      return newScheduleData({
        type: "dayRepeat",
        interval: 1,
        days: { type: "every" },
        times: [{ hour: 0, minute: 0 }],
      });
    case "@hourly":
      return newScheduleData({
        type: "intervalRepeat",
        interval: 1,
        unit: "hours",
        from: { hour: 0, minute: 0 },
        to: { hour: 23, minute: 59 },
        dayFilter: null,
      });
    default:
      throw HronError.cron(`unknown @ shortcut: ${cron}`);
  }
}

/** Parse month field into a MonthName[] for the `during` clause. */
function parseMonthField(field: string): MonthName[] {
  if (field === "*") return [];

  const months: MonthName[] = [];

  for (const part of field.split(",")) {
    // Check for step values FIRST (e.g., 1-12/3 or */3)
    if (part.includes("/")) {
      const [rangePart, stepStr] = part.split("/");
      let start: number, end: number;

      if (rangePart === "*") {
        start = 1;
        end = 12;
      } else if (rangePart.includes("-")) {
        const [s, e] = rangePart.split("-");
        start = monthNumber(parseMonthValue(s));
        end = monthNumber(parseMonthValue(e));
      } else {
        throw HronError.cron(`invalid month step expression: ${part}`);
      }

      const step = parseInt(stepStr, 10);
      if (Number.isNaN(step)) {
        throw HronError.cron(`invalid month step value: ${stepStr}`);
      }
      if (step === 0) {
        throw HronError.cron("step cannot be 0");
      }

      for (let n = start; n <= end; n += step) {
        months.push(monthFromNumber(n));
      }
    } else if (part.includes("-")) {
      // Range like 1-3 or JAN-MAR
      const [startStr, endStr] = part.split("-");
      const startMonth = parseMonthValue(startStr);
      const endMonth = parseMonthValue(endStr);
      const startNum = monthNumber(startMonth);
      const endNum = monthNumber(endMonth);

      if (startNum > endNum) {
        throw HronError.cron(`invalid month range: ${startStr} > ${endStr}`);
      }

      for (let n = startNum; n <= endNum; n++) {
        months.push(monthFromNumber(n));
      }
    } else {
      // Single month
      months.push(parseMonthValue(part));
    }
  }

  return months;
}

/** Parse a single month value (number 1-12 or name JAN-DEC). */
function parseMonthValue(s: string): MonthName {
  // Try as number first
  const n = parseInt(s, 10);
  if (!Number.isNaN(n)) {
    return monthFromNumber(n);
  }
  // Try as name
  const name = parseMonthName(s);
  if (!name) {
    throw HronError.cron(`invalid month: ${s}`);
  }
  return name;
}

function monthFromNumber(n: number): MonthName {
  const map: Record<number, MonthName> = {
    1: "jan",
    2: "feb",
    3: "mar",
    4: "apr",
    5: "may",
    6: "jun",
    7: "jul",
    8: "aug",
    9: "sep",
    10: "oct",
    11: "nov",
    12: "dec",
  };
  const result = map[n];
  if (!result) {
    throw HronError.cron(`invalid month number: ${n}`);
  }
  return result;
}

/** Try to parse nth weekday patterns like 1#1 (first Monday) or 5L (last Friday). */
function tryParseNthWeekday(
  minuteField: string,
  hourField: string,
  domField: string,
  dowField: string,
  during: MonthName[],
): ScheduleData | null {
  // Check for # pattern (nth weekday of month)
  if (dowField.includes("#")) {
    const [dowStr, nthStr] = dowField.split("#");
    const dowNum = parseDowValue(dowStr);
    const weekday = cronDowToWeekday(dowNum);
    const nth = parseInt(nthStr, 10);

    if (Number.isNaN(nth) || nth < 1 || nth > 5) {
      throw HronError.cron(`nth must be 1-5, got ${nthStr}`);
    }

    if (domField !== "*" && domField !== "?") {
      throw HronError.cron("DOM must be * when using # for nth weekday");
    }

    const minute = parseSingleValue(minuteField, "minute", 0, 59);
    const hour = parseSingleValue(hourField, "hour", 0, 23);

    const ordinalMap: Record<number, OrdinalPosition> = {
      1: "first",
      2: "second",
      3: "third",
      4: "fourth",
      5: "fifth",
    };

    const schedule = newScheduleData({
      type: "ordinalRepeat",
      interval: 1,
      ordinal: ordinalMap[nth],
      day: weekday,
      times: [{ hour, minute }],
    });
    schedule.during = during;
    return schedule;
  }

  // Check for nL pattern (last weekday of month, e.g., 5L = last Friday)
  if (dowField.endsWith("L") && dowField.length > 1) {
    const dowStr = dowField.slice(0, -1);
    const dowNum = parseDowValue(dowStr);
    const weekday = cronDowToWeekday(dowNum);

    if (domField !== "*" && domField !== "?") {
      throw HronError.cron("DOM must be * when using nL for last weekday");
    }

    const minute = parseSingleValue(minuteField, "minute", 0, 59);
    const hour = parseSingleValue(hourField, "hour", 0, 23);

    const schedule = newScheduleData({
      type: "ordinalRepeat",
      interval: 1,
      ordinal: "last",
      day: weekday,
      times: [{ hour, minute }],
    });
    schedule.during = during;
    return schedule;
  }

  return null;
}

/** Try to parse L (last day) or LW (last weekday) patterns. */
function tryParseLastDay(
  minuteField: string,
  hourField: string,
  domField: string,
  dowField: string,
  during: MonthName[],
): ScheduleData | null {
  if (domField !== "L" && domField !== "LW") {
    return null;
  }

  if (dowField !== "*" && dowField !== "?") {
    throw HronError.cron("DOW must be * when using L or LW in DOM");
  }

  const minute = parseSingleValue(minuteField, "minute", 0, 59);
  const hour = parseSingleValue(hourField, "hour", 0, 23);

  const target: MonthTarget =
    domField === "LW" ? { type: "lastWeekday" } : { type: "lastDay" };

  const schedule = newScheduleData({
    type: "monthRepeat",
    interval: 1,
    target,
    times: [{ hour, minute }],
  });
  schedule.during = during;
  return schedule;
}

/** Try to parse W (nearest weekday) patterns: 15W, 1W, etc. */
function tryParseNearestWeekday(
  minuteField: string,
  hourField: string,
  domField: string,
  dowField: string,
  during: MonthName[],
): ScheduleData | null {
  if (!domField.endsWith("W") || domField === "LW") {
    return null;
  }

  if (dowField !== "*" && dowField !== "?") {
    throw HronError.cron("DOW must be * when using W in DOM");
  }

  const dayStr = domField.slice(0, -1);
  const day = parseInt(dayStr, 10);

  if (Number.isNaN(day)) {
    throw HronError.cron(`invalid W day: ${dayStr}`);
  }

  if (day < 1 || day > 31) {
    throw HronError.cron(`W day must be 1-31, got ${day}`);
  }

  const minute = parseSingleValue(minuteField, "minute", 0, 59);
  const hour = parseSingleValue(hourField, "hour", 0, 23);

  const target: MonthTarget = {
    type: "nearestWeekday",
    day,
    direction: null,
  };

  const schedule = newScheduleData({
    type: "monthRepeat",
    interval: 1,
    target,
    times: [{ hour, minute }],
  });
  schedule.during = during;
  return schedule;
}

/** Try to parse interval patterns: star/N, range/N in minute or hour fields. */
function tryParseInterval(
  minuteField: string,
  hourField: string,
  domField: string,
  dowField: string,
  during: MonthName[],
): ScheduleData | null {
  // Minute interval: */N or range/N
  if (minuteField.includes("/")) {
    const [rangePart, stepStr] = minuteField.split("/");
    const interval = parseInt(stepStr, 10);

    if (Number.isNaN(interval)) {
      throw HronError.cron("invalid minute interval value");
    }
    if (interval === 0) {
      throw HronError.cron("step cannot be 0");
    }

    let fromMinute: number, toMinute: number;
    if (rangePart === "*") {
      fromMinute = 0;
      toMinute = 59;
    } else if (rangePart.includes("-")) {
      const [s, e] = rangePart.split("-");
      fromMinute = parseInt(s, 10);
      toMinute = parseInt(e, 10);
      if (Number.isNaN(fromMinute) || Number.isNaN(toMinute)) {
        throw HronError.cron("invalid minute range");
      }
      if (fromMinute > toMinute) {
        throw HronError.cron(
          `range start must be <= end: ${fromMinute}-${toMinute}`,
        );
      }
    } else {
      // Single value with step
      fromMinute = parseInt(rangePart, 10);
      if (Number.isNaN(fromMinute)) {
        throw HronError.cron("invalid minute value");
      }
      toMinute = 59;
    }

    // Determine the hour window
    let fromHour: number, toHour: number;
    if (hourField === "*") {
      fromHour = 0;
      toHour = 23;
    } else if (hourField.includes("-") && !hourField.includes("/")) {
      const [s, e] = hourField.split("-");
      fromHour = parseInt(s, 10);
      toHour = parseInt(e, 10);
      if (Number.isNaN(fromHour) || Number.isNaN(toHour)) {
        throw HronError.cron("invalid hour range");
      }
    } else if (hourField.includes("/")) {
      // Hour also has step - complex, skip
      return null;
    } else {
      const h = parseInt(hourField, 10);
      if (Number.isNaN(h)) {
        throw HronError.cron("invalid hour");
      }
      fromHour = h;
      toHour = h;
    }

    const dayFilter = dowField === "*" ? null : parseCronDow(dowField);

    if (domField === "*" || domField === "?") {
      // Determine end minute based on context
      let endMinute: number;
      if (fromMinute === 0 && toMinute === 59 && toHour === 23) {
        // Full day: 00:00 to 23:59
        endMinute = 59;
      } else if (fromMinute === 0 && toMinute === 59) {
        // Partial day with full minutes range: use :00 for cleaner output
        endMinute = 0;
      } else {
        endMinute = toMinute;
      }

      const schedule = newScheduleData({
        type: "intervalRepeat",
        interval,
        unit: "min",
        from: { hour: fromHour, minute: fromMinute },
        to: { hour: toHour, minute: endMinute },
        dayFilter,
      });
      schedule.during = during;
      return schedule;
    }
  }

  // Hour interval: 0 */N or 0 range/N
  if (
    hourField.includes("/") &&
    (minuteField === "0" || minuteField === "00")
  ) {
    const [rangePart, stepStr] = hourField.split("/");
    const interval = parseInt(stepStr, 10);

    if (Number.isNaN(interval)) {
      throw HronError.cron("invalid hour interval value");
    }
    if (interval === 0) {
      throw HronError.cron("step cannot be 0");
    }

    let fromHour: number, toHour: number;
    if (rangePart === "*") {
      fromHour = 0;
      toHour = 23;
    } else if (rangePart.includes("-")) {
      const [s, e] = rangePart.split("-");
      fromHour = parseInt(s, 10);
      toHour = parseInt(e, 10);
      if (Number.isNaN(fromHour) || Number.isNaN(toHour)) {
        throw HronError.cron("invalid hour range");
      }
      if (fromHour > toHour) {
        throw HronError.cron(
          `range start must be <= end: ${fromHour}-${toHour}`,
        );
      }
    } else {
      fromHour = parseInt(rangePart, 10);
      if (Number.isNaN(fromHour)) {
        throw HronError.cron("invalid hour value");
      }
      toHour = 23;
    }

    if (
      (domField === "*" || domField === "?") &&
      (dowField === "*" || dowField === "?")
    ) {
      // Use :59 only for full day (00:00 to 23:59), otherwise use :00
      const endMinute = fromHour === 0 && toHour === 23 ? 59 : 0;

      const schedule = newScheduleData({
        type: "intervalRepeat",
        interval,
        unit: "hours",
        from: { hour: fromHour, minute: 0 },
        to: { hour: toHour, minute: endMinute },
        dayFilter: null,
      });
      schedule.during = during;
      return schedule;
    }
  }

  return null;
}

/** Parse a DOM field into a MonthTarget. */
function parseDomField(field: string): MonthTarget {
  const specs: DayOfMonthSpec[] = [];

  for (const part of field.split(",")) {
    if (part.includes("/")) {
      // Step value: 1-31/2 or */5
      const [rangePart, stepStr] = part.split("/");
      let start: number, end: number;

      if (rangePart === "*") {
        start = 1;
        end = 31;
      } else if (rangePart.includes("-")) {
        const [s, e] = rangePart.split("-");
        start = parseInt(s, 10);
        end = parseInt(e, 10);
        if (Number.isNaN(start)) {
          throw HronError.cron(`invalid DOM range start: ${s}`);
        }
        if (Number.isNaN(end)) {
          throw HronError.cron(`invalid DOM range end: ${e}`);
        }
        if (start > end) {
          throw HronError.cron(`range start must be <= end: ${start}-${end}`);
        }
      } else {
        start = parseInt(rangePart, 10);
        if (Number.isNaN(start)) {
          throw HronError.cron(`invalid DOM value: ${rangePart}`);
        }
        end = 31;
      }

      const step = parseInt(stepStr, 10);
      if (Number.isNaN(step)) {
        throw HronError.cron(`invalid DOM step: ${stepStr}`);
      }
      if (step === 0) {
        throw HronError.cron("step cannot be 0");
      }

      validateDom(start);
      validateDom(end);

      for (let d = start; d <= end; d += step) {
        specs.push({ type: "single", day: d });
      }
    } else if (part.includes("-")) {
      // Range: 1-5
      const [startStr, endStr] = part.split("-");
      const start = parseInt(startStr, 10);
      const end = parseInt(endStr, 10);
      if (Number.isNaN(start)) {
        throw HronError.cron(`invalid DOM range start: ${startStr}`);
      }
      if (Number.isNaN(end)) {
        throw HronError.cron(`invalid DOM range end: ${endStr}`);
      }
      if (start > end) {
        throw HronError.cron(`range start must be <= end: ${start}-${end}`);
      }
      validateDom(start);
      validateDom(end);
      specs.push({ type: "range", start, end });
    } else {
      // Single: 15
      const day = parseInt(part, 10);
      if (Number.isNaN(day)) {
        throw HronError.cron(`invalid DOM value: ${part}`);
      }
      validateDom(day);
      specs.push({ type: "single", day });
    }
  }

  return { type: "days", specs };
}

function validateDom(day: number): void {
  if (day < 1 || day > 31) {
    throw HronError.cron(`DOM must be 1-31, got ${day}`);
  }
}

/** Parse a DOW field into a DayFilter. */
function parseCronDow(field: string): DayFilter {
  if (field === "*") return { type: "every" };

  const days: Weekday[] = [];

  for (const part of field.split(",")) {
    if (part.includes("/")) {
      // Step value: 0-6/2 or */2
      const [rangePart, stepStr] = part.split("/");
      let start: number, end: number;

      if (rangePart === "*") {
        start = 0;
        end = 6;
      } else if (rangePart.includes("-")) {
        const [s, e] = rangePart.split("-");
        start = parseDowValueRaw(s);
        end = parseDowValueRaw(e);
        if (start > end) {
          throw HronError.cron(`range start must be <= end: ${s}-${e}`);
        }
      } else {
        start = parseDowValueRaw(rangePart);
        end = 6;
      }

      const step = parseInt(stepStr, 10);
      if (Number.isNaN(step)) {
        throw HronError.cron(`invalid DOW step: ${stepStr}`);
      }
      if (step === 0) {
        throw HronError.cron("step cannot be 0");
      }

      for (let d = start; d <= end; d += step) {
        const normalized = d === 7 ? 0 : d;
        days.push(cronDowToWeekday(normalized));
      }
    } else if (part.includes("-")) {
      // Range: 1-5 or MON-FRI (parse without normalizing 7 for range checking)
      const [startStr, endStr] = part.split("-");
      const start = parseDowValueRaw(startStr);
      const end = parseDowValueRaw(endStr);
      if (start > end) {
        throw HronError.cron(
          `range start must be <= end: ${startStr}-${endStr}`,
        );
      }
      for (let d = start; d <= end; d++) {
        // Normalize 7 to 0 (Sunday) when converting to weekday
        const normalized = d === 7 ? 0 : d;
        days.push(cronDowToWeekday(normalized));
      }
    } else {
      // Single: 1 or MON
      const dow = parseDowValue(part);
      days.push(cronDowToWeekday(dow));
    }
  }

  // Check for special patterns
  if (days.length === 5) {
    const sorted = [...days].sort(
      (a, b) => weekdayNumber(a) - weekdayNumber(b),
    );
    const weekdays = [...ALL_WEEKDAYS].sort(
      (a, b) => weekdayNumber(a) - weekdayNumber(b),
    );
    if (JSON.stringify(sorted) === JSON.stringify(weekdays)) {
      return { type: "weekday" };
    }
  }
  if (days.length === 2) {
    const sorted = [...days].sort(
      (a, b) => weekdayNumber(a) - weekdayNumber(b),
    );
    const weekend = [...ALL_WEEKEND].sort(
      (a, b) => weekdayNumber(a) - weekdayNumber(b),
    );
    if (JSON.stringify(sorted) === JSON.stringify(weekend)) {
      return { type: "weekend" };
    }
  }

  return { type: "days", days };
}

/** Parse a DOW value (number 0-7 or name SUN-SAT), normalizing 7 to 0. */
function parseDowValue(s: string): number {
  const raw = parseDowValueRaw(s);
  // Normalize 7 to 0 (both mean Sunday)
  return raw === 7 ? 0 : raw;
}

/** Parse a DOW value without normalizing 7 to 0 (for range checking). */
function parseDowValueRaw(s: string): number {
  // Try as number first
  const n = parseInt(s, 10);
  if (!Number.isNaN(n)) {
    if (n > 7) {
      throw HronError.cron(`DOW must be 0-7, got ${n}`);
    }
    return n;
  }
  // Try as name
  const map: Record<string, number> = {
    SUN: 0,
    MON: 1,
    TUE: 2,
    WED: 3,
    THU: 4,
    FRI: 5,
    SAT: 6,
  };
  const result = map[s.toUpperCase()];
  if (result === undefined) {
    throw HronError.cron(`invalid DOW: ${s}`);
  }
  return result;
}

function cronDowToWeekday(n: number): Weekday {
  const map: Record<number, Weekday> = {
    0: "sunday",
    1: "monday",
    2: "tuesday",
    3: "wednesday",
    4: "thursday",
    5: "friday",
    6: "saturday",
    7: "sunday",
  };
  const result = map[n];
  if (!result) {
    throw HronError.cron(`invalid DOW number: ${n}`);
  }
  return result;
}

/** Parse a single numeric value with validation. */
function parseSingleValue(
  field: string,
  name: string,
  min: number,
  max: number,
): number {
  const value = parseInt(field, 10);
  if (Number.isNaN(value)) {
    throw HronError.cron(`invalid ${name} field: ${field}`);
  }
  if (value < min || value > max) {
    throw HronError.cron(`${name} must be ${min}-${max}, got ${value}`);
  }
  return value;
}
