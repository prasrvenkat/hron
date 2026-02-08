# hron-js (TypeScript)

Native TypeScript implementation of [hron](https://github.com/prasrvenkat/hron) — human-readable cron expressions.

## Install

```sh
npm install hron-js
```

## Usage

```typescript
import { Schedule, Temporal } from "hron-js";

// Parse an expression
const schedule = Schedule.parse("every weekday at 9:00 in America/New_York");

// Compute next occurrence
const now = Temporal.Now.zonedDateTimeISO();
const next = schedule.nextFrom(now);

// Compute next N occurrences
const nextFive = schedule.nextNFrom(now, 5);

// Check if a datetime matches
const matches = schedule.matches(now);

// Convert to cron (expressible subset only)
const cron = Schedule.parse("every day at 9:00").toCron();

// Convert from cron
const fromCron = Schedule.fromCron("0 9 * * *");

// Canonical string (roundtrip-safe)
console.log(schedule.toString());
```

## Temporal Polyfill

This package uses the [Temporal API](https://tc39.es/proposal-temporal/) via `@js-temporal/polyfill`. Once Temporal ships natively in runtimes, performance improves automatically. For performance-critical use cases, consider the WASM package (`hron-wasm`).

## Tests

```sh
pnpm test
```

Uses vitest. Conformance tests driven by `spec/tests.json`.

## License

MIT
