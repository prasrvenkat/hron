// Type-checks the built package the way a consumer imports it, so a build
// tool change that alters the published declarations fails CI.
import { HronError, Schedule, type ScheduleExpr, Temporal } from "hron-ts";

const now: Temporal.ZonedDateTime = Temporal.Now.zonedDateTimeISO("UTC");
const schedule: Schedule = Schedule.parse("every day at 09:00");
const next: Temporal.ZonedDateTime | null = schedule.nextFrom(now);
const expr: ScheduleExpr = schedule.expression;
const valid: boolean = Schedule.validate("every day at 09:00");

try {
  Schedule.parse("every");
} catch (err) {
  if (err instanceof HronError) console.log(err.kind, err.displayRich());
}

console.log(next, expr, valid);
