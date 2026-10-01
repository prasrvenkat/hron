# hron-ts (TypeScript)

Native TypeScript implementation of [hron](https://github.com/simpllyf/hron) — human-readable cron expressions.

## Install

```sh
npm install hron-ts
```

## Usage

```typescript
import { Schedule, Temporal } from "hron-ts";

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
  error.kind; // "cron"
  error.message; // "not expressible in hron: cron fires on either the day of month or the day of week"
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
