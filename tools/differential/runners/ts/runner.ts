import { createInterface } from "node:readline";
import { HronError, Schedule, Temporal } from "../../../../ts/dist/index.js";

type Case = {
  id: string;
  op: string;
  expr: string;
  now: string;
  datetime: string;
  from: string;
  to: string;
  n: number;
};

// ZonedDateTime.from rejects an offset that Temporal's tz data does not give the wall time, so the
// instant is read first.
function zoned(s: string): Temporal.ZonedDateTime {
  const [, iso, zone] = s.match(/^(.+)\[(.+)\]$/)!;
  return Temporal.Instant.from(iso).toZonedDateTimeISO(zone);
}
// toString() rounds the offset to the nearest minute, since RFC 9557 has no seconds there.
const format = (t: Temporal.ZonedDateTime | null) =>
  t ? `${t.toPlainDateTime()}${t.offset}[${t.timeZoneId}]` : null;

function take<T>(items: Iterable<T>, n: number): T[] {
  const out: T[] = [];
  for (const item of items) {
    if (out.length === n) break;
    out.push(item);
  }
  return out;
}

function evaluate(c: Case): unknown {
  if (c.op === "fromCron") return Schedule.fromCron(c.expr).toString();
  const schedule = Schedule.parse(c.expr);
  switch (c.op) {
    case "parse":
      return schedule.toString();
    case "toCron":
      return schedule.toCron();
    case "next":
      return format(schedule.nextFrom(zoned(c.now)));
    case "nextN":
      return schedule.nextNFrom(zoned(c.now), c.n).map(format);
    case "prev":
      return format(schedule.previousFrom(zoned(c.now)));
    case "matches":
      return schedule.matches(zoned(c.datetime));
    case "between":
      return [...schedule.between(zoned(c.from), zoned(c.to))].map(format);
    case "occurrences":
      return take(schedule.occurrences(zoned(c.from)), c.n).map(format);
  }
  throw new Error(`unknown op ${c.op}`);
}

function details(e: HronError): object {
  return {
    kind: e.kind,
    message: e.message,
    span: e.span ? [e.span.start, e.span.end] : null,
    suggestion: e.suggestion ?? null,
  };
}

function run(c: Case): object {
  try {
    return { ok: true, result: evaluate(c) };
  } catch (e) {
    if (e instanceof HronError) return { ok: false, error: details(e) };
    return { ok: false, error: { kind: "crash", message: String(e) } };
  }
}

for await (const line of createInterface({ input: process.stdin })) {
  const c: Case = JSON.parse(line);
  const start = performance.now();
  const outcome = run(c);
  const micros = Math.round((performance.now() - start) * 1000);
  process.stdout.write(`${JSON.stringify({ id: c.id, ...outcome, micros })}\n`);
}
