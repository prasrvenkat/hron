// Same checks as consumer.ts, resolved through the package's require condition.
import {
  type DateSpec,
  type DayFilter,
  type DayOfMonthSpec,
  type Exception,
  HronError,
  type IntervalUnit,
  type MonthName,
  type MonthTarget,
  type NearestDirection,
  type OrdinalPosition,
  Schedule,
  type ScheduleExpr,
  Temporal,
  type TimeOfDay,
  type UntilSpec,
  type Weekday,
  type YearTarget,
} from "hron-ts";

const now: Temporal.ZonedDateTime = Temporal.Now.zonedDateTimeISO("UTC");
const schedule: Schedule = Schedule.parse("every day at 09:00");
const next: Temporal.ZonedDateTime | null = schedule.nextFrom(now);
const fromInstant: Temporal.ZonedDateTime | null = schedule.nextFrom(
  Temporal.Now.instant(),
);
const expr: ScheduleExpr = schedule.expression;
if (expr.type === "dayRepeat") {
  // @ts-expect-error: a schedule's expression is read-only
  expr.times[0].hour = 25;
  // @ts-expect-error: a schedule's expression is read-only
  expr.times.push({ hour: 10, minute: 0 });
  // @ts-expect-error: a schedule's expression is read-only
  expr.interval = 2;
}
const except: readonly Exception[] = schedule.except;
const until: UntilSpec | null = schedule.until;
const starting: string | null = schedule.starting;
const during: readonly MonthName[] = schedule.during;
// @ts-expect-error: a schedule's except dates are read-only
except.push({ type: "iso", date: "2026-12-25" });
// @ts-expect-error: a schedule's during months are read-only
during.push("jan");
if (until?.type === "iso") {
  // @ts-expect-error: a schedule's until date is read-only
  until.date = "2026-12-25";
}
// @ts-expect-error: a schedule's starting date cannot be set
schedule.starting = "2026-01-01";
const direction: NearestDirection = "next";
// Names the part types nothing else here uses, so each stays a checked export.
const partTypes:
  | [
      DateSpec,
      DayFilter,
      DayOfMonthSpec,
      IntervalUnit,
      MonthTarget,
      OrdinalPosition,
      TimeOfDay,
      Weekday,
      YearTarget,
    ]
  | null = null;
// @ts-expect-error: the parts are read through the getters, not exported as one type
const parts: import("hron-ts").ScheduleData | null = null;
const same: boolean = schedule.equals(Schedule.parse("every day at 9:00"));
const valid: boolean = Schedule.validate("every day at 09:00");

try {
  Schedule.parse("every");
} catch (err) {
  if (err instanceof HronError) console.log(err.kind, err.displayRich());
}

console.log(
  next,
  fromInstant,
  expr,
  starting,
  direction,
  partTypes,
  parts,
  same,
  valid,
);
