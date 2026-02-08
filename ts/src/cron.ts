// Cron conversion — to_cron / from_cron for hron schedules.

import type {
  DayFilter,
  DayOfMonthSpec,
  ScheduleData,
  ScheduleExpr,
  Weekday,
} from "./ast.js";
import { cronDowNumber, newScheduleData } from "./ast.js";
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
      throw HronError.cron(
        "not expressible as cron (last weekday of month not supported)",
      );
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

/** Parse a 5-field cron expression into a ScheduleData. */
export function fromCron(cron: string): ScheduleData {
  const fields = cron.trim().split(/\s+/);
  if (fields.length !== 5) {
    throw HronError.cron(`expected 5 cron fields, got ${fields.length}`);
  }

  const [minuteField, hourField, domField, _monthField, dowField] = fields;

  // Minute interval: */N
  if (minuteField.startsWith("*/")) {
    const interval = parseInt(minuteField.slice(2), 10);
    if (Number.isNaN(interval)) throw HronError.cron("invalid minute interval");

    let fromHour = 0;
    let toHour = 23;

    if (hourField === "*") {
      // full day
    } else if (hourField.includes("-")) {
      const [start, end] = hourField.split("-");
      fromHour = parseInt(start, 10);
      toHour = parseInt(end, 10);
      if (Number.isNaN(fromHour) || Number.isNaN(toHour))
        throw HronError.cron("invalid hour range");
    } else {
      const h = parseInt(hourField, 10);
      if (Number.isNaN(h)) throw HronError.cron("invalid hour");
      fromHour = h;
      toHour = h;
    }

    const dayFilter = dowField === "*" ? null : parseCronDow(dowField);

    if (domField === "*") {
      const expr: ScheduleExpr = {
        type: "intervalRepeat",
        interval,
        unit: "min",
        from: { hour: fromHour, minute: 0 },
        to: { hour: toHour, minute: toHour === 23 ? 59 : 0 },
        dayFilter,
      };
      return newScheduleData(expr);
    }
  }

  // Hour interval: 0 */N
  if (hourField.startsWith("*/") && minuteField === "0") {
    const interval = parseInt(hourField.slice(2), 10);
    if (Number.isNaN(interval)) throw HronError.cron("invalid hour interval");
    if (domField === "*" && dowField === "*") {
      const expr: ScheduleExpr = {
        type: "intervalRepeat",
        interval,
        unit: "hours",
        from: { hour: 0, minute: 0 },
        to: { hour: 23, minute: 59 },
        dayFilter: null,
      };
      return newScheduleData(expr);
    }
  }

  // Standard time-based cron
  const minute = parseInt(minuteField, 10);
  if (Number.isNaN(minute))
    throw HronError.cron(`invalid minute field: ${minuteField}`);
  const hour = parseInt(hourField, 10);
  if (Number.isNaN(hour))
    throw HronError.cron(`invalid hour field: ${hourField}`);
  const time = { hour, minute };

  // DOM-based (monthly)
  if (domField !== "*" && dowField === "*") {
    if (domField.includes("-")) {
      throw HronError.cron(`DOM ranges not supported: ${domField}`);
    }
    const dayNums = domField.split(",").map((s) => {
      const n = parseInt(s, 10);
      if (Number.isNaN(n))
        throw HronError.cron(`invalid DOM field: ${domField}`);
      return n;
    });
    const specs: DayOfMonthSpec[] = dayNums.map((d) => ({
      type: "single" as const,
      day: d,
    }));
    const expr: ScheduleExpr = {
      type: "monthRepeat",
      interval: 1,
      target: { type: "days", specs },
      times: [time],
    };
    return newScheduleData(expr);
  }

  // DOW-based (day repeat)
  const days = parseCronDow(dowField);
  const expr: ScheduleExpr = {
    type: "dayRepeat",
    interval: 1,
    days,
    times: [time],
  };
  return newScheduleData(expr);
}

function parseCronDow(field: string): DayFilter {
  if (field === "*") return { type: "every" };
  if (field === "1-5") return { type: "weekday" };
  if (field === "0,6" || field === "6,0") return { type: "weekend" };

  if (field.includes("-")) {
    throw HronError.cron(`DOW ranges not supported: ${field}`);
  }

  const nums = field.split(",").map((s) => {
    const n = parseInt(s, 10);
    if (Number.isNaN(n)) throw HronError.cron(`invalid DOW field: ${field}`);
    return n;
  });

  const days: Weekday[] = nums.map((n) => cronDowToWeekday(n));
  return { type: "days", days };
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
  if (!result) throw HronError.cron(`invalid DOW number: ${n}`);
  return result;
}
