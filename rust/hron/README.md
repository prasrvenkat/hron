# hron (Rust)

Native Rust implementation of [hron](https://github.com/prasrvenkat/hron) — human-readable cron expressions.

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
let next = schedule.next_from(&now);

// Compute next N occurrences
let next_five = schedule.next_n_from(&now, 5);

// Check if a datetime matches
let matches = schedule.matches(&now);

// Convert to cron (expressible subset only)
let cron = Schedule::parse("every day at 9:00").unwrap().to_cron().unwrap();

// Convert from cron
let from_cron = Schedule::from_cron("0 9 * * *").unwrap();

// Canonical string (roundtrip-safe)
println!("{schedule}");
```

## Tests

```sh
cargo test
```

Conformance tests driven by `spec/tests.json`.

## License

MIT
