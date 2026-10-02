# hron (Rust)

Native Rust implementation of [hron](https://github.com/simpllyf/hron) — human-readable cron expressions.

## Install

```sh
cargo add hron
```

By default, `serde` support is included. For a minimal build with only `jiff` as a dependency:

```toml
[dependencies]
hron = { version = "*", default-features = false }
```

## Usage

```rust
use hron::Schedule;
use jiff::Zoned;

// Parse an expression
let schedule: Schedule = "every weekday at 9:00 in America/New_York".parse().unwrap();

// Compute next occurrence: evaluating a schedule never fails
let now = Zoned::now();
let next: Option<Zoned> = schedule.next_from(&now);

// Compute next N occurrences
let next_five: Vec<Zoned> = schedule.next_n_from(&now, 5);

// Check if a datetime matches
let matches: bool = schedule.matches(&now);

// Convert to cron (expressible subset only)
let cron = Schedule::parse("every day at 9:00").unwrap().to_cron().unwrap();

// Convert from cron
let from_cron = Schedule::from_cron("0 9 * * *").unwrap();

// Canonical string (roundtrip-safe)
println!("{schedule}");
```

## Building in code

`Schedule::from_parts` builds a schedule from its parts and checks them by the rules `parse` applies ([spec](https://github.com/simpllyf/hron/blob/main/spec/README.md#schedules-built-in-code)), so a built schedule evaluates, displays and converts to cron like a parsed one. `to_parts` gives the parts of any schedule, to change and build again:

```rust
use hron::ast::{DayFilter, TimeOfDay};
use hron::{Schedule, ScheduleExpr, ScheduleParts};

let schedule = Schedule::from_parts(ScheduleParts {
    expression: ScheduleExpr::DayRepeat {
        interval: 1,
        days: DayFilter::Weekday,
        times: vec![TimeOfDay { hour: 9, minute: 0 }],
    },
    timezone: Some("america/new_york".into()),
    except: vec![],
    until: None,
    starting: Some(jiff::civil::date(2026, 1, 5)),
    during: vec![],
})
.unwrap();
assert_eq!(
    schedule.to_string(),
    "every weekday at 09:00 starting 2026-01-05 in America/New_York"
);

let mut parts = schedule.to_parts();
parts.expression = ScheduleExpr::DayRepeat {
    interval: 2,
    days: DayFilter::Weekday,
    times: vec![TimeOfDay { hour: 9, minute: 0 }],
};
let error = Schedule::from_parts(parts).unwrap_err();
assert_eq!(error.to_string(), "days must be every day when the interval is above 1");
```

## Errors

`Schedule::parse` fails with `ScheduleError::Lex` or `ScheduleError::Parse`, each with the exact message of the spec, the `input`, and a `span` that counts code points (`char`s), not bytes. A parse error may carry a `suggestion`. `display_rich()` renders the error with carets under the span:

```text
error: until dec 31 has no year: add a starting date, or use an ISO date
  every weekday at 09:00 until dec 31
                         ^^^^^^^^^^^^ try: "until dec 31 starting YYYY-MM-DD"
```

`Schedule::from_parts` fails with `ScheduleError::Eval`, which has only a message, and `to_cron`, `from_cron` and `explain_cron` with `ScheduleError::Cron`; `display_rich()` renders either as `error: {message}`.

## Tests

```sh
cargo test
```

Conformance tests driven by `spec/tests.json` and `spec/build.json`.

## License

MIT
