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

// Next occurrence after a timestamp string (see "Timestamps" below)
const now = new Date().toISOString();
const next = schedule.nextFrom(now);

// Next N occurrences
const nextFive = schedule.nextNFrom(now, 5);

// Previous occurrence before a given datetime
const prev = schedule.previousFrom(now);

// Check if a datetime matches
const isMatch = schedule.matches(now);

// Occurrences after `from`, limited to `limit` results
const occ = schedule.occurrences(now, 10);

// Bounded range: occurrences where from < t <= to
const range = schedule.between("2026-01-01T00:00:00Z", "2026-12-31T23:59:59Z");

// Convert to cron (if expressible)
const cron = schedule.toCron();

// Convert from cron
const fromCronSchedule = fromCron("0 9 * * *");

// Explain a cron expression in human-readable form
const explanation = explainCron("0 9 * * 1-5");

// Structured JSON representation, as a plain object; JSON.stringify(schedule) uses it
const json = schedule.toJSON();

// Canonical string (roundtrip-safe)
const str = schedule.toString();

// Validate without parsing
const valid = Schedule.validate("every day at 9:00");

// Timezone getter
const tz = schedule.timezone; // "America/New_York", or null without an `in` clause
```

## API

### Building a schedule

- `Schedule.parse(input: string): Schedule` - Parse an hron expression
- `fromCron(cronExpr: string): Schedule` - Convert a 5-field cron expression to the schedule that fires at the same times
- `Schedule.validate(input: string): boolean` - False for anything `parse` rejects, including unknown timezones
- `explainCron(cronExpr: string): string` - The same as `fromCron(cronExpr).toString()`

### Schedule methods

- `nextFrom(now: string): string | null` - The next occurrence after `now`
- `nextNFrom(now: string, n: number): string[]` - Up to `n` occurrences after `now`
- `previousFrom(now: string): string | null` - The most recent occurrence before `now`
- `matches(datetime: string): boolean` - Whether the minute containing `datetime` is an occurrence
- `occurrences(from: string, limit: number): string[]` - Up to `limit` occurrences after `from`; an array, not an iterator, so it needs a limit
- `between(from: string, to: string): string[]` - The occurrences where `from < occurrence <= to`
- `toCron(): string` - The 5-field cron expression that fires at the same times; run it in the schedule's timezone
- `toString(): string` - The canonical expression, which parses back to an equal schedule
- `equals(other: unknown): boolean` - Whether `other` is a schedule with the same parts (below)
- `toJSON(): any` - A structured view for logging, which `JSON.stringify` uses

### Getters

Each getter returns the same plain objects [`hron-ts`](https://github.com/simpllyf/hron/tree/main/ts) returns, typed in `hron-wasm`'s `.d.ts` with the same names (`ScheduleExpr`, `Exception`, `UntilSpec`, `MonthName` and the rest), so code that reads one reads the other. They are frozen at every level, as hron-ts's are: a write to one throws in strict mode, and the schedule never changes.

- `timezone: string | null` - The IANA timezone name with its canonical capitalization
- `expression: ScheduleExpr` - The repeat, tagged by `type`: `intervalRepeat`, `dayRepeat`, `weekRepeat`, `monthRepeat`, `singleDate` or `yearRepeat`
- `except: Exception[]` - The except dates, `[]` without an `except` clause
- `until: UntilSpec | null` - The until date
- `starting: string | null` - The starting date as `YYYY-MM-DD`
- `during: MonthName[]` - The during months, `[]` without a `during` clause

```javascript
const schedule = Schedule.parse(
  "every weekday at 09:00, 17:00 except dec 25 starting 2026-01-05 during jan, feb in america/new_york",
);
schedule.expression.type;         // "dayRepeat"
schedule.expression.days;         // { type: "weekday" }
schedule.expression.times.length; // 2
schedule.expression.times[1];     // { hour: 17, minute: 0 }
schedule.except;                  // [{ type: "named", month: "dec", day: 25 }]
schedule.until;                   // null
schedule.starting;                // "2026-01-05"
schedule.during;                  // ["jan", "feb"]
schedule.timezone;                // "America/New_York"
```

### Equality

`equals` compares the parts, lists in order with duplicates included, so `every day at 9:00` equals `every day at 09:00`, and a schedule equals the one `Schedule.parse` reads from its `toString()` ([spec](https://github.com/simpllyf/hron/blob/main/spec/README.md#equality)). It is `false` for anything that is not a schedule, `null` and `undefined` included, and never throws. There is no hash: equal schedules have the same `toString()`, which can serve as a `Map` key.

```javascript
const nine = Schedule.parse("every day at 9:00");
nine.equals(Schedule.parse("every day at 09:00")); // true
nine.equals(fromCron("0 9 * * *"));                 // true
nine === Schedule.parse("every day at 9:00");       // false
nine.equals("every day at 09:00");                  // false
nine.equals(null);                                  // false
```

## Timestamps

Every method takes and returns timestamps as strings ([spec](https://github.com/simpllyf/hron/blob/main/spec/README.md#timestamps-and-counts)):

- A timestamp you pass needs a UTC offset or `Z`, in either case: `2026-02-06T12:00:00+09:00[Asia/Tokyo]`, `2026-02-06T03:00:00Z` and `2026-02-06t03:00:00.000z` all name the same instant, and only the instant matters. The offset decides it: a zone in brackets that disagrees with the offset is ignored, unless it is marked critical (`[!Asia/Tokyo]`).
- `new Date().toISOString()` gives a valid timestamp. Its six-digit years (`+010000-01-01T00:00:00.000Z`) lie outside the supported range, 0001-01-02 to 9999-12-30, where `nextFrom` and `previousFrom` return `null`, `matches` returns `false`, and the others return `[]`.
- Every returned timestamp has seconds, an offset as `±HH:MM` and the schedule's timezone, or `UTC` when it has none: `2026-02-06T09:00:00-05:00[America/New_York]`, `2026-02-07T09:00:00+00:00[UTC]`.
- `nextNFrom(now, n)` and `occurrences(from, limit)` return at most `n` or `limit` results, and `[]` when it is 0 or less. A large count only caps the results.

```javascript
const daily = Schedule.parse("every day at 09:00");
daily.nextFrom("2026-02-06T12:00:00+09:00[Asia/Tokyo]"); // "2026-02-06T09:00:00+00:00[UTC]"
daily.nextFrom("2026-02-06T08:59:00+00:00[Asia/Tokyo]"); // "2026-02-06T09:00:00+00:00[UTC]"
daily.nextFrom("+010000-01-01T00:00:00.000Z");           // null
daily.nextNFrom("2026-02-06T03:00:00Z", -1);             // []
```

## Usage errors

A bad argument throws the platform's own error, with no `kind`: a `TypeError` for a value of the wrong type, such as anything but a string, `null` and `undefined` included, as the input of `Schedule.parse`, `Schedule.validate`, `fromCron` or `explainCron`, a `Date`, a number or `undefined` where a timestamp string goes, or a string where `n` or `limit` goes; and a `RangeError` for a bad value, such as a timestamp without an offset (`2026-02-06T12:00:00[Asia/Tokyo]`), an unknown timezone, an offset that disagrees with a critical zone, or an `n` or `limit` that is not an integer.

## Errors

Apart from the bad arguments above, methods throw an `Error` whose `message` is the hron error message and whose `kind` says what failed. The `.d.ts` types it as `HronError`, an interface, so `catch (error) { (error as HronError).kind }` type-checks; there is no class to test with `instanceof`, and no error constructors.

| `kind` | Thrown by |
|---|---|
| `lex`, `parse` | `Schedule.parse` on an invalid expression |
| `eval` | never: it is reserved for schedules built in code, and WebAssembly builds one only with `Schedule.parse` or `fromCron`, whose schedules never fail to evaluate |
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

## License

MIT
