// AST types for hron — TypeScript discriminated unions mirroring Rust enums.

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
  hour: number;
  minute: number;
}

// --- Day filter ---

export type DayFilter =
  | { type: "every" }
  | { type: "weekday" }
  | { type: "weekend" }
  | { type: "days"; days: Weekday[] };

// --- Day of month spec ---

export type DayOfMonthSpec =
  | { type: "single"; day: number }
  | { type: "range"; start: number; end: number };

// --- Month target ---

export type MonthTarget =
  | { type: "days"; specs: DayOfMonthSpec[] }
  | { type: "lastDay" }
  | { type: "lastWeekday" };

// --- Year target ---

export type YearTarget =
  | { type: "date"; month: MonthName; day: number }
  | {
      type: "ordinalWeekday";
      ordinal: OrdinalPosition;
      weekday: Weekday;
      month: MonthName;
    }
  | { type: "dayOfMonth"; day: number; month: MonthName }
  | { type: "lastWeekday"; month: MonthName };

// --- Date spec ---

export type DateSpec =
  | { type: "named"; month: MonthName; day: number }
  | { type: "iso"; date: string };

// --- Exception ---

export type Exception =
  | { type: "named"; month: MonthName; day: number }
  | { type: "iso"; date: string };

// --- Until spec ---

export type UntilSpec =
  | { type: "iso"; date: string }
  | { type: "named"; month: MonthName; day: number };

// --- Schedule expression ---

export type ScheduleExpr =
  | {
      type: "intervalRepeat";
      interval: number;
      unit: IntervalUnit;
      from: TimeOfDay;
      to: TimeOfDay;
      dayFilter: DayFilter | null;
    }
  | { type: "dayRepeat"; days: DayFilter; times: TimeOfDay[] }
  | {
      type: "weekRepeat";
      interval: number;
      days: Weekday[];
      times: TimeOfDay[];
    }
  | { type: "monthRepeat"; target: MonthTarget; times: TimeOfDay[] }
  | {
      type: "ordinalRepeat";
      ordinal: OrdinalPosition;
      day: Weekday;
      times: TimeOfDay[];
    }
  | { type: "singleDate"; date: DateSpec; times: TimeOfDay[] }
  | { type: "yearRepeat"; target: YearTarget; times: TimeOfDay[] };

// --- Schedule (top-level) ---

export interface ScheduleData {
  expr: ScheduleExpr;
  timezone: string | null;
  except: Exception[];
  until: UntilSpec | null;
  anchor: string | null; // ISO date string (YYYY-MM-DD)
  during: MonthName[];
}

// --- Helper functions ---

/** ISO 8601 day number: Monday=1, Sunday=7. */
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

/** Cron DOW number: Sunday=0, Monday=1, ..., Saturday=6. */
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

export function parseWeekday(s: string): Weekday | null {
  const map: Record<string, Weekday> = {
    monday: "monday",
    mon: "monday",
    tuesday: "tuesday",
    tue: "tuesday",
    wednesday: "wednesday",
    wed: "wednesday",
    thursday: "thursday",
    thu: "thursday",
    friday: "friday",
    fri: "friday",
    saturday: "saturday",
    sat: "saturday",
    sunday: "sunday",
    sun: "sunday",
  };
  return map[s.toLowerCase()] ?? null;
}

export function parseMonthName(s: string): MonthName | null {
  const map: Record<string, MonthName> = {
    january: "jan",
    jan: "jan",
    february: "feb",
    feb: "feb",
    march: "mar",
    mar: "mar",
    april: "apr",
    apr: "apr",
    may: "may",
    june: "jun",
    jun: "jun",
    july: "jul",
    jul: "jul",
    august: "aug",
    aug: "aug",
    september: "sep",
    sep: "sep",
    october: "oct",
    oct: "oct",
    november: "nov",
    nov: "nov",
    december: "dec",
    dec: "dec",
  };
  return map[s.toLowerCase()] ?? null;
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

export const ALL_WEEKDAYS: Weekday[] = [
  "monday",
  "tuesday",
  "wednesday",
  "thursday",
  "friday",
];

export const ALL_WEEKEND: Weekday[] = ["saturday", "sunday"];

export function newScheduleData(expr: ScheduleExpr): ScheduleData {
  return {
    expr,
    timezone: null,
    except: [],
    until: null,
    anchor: null,
    during: [],
  };
}
