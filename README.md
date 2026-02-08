# hron

**Human-readable cron** — scheduling expressions that are a superset of what cron can express.

```
every weekday at 9:00 except dec 25, jan 1 until 2027-12-31 in America/New_York
```

hron is a language specification with native implementations for multiple programming languages. It handles everything cron can do and more: multi-week intervals, ordinal weekdays, yearly schedules, exception dates, end dates, and IANA timezone support with full DST awareness.

## Packages

| Language | Package | Registry | Source |
|----------|---------|----------|--------|
| Rust | `hron` | crates.io | [rust/hron/](rust/hron/) |
| Rust CLI | `hron-cli` | crates.io | [rust/hron-cli/](rust/hron-cli/) |
| JS/TS (WASM) | `hron-wasm` | npm | [rust/wasm/](rust/wasm/) |
| JS/TS (native) | `hron-js` | npm | [ts/](ts/) |

## Expression Syntax

### Daily

```
every day at 09:00
every weekday at 9:00
every weekend at 10:00
every monday at 9:00
every mon, wed, fri at 9:00
```

### Intervals

```
every 30 min from 09:00 to 17:00
every 2 hours from 00:00 to 23:59
every 45 min from 09:00 to 17:00 on weekdays
```

### Weekly

```
every 2 weeks on monday at 9:00
every 3 weeks on mon, wed at 10:00
```

### Monthly

```
every month on the 1st at 9:00
every month on the 1st, 15th at 9:00
every month on the last day at 17:00
every month on the last weekday at 15:00
first monday of every month at 10:00
last friday of every month at 16:00
third thursday of every month at 11:00
```

### Yearly

```
every year on dec 25 at 00:00
every year on jul 4 at 12:00
every year on the first monday of march at 10:00
every year on the third thursday of november at 12:00
every year on the 15th of march at 09:00
every year on the last weekday of december at 17:00
every year on the last friday of december at 17:00
```

### One-off dates

```
on feb 14 at 9:00
on 2026-03-15 at 14:30
on next monday at 9:00
```

### Modifiers

Trailing clauses can be combined in this order: `except`, `until`, `starting`, `during`, `in`.

```
every weekday at 9:00 except dec 25, jan 1
every weekday at 9:00 except 2026-07-04
every day at 09:00 until 2026-12-31
every day at 09:00 until dec 31
every 2 weeks on monday at 9:00 starting 2026-01-05
every weekday at 9:00 in America/New_York
every day at 9:00 during jan, jun
every weekday at 9:00 except dec 25 until 2027-12-31 during jan, dec in UTC
```

- **`except`** — skip specific dates. Named dates (`dec 25`) recur every year. ISO dates (`2026-07-04`) are one-off.
- **`until`** — stop producing occurrences after this date.
- **`starting`** — anchor date for multi-week intervals.
- **`during`** — only fire during specific months.
- **`in`** — IANA timezone. Must be last.

## Cron Compatibility

hron can convert to and from standard 5-field cron expressions for the expressible subset:

| hron | cron |
|---|---|
| `every day at 9:00` | `0 9 * * *` |
| `every weekday at 9:00` | `0 9 * * 1-5` |
| `every weekend at 10:00` | `0 10 * * 0,6` |
| `every mon, wed, fri at 9:00` | `0 9 * * 1,3,5` |
| `every 30 min from 00:00 to 23:59` | `*/30 * * * *` |
| `every 2 hours from 00:00 to 23:59` | `0 */2 * * *` |
| `every month on the 1st at 9:00` | `0 9 1 * *` |

Expressions that go beyond cron's capabilities (multi-week intervals, ordinals, yearly, `except`, `until`, partial-day windows) will return an error from `to_cron()`.

## Conformance Spec

The [spec/](spec/) directory contains the language-agnostic conformance test suite (`tests.json`) and formal grammar (`grammar.ebnf`). All language implementations must pass the conformance tests.

## Development

Requires [just](https://github.com/casey/just).

```sh
just test-all        # Run tests across all languages
just test-rust       # Run Rust tests only
just test-ts         # Run TypeScript tests only
just build-wasm      # Build WASM package
just stamp-versions  # Stamp VERSION into all package manifests
```

## License

MIT
