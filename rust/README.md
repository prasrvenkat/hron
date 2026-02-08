# hron (Rust)

Rust reference implementation — library, CLI, and WASM bindings.

## Workspace

| Crate | Purpose |
|-------|---------|
| `hron/` | Library — parser, evaluator, cron conversion |
| `hron-cli/` | CLI binary (depends on `hron`) |
| `wasm/` | WASM bindings (depends on `hron`) |

## Library Architecture

Pipeline: `lexer.rs` → `parser.rs` → `eval.rs`

| Module | Purpose |
|--------|---------|
| `ast.rs` | `Schedule` wrapping `ScheduleExpr` (7 variants) + shared modifiers |
| `lexer.rs` | Tokenizer |
| `parser.rs` | Hand-rolled recursive descent, follows `spec/grammar.ebnf` |
| `eval.rs` | `next_from`, `next_n_from`, `matches` via jiff |
| `cron.rs` | Bidirectional cron conversion (expressible subset only) |
| `display.rs` | Canonical `Display` impl that roundtrips with parse |
| `error.rs` | Error types with source spans |

## Features

```toml
# Default — lib + serde
hron = "0.1"

# Library only — just jiff as dependency
hron = { version = "0.1", default-features = false }
```

- `serde` (default): enables Serialize/Deserialize on all AST types

## Gotchas

- Leap year resolution (e.g. "on feb 29") searches up to 8 years forward.
- `last` in yearly context is ambiguous: `last weekday of <month>` vs `last <day_name> of <month>`. Parser peeks at next token.
- `from_cron` handles hour ranges like `9-17`, not just `*` or single numbers.

## Tests

```sh
cargo test --workspace --all-features
```

`hron/tests/conformance.rs` drives all cases from `spec/tests.json`. Unit tests live in each module. CLI tests in `hron-cli/tests/cli.rs`.
