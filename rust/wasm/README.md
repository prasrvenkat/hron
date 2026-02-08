# hron-wasm

WASM bindings for [hron](https://github.com/prasrvenkat/hron) — human-readable cron expressions for JavaScript/TypeScript via WebAssembly.

For a native TypeScript implementation (no WASM), see [`hron-ts`](https://github.com/prasrvenkat/hron/tree/main/ts).

## Install

```sh
npm install hron-wasm
```

## Usage

```javascript
import { Schedule, fromCron } from "hron-wasm";

// Parse an expression
const schedule = Schedule.parse("every weekday at 9:00 in America/New_York");

// Next occurrence (ISO string, UTC)
const next = schedule.next();

// Next N occurrences
const nextFive = schedule.nextN(5);

// Convert to cron
const cron = schedule.toCron();

// Convert from cron
const fromCronSchedule = fromCron("0 9 * * *");

// Structured JSON
const json = schedule.toJSON();

// Canonical string
const str = schedule.toString();

// Validate
const valid = Schedule.validate("every day at 9:00");
```

## License

MIT
