export type Weekday =
  | "monday"
  | "tuesday"
  | "wednesday"
  | "thursday"
  | "friday"
  | "saturday"
  | "sunday";

export type MonthName =
  | "jan"
  | "feb"
  | "mar"
  | "apr"
  | "may"
  | "jun"
  | "jul"
  | "aug"
  | "sep"
  | "oct"
  | "nov"
  | "dec";

export type IntervalUnit = "min" | "hours";

export type OrdinalPosition =
  | "first"
  | "second"
  | "third"
  | "fourth"
  | "fifth"
  | "last";

export interface TimeOfDay {
  readonly hour: number;
  readonly minute: number;
}

export type DayFilter =
  | { readonly type: "every" }
  | { readonly type: "weekday" }
  | { readonly type: "weekend" }
  | { readonly type: "days"; readonly days: readonly Weekday[] };

export type DayOfMonthSpec =
  | { readonly type: "single"; readonly day: number }
  | { readonly type: "range"; readonly start: number; readonly end: number };

export type NearestDirection = "next" | "previous";

export type MonthTarget =
  | { readonly type: "days"; readonly specs: readonly DayOfMonthSpec[] }
  | { readonly type: "lastDay" }
  | { readonly type: "lastWeekday" }
  | {
      readonly type: "nearestWeekday";
      readonly day: number;
      /** Null stays in the month, as cron `W` does; a direction can cross into the adjacent month. */
      readonly direction: NearestDirection | null;
    }
  | {
      readonly type: "ordinalWeekday";
      readonly ordinal: OrdinalPosition;
      readonly weekday: Weekday;
    };

export type YearTarget =
  | { readonly type: "date"; readonly month: MonthName; readonly day: number }
  | {
      readonly type: "ordinalWeekday";
      readonly ordinal: OrdinalPosition;
      readonly weekday: Weekday;
      readonly month: MonthName;
    }
  | {
      readonly type: "dayOfMonth";
      readonly day: number;
      readonly month: MonthName;
    }
  | { readonly type: "lastWeekday"; readonly month: MonthName };

export type DateSpec =
  | { readonly type: "named"; readonly month: MonthName; readonly day: number }
  | { readonly type: "iso"; readonly date: string };

export type Exception =
  | { readonly type: "named"; readonly month: MonthName; readonly day: number }
  | { readonly type: "iso"; readonly date: string };

export type UntilSpec =
  | { readonly type: "iso"; readonly date: string }
  | { readonly type: "named"; readonly month: MonthName; readonly day: number };

export type ScheduleExpr =
  | {
      readonly type: "intervalRepeat";
      readonly interval: number;
      readonly unit: IntervalUnit;
      readonly from: TimeOfDay;
      readonly to: TimeOfDay;
      readonly dayFilter: DayFilter | null;
    }
  | {
      readonly type: "dayRepeat";
      readonly interval: number;
      readonly days: DayFilter;
      readonly times: readonly TimeOfDay[];
    }
  | {
      readonly type: "weekRepeat";
      readonly interval: number;
      readonly days: readonly Weekday[];
      readonly times: readonly TimeOfDay[];
    }
  | {
      readonly type: "monthRepeat";
      readonly interval: number;
      readonly target: MonthTarget;
      readonly times: readonly TimeOfDay[];
    }
  | {
      readonly type: "singleDate";
      readonly date: DateSpec;
      readonly times: readonly TimeOfDay[];
    }
  | {
      readonly type: "yearRepeat";
      readonly interval: number;
      readonly target: YearTarget;
      readonly times: readonly TimeOfDay[];
    };

export interface ScheduleData {
  readonly expression: ScheduleExpr;
  /** Null means UTC. */
  readonly timezone: string | null;
  readonly except: readonly Exception[];
  readonly until: UntilSpec | null;
  readonly starting: string | null;
  readonly during: readonly MonthName[];
}

export function weekdayNumber(day: Weekday): number {
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

export function cronDowNumber(day: Weekday): number {
  const map: Record<Weekday, number> = {
    sunday: 0,
    monday: 1,
    tuesday: 2,
    wednesday: 3,
    thursday: 4,
    friday: 5,
    saturday: 6,
  };
  return map[day];
}

export function weekdayFromNumber(n: number): Weekday | null {
  const map: Record<number, Weekday> = {
    1: "monday",
    2: "tuesday",
    3: "wednesday",
    4: "thursday",
    5: "friday",
    6: "saturday",
    7: "sunday",
  };
  return map[n] ?? null;
}

export function monthNumber(month: MonthName): number {
  const map: Record<MonthName, number> = {
    jan: 1,
    feb: 2,
    mar: 3,
    apr: 4,
    may: 5,
    jun: 6,
    jul: 7,
    aug: 8,
    sep: 9,
    oct: 10,
    nov: 11,
    dec: 12,
  };
  return map[month];
}

export function expandDaySpec(spec: DayOfMonthSpec): number[] {
  if (spec.type === "single") {
    return [spec.day];
  }
  const result: number[] = [];
  for (let d = spec.start; d <= spec.end; d++) {
    result.push(d);
  }
  return result;
}

export function expandMonthTarget(target: MonthTarget): number[] {
  if (target.type === "days") {
    return target.specs.flatMap(expandDaySpec);
  }
  return [];
}

export function ordinalToN(ord: OrdinalPosition): number {
  const map: Record<string, number> = {
    first: 1,
    second: 2,
    third: 3,
    fourth: 4,
    fifth: 5,
  };
  return map[ord];
}

export const ALL_WEEKDAYS: readonly Weekday[] = [
  "monday",
  "tuesday",
  "wednesday",
  "thursday",
  "friday",
];

export const ALL_WEEKEND: readonly Weekday[] = ["saturday", "sunday"];

export function newScheduleData(expr: ScheduleExpr): ScheduleData {
  return {
    expression: expr,
    timezone: null,
    except: [],
    until: null,
    starting: null,
    during: [],
  };
}
