# hron-wasm

WASM bindings for [hron](https://github.com/simpllyf/hron) — human-readable cron expressions for JavaScript/TypeScript via WebAssembly.

For a native TypeScript implementation (no WASM), see [`hron-ts`](https://github.com/simpllyf/hron/tree/main/ts).

## Install

```sh
npm install hron-wasm
```

## Usage

```javascript
import { Schedule, fromCron, explainCron } from "hron-wasm";

// Parse an expression
const schedule = Schedule.parse("every weekday at 9:00 in America/New_York");

// Next occurrence from a given datetime (RFC 9557 string with a [zone])
const now = `${new Date().toISOString()}[UTC]`;
const next = schedule.nextFrom(now);

// Next N occurrences
const nextFive = schedule.nextNFrom(now, 5);

// Previous occurrence before a given datetime
const prev = schedule.previousFrom(now);

// Check if a datetime matches
const isMatch = schedule.matches(now);

// Lazy iteration: occurrences after `from`, limited to `limit` results
const occ = schedule.occurrences(now, 10);

// Bounded range: occurrences where from < t <= to
const range = schedule.between("2026-01-01T00:00:00Z[UTC]", "2026-12-31T23:59:59Z[UTC]");

// Convert to cron (if expressible)
const cron = schedule.toCron();

// Convert from cron
const fromCronSchedule = fromCron("0 9 * * *");

// Explain a cron expression in human-readable form
const explanation = explainCron("0 9 * * 1-5");

// Structured JSON representation
const json = schedule.toJSON();

// Canonical string (roundtrip-safe)
const str = schedule.toString();

// Validate without parsing
const valid = Schedule.validate("every day at 9:00");

// Timezone getter
const tz = schedule.timezone; // "America/New_York" or undefined
```

## Errors

Methods throw an `Error` whose `message` is the hron error message and whose `kind` says what failed:

| `kind` | Thrown by |
|---|---|
| `lex`, `parse` | `Schedule.parse` on an invalid expression |
| `eval` | reserved: evaluating a schedule from `Schedule.parse` or `fromCron` never fails |
| `cron` | `fromCron` and `explainCron` on invalid cron or cron hron cannot express exactly; `toCron` when no cron fires at the same times |

```javascript
try {
  fromCron("0 9 15 * 1");
} catch (error) {
  error.kind;    // "cron"
  error.message; // "not expressible in hron: cron fires on either the day of month or the day of week"
}
```

A `lex` or `parse` error also carries:

| Property | Value |
|---|---|
| `span` | `{ start, end }`, the part of the input the error points at: `[start, end)` in code points |
| `input` | the expression as given |
| `suggestion` | text to put in place of the span, or `undefined` |

Every hron error has `displayRich()`, which renders the message, then for `lex` and `parse` errors the input with carets under the span:

```javascript
try {
  Schedule.parse("every weekday at 09:00 until dec 31");
} catch (error) {
  error.kind;       // "parse"
  error.message;    // "until dec 31 has no year: add a starting date, or use an ISO date"
  error.span;       // { start: 23, end: 35 }
  error.suggestion; // "until dec 31 starting YYYY-MM-DD"
  console.log(error.displayRich());
  // error: until dec 31 has no year: add a starting date, or use an ISO date
  //   every weekday at 09:00 until dec 31
  //                          ^^^^^^^^^^^^ try: "until dec 31 starting YYYY-MM-DD"
}
```

Spans count code points, not JavaScript string (UTF-16) indices, so the two differ after a character such as an emoji. To turn a span position into a string index:

```javascript
const index = (n) => [...input].slice(0, n).join("").length;
const text = input.slice(index(error.span.start), index(error.span.end));
```

Strings reach WebAssembly as UTF-8, so a lone surrogate arrives as U+FFFD: it is reported as `unexpected character U+FFFD`, one code point wide, and U+FFFD also stands in its place in `error.input`, in any text the message echoes (such as a timezone) and in `displayRich()`.

A datetime argument that cannot be parsed throws a plain `Error` with no `kind`.

## License

MIT
