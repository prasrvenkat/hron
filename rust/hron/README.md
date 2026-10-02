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

## API

### Building a schedule

- `Schedule::parse(input: &str) -> Result<Schedule, ScheduleError>` - Parse an hron expression; `"...".parse::<Schedule>()` does the same
- `Schedule::from_cron(cron_expr: &str) -> Result<Schedule, ScheduleError>` - Convert a 5-field cron expression to the schedule that fires at the same times
- `Schedule::validate(input: &str) -> bool` - False for anything `parse` rejects, including unknown timezones
- `Schedule::explain_cron(cron_expr: &str) -> Result<String, ScheduleError>` - The same as `Schedule::from_cron(cron_expr)?.to_string()`
- `Schedule::from_parts(parts: ScheduleParts) -> Result<Schedule, ScheduleError>` and `to_parts(&self) -> ScheduleParts` - Build a schedule in code (see [Building in code](#building-in-code))

### Schedule methods

Evaluating a schedule never fails, so these return no `Result`:

- `next_from(&self, now: &Zoned) -> Option<Zoned>` - The next occurrence after `now`, or `None` if there is none
- `next_n_from(&self, now: &Zoned, n: usize) -> Vec<Zoned>` - Up to `n` occurrences after `now`
- `previous_from(&self, now: &Zoned) -> Option<Zoned>` - The most recent occurrence before `now`, or `None` if there is none
- `matches(&self, datetime: &Zoned) -> bool` - Whether the minute containing `datetime` (seconds dropped, on the schedule's wall clock) is an occurrence
- `occurrences(&self, from: &Zoned) -> Occurrences` - A lazy iterator of `Zoned` after `from`; for a repeating schedule it ends only at an `until` clause or the end of the supported range
- `between(&self, from: &Zoned, to: &Zoned) -> BoundedOccurrences` - A lazy iterator of `Zoned` where `from < occurrence <= to`
- `to_cron(&self) -> Result<String, ScheduleError>` - The 5-field cron expression that fires at the same times; run it in the schedule's timezone
- `Display` (`to_string()`) - The canonical expression, which parses back to an equal schedule

Every returned `Zoned` is in the schedule's timezone, or UTC when it has none.

```rust
use hron::Schedule;
use jiff::Zoned;

let schedule = Schedule::parse("every day at 09:00").unwrap();
let from: Zoned = "2026-02-06T21:00:00+09:00[Asia/Tokyo]".parse().unwrap();
assert_eq!(schedule.previous_from(&from).unwrap().to_string(), "2026-02-06T09:00:00+00:00[UTC]");
let to: Zoned = "2026-02-08T12:00:00+00:00[UTC]".parse().unwrap();
let found: Vec<String> = schedule.between(&from, &to).map(|t| t.to_string()).collect();
assert_eq!(found, ["2026-02-07T09:00:00+00:00[UTC]", "2026-02-08T09:00:00+00:00[UTC]"]);
```

### Getters

The getters borrow from the schedule or copy out of it, so nothing they return can change it. The types are in `hron::ast`.

- `timezone(&self) -> Option<&str>` - The IANA timezone name with its canonical capitalization
- `expression(&self) -> &ScheduleExpr` - The repeat: its kind, interval, days or target, and its times or window
- `except(&self) -> &[Exception]` - The except dates, empty without an `except` clause
- `until(&self) -> Option<&UntilSpec>` - The until date
- `starting(&self) -> Option<jiff::civil::Date>` - The starting date
- `during(&self) -> &[MonthName]` - The during months, empty without a `during` clause

```rust
use hron::ast::{Exception, MonthName, TimeOfDay};
use hron::{Schedule, ScheduleExpr};

let schedule = Schedule::parse(
    "every weekday at 09:00 except dec 25 starting 2026-01-05 during jan, feb in america/new_york",
)
.unwrap();
assert!(matches!(
    schedule.expression(),
    ScheduleExpr::DayRepeat { times, .. } if times == &[TimeOfDay { hour: 9, minute: 0 }]
));
assert_eq!(schedule.timezone(), Some("America/New_York"));
assert_eq!(schedule.except(), [Exception::Named { month: MonthName::December, day: 25 }]);
assert_eq!(schedule.until(), None);
assert_eq!(schedule.starting(), Some(jiff::civil::date(2026, 1, 5)));
assert_eq!(schedule.during(), [MonthName::January, MonthName::February]);
```

### Equality

`Schedule` is `PartialEq`, `Eq` and `Hash` by its parts, lists in order with duplicates included, so `every day at 9:00` equals `every day at 09:00`, and a schedule equals the one `parse` reads from its `to_string()` ([spec](https://github.com/simpllyf/hron/blob/main/spec/README.md#equality)):

```rust
use hron::Schedule;
use std::collections::HashSet;

let nine = Schedule::parse("every day at 9:00").unwrap();
assert_eq!(nine, Schedule::parse("every day at 09:00").unwrap());
assert_ne!(nine, Schedule::parse("every day at 09:00 in UTC").unwrap());

let unique: HashSet<Schedule> = ["every day at 9:00", "every day at 09:00"]
    .into_iter()
    .map(|input| Schedule::parse(input).unwrap())
    .collect();
assert_eq!(unique.len(), 1);
```

### Usage errors

There are none: Rust's types rule out a missing argument or one of the wrong type, and a count is a `usize`.

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

Every error is a `ScheduleError`, which implements `std::error::Error` and has:

| Accessor | Returns |
|---|---|
| `kind()` | an `ErrorKind`: `Lex` or `Parse` from `Schedule::parse`, `Eval` from `Schedule::from_parts`, `Cron` from `from_cron`, `explain_cron` and `to_cron` |
| `message()` | the exact message of the spec, which `to_string()` also gives |
| `span()` | for `Lex` and `Parse`, a `Span` of the input, `[start, end)` counted in code points (`char`s), not bytes; otherwise `None` |
| `input()` | for `Lex` and `Parse`, the expression as given; otherwise `None` |
| `suggestion()` | text to put in place of the span, which only a `Parse` error may have |
| `display_rich()` | the message, then for `Lex` and `Parse` the input with carets under the span and any suggestion |

`ScheduleError::lex`, `parse`, `eval` and `cron` build one of each kind. `ErrorKind` and `Span` are exported beside `ScheduleError`.

```rust
use hron::{ErrorKind, Schedule, Span};

let error = Schedule::parse("every weekday at 09:00 until dec 31").unwrap_err();
assert_eq!(error.kind(), ErrorKind::Parse);
assert_eq!(error.message(), "until dec 31 has no year: add a starting date, or use an ISO date");
assert_eq!(error.span(), Some(Span::new(23, 35)));
assert_eq!(error.input(), Some("every weekday at 09:00 until dec 31"));
assert_eq!(error.suggestion(), Some("until dec 31 starting YYYY-MM-DD"));
assert_eq!(
    error.display_rich(),
    "error: until dec 31 has no year: add a starting date, or use an ISO date
  every weekday at 09:00 until dec 31
                         ^^^^^^^^^^^^ try: \"until dec 31 starting YYYY-MM-DD\""
);

let error = Schedule::from_cron("0 9 15 * 1").unwrap_err();
assert_eq!((error.kind(), error.span()), (ErrorKind::Cron, None));
assert_eq!(error.display_rich(), format!("error: {}", error.message()));
```

## Tests

```sh
cargo test
```

Conformance tests driven by `spec/tests.json` and `spec/build.json`.

## License

MIT
