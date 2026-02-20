# hron-wasm

WASM bindings for [hron](https://github.com/prasrvenkat/hron) — human-readable cron expressions for JavaScript/TypeScript via WebAssembly.

For a native TypeScript implementation (no WASM), see [`hron-ts`](https://github.com/prasrvenkat/hron/tree/main/ts).

## Install

```sh
npm install hron-wasm
```

## Usage

```javascript
import { Schedule, fromCron, explainCron } from "hron-wasm";

// Parse an expression
const schedule = Schedule.parse("every weekday at 9:00 in America/New_York");

// Next occurrence from a given datetime (ISO 8601 string)
const now = new Date().toISOString();
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
const range = schedule.between("2026-01-01T00:00:00Z", "2026-12-31T23:59:59Z");

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

## License

MIT
