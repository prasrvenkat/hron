# hron (Rust)

Rust reference implementation — library, CLI, and WASM bindings.

## Workspace

| Crate | Purpose |
|-------|---------|
| `hron/` | Library — parser, evaluator, cron conversion |
| `hron-cli/` | CLI binary (depends on `hron`) |
| `wasm/` | WASM bindings (depends on `hron`) |

## Library Architecture

Pipeline: `lexer.rs` → `parser.rs` → `eval/`

| Module | Purpose |
|--------|---------|
| `ast.rs` | `Schedule` wrapping `ScheduleExpr` (6 variants) + shared modifiers |
| `lexer.rs` | Tokenizer |
| `parser.rs` | Hand-rolled recursive descent, follows `spec/grammar.ebnf` |
| `parts.rs` | The checks `Schedule::from_parts` runs (spec/README.md, "Schedules built in code") |
| `eval/` | Search for the nearest occurrence, with `calendar.rs` (date arithmetic) and `wall_clock.rs` (time zones); the reference for every implementation's evaluator |
| `cron.rs` | Exact cron conversion in both directions (spec/README.md, "Cron Conversion") |
| `display.rs` | Canonical `Display` impl that roundtrips with parse |
| `error.rs` | Error types with source spans |

## Features

```sh
# Default — lib + serde
cargo add hron

# Library only — just jiff as dependency
cargo add hron --no-default-features
```

- `serde` (default): enables Serialize/Deserialize on all AST types

## Gotchas

- Searches span the 400-year Gregorian cycle (multiplied by the interval where they do not divide evenly), so sparse schedules such as `every 11 years on the fifth sunday of february` are found and contradictory ones return `None`.
- `last` in yearly context is ambiguous: `last weekday of <month>` vs `last <day_name> of <month>`. Parser peeks at next token.

## Tests

```sh
cargo test --workspace --all-features
```

`hron/tests/conformance.rs` drives all cases from `spec/tests.json` and `spec/build.json`. `hron/tests/cron.rs` checks cron conversion against an independent cron matcher. Unit tests live in each module. CLI tests in `hron-cli/tests/cli.rs`.
