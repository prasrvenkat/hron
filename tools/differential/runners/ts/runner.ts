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

const zoned = (s: string) => Temporal.ZonedDateTime.from(s);
const format = (t: Temporal.ZonedDateTime | null) => t?.toString() ?? null;

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
  process.stdout.write(`${JSON.stringify({ id: c.id, ...run(c) })}\n`);
}
