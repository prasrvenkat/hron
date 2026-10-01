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

// Compute next occurrence
let now = Zoned::now();
let next = schedule.next_from(&now).unwrap();

// Compute next N occurrences
let next_five = schedule.next_n_from(&now, 5).unwrap();

// Check if a datetime matches
let matches = schedule.matches(&now).unwrap();

// Convert to cron (expressible subset only)
let cron = Schedule::parse("every day at 9:00").unwrap().to_cron().unwrap();

// Convert from cron
let from_cron = Schedule::from_cron("0 9 * * *").unwrap();

// Canonical string (roundtrip-safe)
println!("{schedule}");
```

## Errors

`Schedule::parse` fails with `ScheduleError::Lex` or `ScheduleError::Parse`, each with the exact message of the spec, the `input`, and a `span` that counts code points (`char`s), not bytes. A parse error may carry a `suggestion`. `display_rich()` renders the error with carets under the span:

```text
error: until dec 31 has no year: add a starting date, or use an ISO date
  every weekday at 09:00 until dec 31
                         ^^^^^^^^^^^^ try: "until dec 31 starting YYYY-MM-DD"
```

## Tests

```sh
cargo test
```

Conformance tests driven by `spec/tests.json`.

## License

MIT
