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
