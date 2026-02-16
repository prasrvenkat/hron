// Display (toString) for hron schedules — produces canonical form for roundtrip.

import type {
  DayFilter,
  DayOfMonthSpec,
  IntervalUnit,
  ScheduleData,
  ScheduleExpr,
  TimeOfDay,
  Weekday,
} from "./ast.js";

/** Render a schedule as its canonical string form. */
export function display(schedule: ScheduleData): string {
  let out = displayExpr(schedule.expr);

  // Trailing clauses in order: except, until, starting, during, timezone
  if (schedule.except.length > 0) {
    out += " except ";
    out += schedule.except
      .map((exc) => {
        if (exc.type === "named") return `${exc.month} ${exc.day}`;
        return exc.date;
      })
      .join(", ");
  }

  if (schedule.until) {
    if (schedule.until.type === "iso") {
      out += ` until ${schedule.until.date}`;
    } else {
      out += ` until ${schedule.until.month} ${schedule.until.day}`;
    }
  }

  if (schedule.anchor) {
    out += ` starting ${schedule.anchor}`;
  }

  if (schedule.during.length > 0) {
    out += ` during ${schedule.during.join(", ")}`;
  }

  if (schedule.timezone) {
    out += ` in ${schedule.timezone}`;
  }

  return out;
}

function displayExpr(expr: ScheduleExpr): string {
  switch (expr.type) {
    case "intervalRepeat": {
      let out = `every ${expr.interval} ${unitDisplay(expr.interval, expr.unit)}`;
      out += ` from ${formatTime(expr.from)} to ${formatTime(expr.to)}`;
      if (expr.dayFilter) {
        out += ` on ${displayDayFilter(expr.dayFilter)}`;
      }
      return out;
    }
    case "dayRepeat":
      if (expr.interval > 1) {
        return `every ${expr.interval} days at ${formatTimeList(expr.times)}`;
      }
      return `every ${displayDayFilter(expr.days)} at ${formatTimeList(expr.times)}`;
    case "weekRepeat":
      return `every ${expr.interval} weeks on ${formatDayList(expr.days)} at ${formatTimeList(expr.times)}`;
    case "monthRepeat": {
      let targetStr: string;
      if (expr.target.type === "days") {
        targetStr = formatOrdinalDaySpecs(expr.target.specs);
      } else if (expr.target.type === "lastDay") {
        targetStr = "last day";
      } else if (expr.target.type === "lastWeekday") {
        targetStr = "last weekday";
      } else if (expr.target.type === "ordinalWeekday") {
        targetStr = `${expr.target.ordinal} ${expr.target.weekday}`;
      } else if (expr.target.type === "nearestWeekday") {
        const { day, direction } = expr.target;
        const dirPrefix = direction ? `${direction} ` : "";
        targetStr = `${dirPrefix}nearest weekday to ${day}${ordinalSuffix(day)}`;
      } else {
        throw new Error(
          `unknown month target type: ${(expr.target as { type: string }).type}`,
        );
      }
      if (expr.interval > 1) {
        return `every ${expr.interval} months on the ${targetStr} at ${formatTimeList(expr.times)}`;
      }
      return `every month on the ${targetStr} at ${formatTimeList(expr.times)}`;
    }
    case "singleDate": {
      let dateStr: string;
      if (expr.date.type === "named") {
        dateStr = `${expr.date.month} ${expr.date.day}`;
      } else {
        dateStr = expr.date.date;
      }
      return `on ${dateStr} at ${formatTimeList(expr.times)}`;
    }
    case "yearRepeat": {
      let targetStr: string;
      if (expr.target.type === "date") {
        targetStr = `${expr.target.month} ${expr.target.day}`;
      } else if (expr.target.type === "ordinalWeekday") {
        targetStr = `the ${expr.target.ordinal} ${expr.target.weekday} of ${expr.target.month}`;
      } else if (expr.target.type === "dayOfMonth") {
        targetStr = `the ${expr.target.day}${ordinalSuffix(expr.target.day)} of ${expr.target.month}`;
      } else if (expr.target.type === "lastWeekday") {
        targetStr = `the last weekday of ${expr.target.month}`;
      } else {
        throw new Error(
          `unknown year target type: ${(expr.target as { type: string }).type}`,
        );
      }
      if (expr.interval > 1) {
        return `every ${expr.interval} years on ${targetStr} at ${formatTimeList(expr.times)}`;
      }
      return `every year on ${targetStr} at ${formatTimeList(expr.times)}`;
    }
    default: {
      const _exhaustive: never = expr;
      throw new Error(
        `unknown expression type: ${(_exhaustive as { type: string }).type}`,
      );
    }
  }
}

function displayDayFilter(filter: DayFilter): string {
  switch (filter.type) {
    case "every":
      return "day";
    case "weekday":
      return "weekday";
    case "weekend":
      return "weekend";
    case "days":
      return formatDayList(filter.days);
    default: {
      const _exhaustive: never = filter;
      throw new Error(
        `unknown day filter type: ${(_exhaustive as { type: string }).type}`,
      );
    }
  }
}

function formatTime(t: TimeOfDay): string {
  return `${String(t.hour).padStart(2, "0")}:${String(t.minute).padStart(2, "0")}`;
}

function formatTimeList(times: TimeOfDay[]): string {
  return times.map(formatTime).join(", ");
}

function formatDayList(days: Weekday[]): string {
  return days.join(", ");
}

function formatOrdinalDaySpecs(specs: DayOfMonthSpec[]): string {
  return specs
    .map((spec) => {
      if (spec.type === "single") {
        return `${spec.day}${ordinalSuffix(spec.day)}`;
      }
      return `${spec.start}${ordinalSuffix(spec.start)} to ${spec.end}${ordinalSuffix(spec.end)}`;
    })
    .join(", ");
}

export function ordinalSuffix(n: number): string {
  const mod100 = n % 100;
  if (mod100 >= 11 && mod100 <= 13) return "th";
  switch (n % 10) {
    case 1:
      return "st";
    case 2:
      return "nd";
    case 3:
      return "rd";
    default:
      return "th";
  }
}

function unitDisplay(interval: number, unit: IntervalUnit): string {
  if (unit === "min") {
    return interval === 1 ? "minute" : "min";
  }
  return interval === 1 ? "hour" : "hours";
}
