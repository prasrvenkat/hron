// Type-checks the built package the way a consumer imports it, so a build
// tool change that alters the published declarations fails CI.
import { HronError, Schedule, type ScheduleExpr, Temporal } from "hron-ts";

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
const valid: boolean = Schedule.validate("every day at 09:00");

try {
  Schedule.parse("every");
} catch (err) {
  if (err instanceof HronError) console.log(err.kind, err.displayRich());
}

console.log(next, fromInstant, expr, valid);
