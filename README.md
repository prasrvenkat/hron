# hron

**Human-readable cron** — scheduling expressions that are a superset of what cron can express.

> **⚠️ Pre-1.0: Expect breaking changes between minor versions.**

```
every weekday at 9:00 except dec 25, jan 1 until 2027-12-31 in America/New_York
```

hron is a language specification with native implementations for multiple programming languages. It handles everything cron can do and more: multi-week intervals, ordinal weekdays, yearly schedules, exception dates, end dates, and IANA timezone support with full DST awareness.

## Try It

**[hron.io](https://hron.io)** — interactive playground, no install needed.

```sh
cargo install hron-cli
```

```sh
$ hron "every weekday at 9:00 in America/New_York"
2026-02-09T09:00:00-05:00[America/New_York]

$ hron "every weekday at 9:00" -n 3
2026-02-09T09:00:00+00:00[UTC]
2026-02-10T09:00:00+00:00[UTC]
2026-02-11T09:00:00+00:00[UTC]

$ hron "every day at 9:00" --to-cron
0 9 * * *

$ hron --from-cron "*/30 * * * *"
every 30 min from 00:00 to 23:59

$ hron --explain "0 9 * * 1-5"
every weekday at 09:00
```

See [`hron-cli`](rust/hron-cli/) for all options.

## Packages

| Language | Package | Registry |
|----------|---------|----------|
| Rust | [`hron`](rust/hron/) | [![crates.io](https://img.shields.io/crates/v/hron)](https://crates.io/crates/hron) |
| JS/TS (native) | [`hron-ts`](ts/) | [![npm](https://img.shields.io/npm/v/hron-ts)](https://www.npmjs.com/package/hron-ts) |
| JS/TS (WASM) | [`hron-wasm`](rust/wasm/) | [![npm](https://img.shields.io/npm/v/hron-wasm)](https://www.npmjs.com/package/hron-wasm) |
| Dart/Flutter | [`hron`](dart/) | [![pub.dev](https://img.shields.io/pub/v/hron)](https://pub.dev/packages/hron) |
| Python | [`hron`](python/) | [![PyPI](https://img.shields.io/pypi/v/hron)](https://pypi.org/project/hron/) |
| Go | [`hron`](go/) | [![Go Reference](https://pkg.go.dev/badge/github.com/prasrvenkat/hron/go.svg)](https://pkg.go.dev/github.com/prasrvenkat/hron/go) |
| Java | [`hron`](java/) | [![Maven Central](https://img.shields.io/maven-central/v/io.hron/hron)](https://central.sonatype.com/artifact/io.hron/hron) |
| C# | [`Hron`](csharp/Hron/) | [![NuGet](https://img.shields.io/nuget/v/Hron)](https://www.nuget.org/packages/Hron) |

> **Note:** The JS/TS native package (`hron-js`) uses the [Temporal API](https://tc39.es/proposal-temporal/) via polyfill. Once Temporal ships natively in runtimes, performance improves automatically. For performance-critical JS/TS use cases, consider the WASM package (`hron-wasm`).

## Library Usage

hron is available as a library in multiple languages:

```sh
# Rust
cargo add hron

# TypeScript / JavaScript
npm install hron-ts    # native
npm install hron-wasm  # WASM

# Dart / Flutter
dart pub add hron

# Python
pip install hron

# Go
go get github.com/prasrvenkat/hron/go

# Java (Maven)
# Add to pom.xml:
# <dependency>
#     <groupId>io.hron</groupId>
#     <artifactId>hron</artifactId>
#     <version>0.4.2</version>
# </dependency>

# C# / .NET
dotnet add package Hron
```

See language-specific READMEs for API docs and examples: [Rust](rust/hron/) · [TypeScript](ts/) · [Dart](dart/) · [Python](python/) · [Go](go/) · [Java](java/) · [C#](csharp/Hron/) · [WASM](rust/wasm/)

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

## Timezone & DST Behavior

When a schedule specifies a timezone via the `in` clause, all occurrences are computed in that timezone with full DST awareness:

- **Spring-forward (gap):** If a scheduled time doesn't exist (e.g. `2:30 AM` during a spring-forward transition), the occurrence shifts to the next valid time after the gap (typically `3:00 AM` or later, depending on the gap size).
- **Fall-back (ambiguity):** If a scheduled time is ambiguous (e.g. `1:30 AM` occurs twice during fall-back), the first (pre-transition) occurrence is used.
- **No timezone:** When no `in` clause is specified, the system's local timezone is used.

All implementations (Rust, TypeScript, Dart, Python, Go, Java, C#, WASM) follow these same DST semantics.

The [conformance test suite](spec/tests.json) includes explicit spring-forward and fall-back test cases to verify this behavior across all implementations.

## Conformance Spec

The [spec/](spec/) directory contains the language-agnostic conformance test suite (`tests.json`) and formal grammar (`grammar.ebnf`). The grammar is a reference specification — all parsers are hand-written [recursive descent](https://en.wikipedia.org/wiki/Recursive_descent_parser), not generated from the EBNF. All language implementations must pass the conformance tests.

## Development

Requires [just](https://github.com/casey/just).

```sh
just test-all        # Run tests across all languages
just test-rust       # Run Rust tests only
just test-ts         # Run TypeScript tests only
just test-dart       # Run Dart tests only
just test-python     # Run Python tests only
just test-go         # Run Go tests only
just test-java       # Run Java tests only
just test-csharp     # Run C# tests only
just build-wasm      # Build WASM package
just bench           # Run Criterion benchmarks (Rust)
just fuzz            # Run fuzz targets (requires nightly, default 3 min)
just stamp-versions  # Stamp VERSION into all package manifests
```

## License

MIT
