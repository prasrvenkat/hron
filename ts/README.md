# hron-ts (TypeScript)

Native TypeScript implementation of [hron](https://github.com/simpllyf/hron) — human-readable cron expressions.

## Install

```sh
npm install hron-ts
```

## Usage

```typescript
import { HronError, Schedule, Temporal } from "hron-ts";

// Parse an expression
const schedule = Schedule.parse("every weekday at 9:00 in America/New_York");

// Compute next occurrence
const now = Temporal.Now.zonedDateTimeISO();
const next = schedule.nextFrom(now);

// Compute next N occurrences
const nextFive = schedule.nextNFrom(now, 5);

// Check if a datetime matches
const matches = schedule.matches(now);

// Convert to cron
const cron = Schedule.parse("every day at 9:00").toCron(); // "0 9 * * *"

// Convert from cron
const fromCron = Schedule.fromCron("0 9 * * 1-5"); // every weekday at 09:00

// Canonical string (roundtrip-safe)
console.log(schedule.toString());
```

A `Schedule` comes only from `Schedule.parse` or `Schedule.fromCron`, and it cannot change afterwards.

## API

### `Schedule.parse(input: string): Schedule`
Parse an hron expression string. Throws a `HronError` whose `kind` is `"lex"` or `"parse"` on an invalid expression (see [Errors](#errors)), and a `TypeError` for anything that is not a string, `null` and `undefined` included.

### `Schedule.fromCron(cronExpr: string): Schedule`
Convert a 5-field cron expression or `@` shortcut to a Schedule that fires at the same times (see [Cron Conversion](#cron-conversion)). Throws a `HronError` whose `kind` is `"cron"` when the input is not valid cron or has no exact hron equivalent, and a `TypeError` for anything that is not a string.

### `Schedule.validate(input: string): boolean`
`false` for anything `parse` rejects, unknown timezones included. Throws a `TypeError` for anything that is not a string, `null` and `undefined` included, rather than returning `false`.

### `schedule.nextFrom(now): Temporal.ZonedDateTime | null`
The next occurrence strictly after `now`, or `null` if there is none.

### `schedule.nextNFrom(now, n: number): Temporal.ZonedDateTime[]`
Up to `n` occurrences strictly after `now`: fewer if the schedule ends, none if `n <= 0`.

### `schedule.previousFrom(now): Temporal.ZonedDateTime | null`
The most recent occurrence strictly before `now`, or `null` if there is none, such as before a `starting` date.

### `schedule.matches(datetime): boolean`
True when the minute containing `datetime`, on the schedule's wall clock, is an occurrence.

### `schedule.occurrences(from): Generator<Temporal.ZonedDateTime>`
Lazily yields the occurrences strictly after `from`, unbounded unless an `until` ends the schedule.

### `schedule.between(from, to): Generator<Temporal.ZonedDateTime>`
Lazily yields the occurrences where `from < occurrence <= to`.

### `schedule.toCron(): string`
A 5-field cron expression that fires at the same times. Throws a `HronError` whose `kind` is `"cron"` when there is none (see [Cron Conversion](#cron-conversion)).

### `schedule.toString(): string`
The canonical expression, which parses back to an equal schedule.

### Getters

Read-only properties, one per part. What they return is frozen and typed `readonly`, so a write is a type error and, at runtime, a `TypeError` in strict mode.

| Property | Type | |
|---|---|---|
| `schedule.expression` | `ScheduleExpr` | The repeat, by its `type`: `intervalRepeat`, `dayRepeat`, `weekRepeat`, `monthRepeat`, `singleDate` or `yearRepeat`. |
| `schedule.timezone` | `string \| null` | The IANA timezone name with its canonical capitalization; `null` without an `in` clause. |
| `schedule.except` | `readonly Exception[]` | The except dates; empty without an except clause. |
| `schedule.until` | `UntilSpec \| null` | The until date; `null` without an until clause. |
| `schedule.starting` | `string \| null` | The starting date as `YYYY-MM-DD`; `null` without a starting clause. |
| `schedule.during` | `readonly MonthName[]` | The during months; empty without a during clause. |

```typescript
const schedule = Schedule.parse(
  "every weekday at 9:00 except dec 25 starting 2026-01-05 during jan, dec in america/new_york",
);
schedule.expression; // { type: "dayRepeat", interval: 1, days: { type: "weekday" }, times: [{ hour: 9, minute: 0 }] }
schedule.except; // [{ type: "named", month: "dec", day: 25 }]
schedule.until; // null
schedule.starting; // "2026-01-05"
schedule.during; // ["jan", "dec"]
schedule.timezone; // "America/New_York"
```

The types of the parts are exported: `ScheduleExpr`, `DayFilter`, `DayOfMonthSpec`, `MonthTarget`, `NearestDirection`, `YearTarget`, `DateSpec`, `Exception`, `UntilSpec`, `TimeOfDay`, `IntervalUnit`, `OrdinalPosition`, `Weekday` and `MonthName`.

### `schedule.equals(other: unknown): boolean`
True when `other` is a schedule with equal parts, however it was built: `every day at 9:00` equals `every day at 09:00`, and a schedule from `fromCron` equals the parse of its `toString`. Lists compare in order, duplicates included, as `toString` writes them. False for anything but a schedule, `null` and `undefined` included; it never throws. JavaScript has no operator overloading, so `===` compares identity, and there is no hash.

```typescript
Schedule.parse("every day at 9:00").equals(Schedule.parse("every day at 09:00")); // true
Schedule.fromCron("0 9 * * 1-5").equals(Schedule.parse("every weekday at 09:00")); // true
Schedule.parse("every day at 09:00, 17:00").equals(Schedule.parse("every day at 17:00, 09:00")); // false
Schedule.parse("every day at 09:00").equals(null); // false
```

## Timestamps

Every method takes a `Temporal.ZonedDateTime` or a `Temporal.Instant`, either the polyfill's (exported as `Temporal`) or the engine's native one, and returns `Temporal.ZonedDateTime`. Only the instant counts, not the zone it is written in, and every result is in the schedule's timezone, or UTC when it has none:

```typescript
const tokyo = Temporal.ZonedDateTime.from("2026-02-06T21:00:00+09:00[Asia/Tokyo]");
Schedule.parse("every day at 09:00 in America/New_York").nextFrom(tokyo)?.toString();
// "2026-02-06T09:00:00-05:00[America/New_York]"
Schedule.parse("every day at 09:00").nextFrom(tokyo)?.toString();
// "2026-02-07T09:00:00+00:00[UTC]"
Schedule.parse("every day at 09:00").nextFrom(tokyo.toInstant())?.toString();
// "2026-02-07T09:00:00+00:00[UTC]"
```

`nextNFrom(now, n)` returns up to `n` occurrences and `[]` when `n <= 0`. A huge `n` costs nothing up front: it returns every occurrence through the end of the supported range.

Any other timestamp (a `Date`, a string, a `PlainDateTime`, `null`, `undefined`) throws a `TypeError` when the method is called, even `occurrences` and `between`, which are lazy. An `n` that is not a number throws a `TypeError`, and one that is not an integer (`1.5`, `NaN`, `Infinity`) a `RangeError`. These are usage errors, never a `HronError`.

## Errors

`Schedule.parse` throws a `HronError` whose `kind` is `"lex"` or `"parse"`, with the exact message of the spec, the `input`, and a `span` of `{ start, end }`. A parse error may carry a `suggestion`. `displayRich()` renders the error with carets under the span:

```text
error: until dec 31 has no year: add a starting date, or use an ISO date
  every weekday at 09:00 until dec 31
                         ^^^^^^^^^^^^ try: "until dec 31 starting YYYY-MM-DD"
```

A span counts code points, not UTF-16 units as string indexes do, so an emoji before it counts once. Index the code points to get the text it covers:

```typescript
if (error.input !== undefined && error.span !== undefined) {
  const spanned = Array.from(error.input).slice(error.span.start, error.span.end).join("");
}
```

Every message is in the spec, under [Error Message Format](https://github.com/simpllyf/hron/blob/main/spec/README.md#error-message-format).

### `HronError`

`HronError` extends `Error`.

| Member | |
|---|---|
| `kind` | `"lex"`, `"parse"`, `"eval"` or `"cron"` (`HronErrorKind`). This package never throws `"eval"`, which is for schedules built in code. |
| `message` | The message alone. |
| `span` | A `Span`, `{ start, end }`, for lex and parse errors, else `undefined`. |
| `input` | The expression as given for lex and parse errors, else `undefined`. |
| `suggestion` | Text to put in place of the span, when a parse error has one, else `undefined`. |
| `displayRich()` | The message, then for lex and parse errors the input with carets under the span and any suggestion. |
| `HronError.lex(message, span, input)`, `HronError.parse(message, span, input, suggestion?)`, `HronError.eval(message)`, `HronError.cron(message)` | Build an error of each kind. Each throws a `TypeError` for a `message` or `input` that is not a string, a `span` that is not an object whose `start` and `end` are numbers, and a `suggestion` that is neither a string nor `undefined`. |

### Usage errors

A bad argument throws JavaScript's own error, never a `HronError`: a `TypeError` for an input to `parse`, `validate` or `fromCron` that is not a string, for a timestamp that is not a `Temporal.ZonedDateTime` or `Temporal.Instant`, and for an `n` that is not a number; a `RangeError` for an `n` that is not an integer. `null` and `undefined` are values of the wrong type.

```typescript
Schedule.validate(null as unknown as string); // throws TypeError: input must be a string
```

## Cron Conversion

`fromCron` and `toCron` convert exactly: the result fires at the same times on the same dates, or the call throws a `HronError` whose `kind` is `"cron"` and whose message says why. This ignores the timezone and DST transitions, where cron schedulers differ. Yearly dates, ordinal weekdays (`1#2`, `5L`) and partial-day intervals convert:

```typescript
Schedule.fromCron("0 9 * 3 1#2").toString(); // "every year on the second monday of mar at 09:00"
Schedule.parse("every 15 min from 09:00 to 17:45 on weekday").toCron(); // "*/15 9-17 * * 1-5"
```

`toCron` throws for `except`, `until` and `starting`, ISO dates, repeats every `n` days, weeks, months or years with `n > 1`, directional nearest weekdays, a `during` that excludes a yearly or named date's month, and times that are not every combination of their minutes and hours (`at 09:00, 17:30`).

Some crons have no hron equivalent:

```typescript
try {
  Schedule.fromCron("0 9 15 * 1");
} catch (error) {
  if (error instanceof HronError) {
    error.kind; // "cron"
    error.message; // "not expressible in hron: cron fires on either the day of month or the day of week"
  }
}
```

`*/7 * * * *` fails too, with `not expressible in hron: 216 times a day are too many to list`: its gaps are uneven across the hour boundary. A schedule's timezone is not part of the cron, so run the cron in the schedule's timezone. The rules and every error message are in the spec, under [Cron Conversion](https://github.com/simpllyf/hron/blob/main/spec/README.md#cron-conversion).

## Temporal Polyfill

This package uses the [Temporal API](https://tc39.es/proposal-temporal/) via `@js-temporal/polyfill`. The accepted timezone names follow the JS engine's Intl/ICU data, so a name IANA has removed may still be accepted. For performance-critical use cases, consider the WASM package (`hron-wasm`).

## Tests

```sh
pnpm test
```

Uses vitest. Conformance tests driven by `spec/tests.json`.

## License

MIT
