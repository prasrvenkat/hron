# Contributing to hron

Thanks for your interest in contributing to hron! This document covers everything you need to get started.

## Development Setup

### Prerequisites

- [just](https://github.com/casey/just) (command runner)
- [mise](https://mise.jdx.dev/) (tool version manager) — or install manually:
  - Rust 1.93+
  - Go 1.25+
  - Java 25+ (Temurin LTS)
  - Node.js 24+ (LTS) with pnpm
  - Dart 3.11+
  - Python 3.11+ with [uv](https://docs.astral.sh/uv/)
  - Ruby 4.0+
  - .NET 10.0+

### Running Tests

All commands should run through [mise](https://mise.jdx.dev/) to ensure the correct tool versions (as defined in `.tool-versions`). Either activate mise in your shell or prefix commands with `mise exec --`:

```sh
# Run all tests across all languages
mise exec -- just test-all

# Or per-language
mise exec -- just test-rust
mise exec -- just test-ts
mise exec -- just test-dart
mise exec -- just test-python
mise exec -- just test-go
mise exec -- just test-java
mise exec -- just test-csharp
mise exec -- just test-ruby
```

If you have mise activated in your shell (via `mise activate bash/zsh`), you can omit the `mise exec --` prefix.

## Project Structure

```
hron/
├── spec/           # Language-agnostic spec (grammar + conformance tests)
├── rust/           # Rust: library, CLI, WASM bindings
│   ├── hron/       # Library crate
│   ├── hron-cli/   # CLI crate
│   └── wasm/       # WASM bindings
├── ts/             # TypeScript: native implementation
├── dart/           # Dart: native implementation
├── python/         # Python: native implementation
├── go/             # Go: native implementation
├── java/           # Java: native implementation
├── csharp/         # C#: native implementation
├── ruby/           # Ruby: native implementation
├── justfile        # Build/test commands
└── VERSION         # Single source of truth for version
```

## Making Changes

### Spec Changes

If you're adding or modifying hron syntax:

1. Update the grammar in `spec/grammar.ebnf`
2. Add conformance test cases to `spec/tests.json`
3. Implement the change in **all** language implementations
4. All conformance tests must pass in all languages before merging

### Implementation Changes

If you're fixing a bug or optimizing a single implementation:

1. For a refactor, record the current behaviour first: `just diff --save tools/differential/.build/before.json`
2. Make the change
3. Ensure conformance tests still pass: `just test-all`
4. For a refactor, show nothing changed: `just diff --compare tools/differential/.build/before.json` (see [tools/differential](tools/differential/README.md))
5. If the fix is relevant to other implementations, apply it there too

### Adding Conformance Tests

Test cases in `spec/tests.json` are the source of truth. When adding tests:

- Follow the existing structure (sections → cases)
- Include `name`, `expression`, `description`, and the relevant assertion (`next_date`, `next_n`, `matches`, `cron`, etc.)
- Run `just test-all` to verify all implementations pass

## Code Style

- **Rust**: `cargo fmt` + `cargo clippy -D warnings`
- **TypeScript**: `tsc --noEmit` (strict mode)
- **Dart**: `dart analyze` with `package:lints/recommended.yaml`
- **Python**: `ruff check` + `ruff format` + `ty check`
- **Go**: `gofmt -w .` + `go vet ./...`
- **Java**: Google Java Format
- **C#**: `dotnet format`
- **Ruby**: `standard`

CI enforces all of these. Run them locally before pushing.

Comments follow the rule in [AGENTS.md](AGENTS.md#comments).

## Evaluator Structure

Every evaluator has the same design, written in its language's idiom. Rust ([rust/hron/src/eval/](rust/hron/src/eval/)) is the reference. One search finds the occurrence nearest an instant, in either direction:

1. Clamp the instant's local date by `starting` (forward) or `until` (backward), and start one period against the search direction: a nearest weekday or a DST shift can move an occurrence out of the period it is scheduled in.
2. Walk the cadence's aligned periods in the search direction: `per_400_years / gcd(per_400_years, interval)` of them plus `HORIZON_MARGIN_PERIODS`, extended to the farthest ISO `except` date (spec/README.md, "Search horizon"). The walk ends early at the calendar's edge: the first period past years 1 to 9999, with one period of slack on each side (a nearest weekday in December of year 0 lands on 0001-01-01), or sooner where the platform's dates end.
3. Take each period's candidate dates in direction order. Stop once a candidate's date is more than `MAX_SHIFT_DAYS` beyond the best occurrence's scheduled date (`could_beat`), or past the clause bound the search moves toward (`ends_search`). Skip a candidate the clauses reject. Otherwise find its occurrence nearest the instant (`nearest_on_date`), and replace the best only when it is strictly nearer.

Each concept has one name, in the language's casing:

| Concept | Name |
|---|---|
| Search direction | `Direction` (`Forward`, `Backward`) with `sign` and `precedes` |
| A schedule prepared for searching | `Search`, with `nearest(now, direction)` and `nearest_on_date` |
| The periods an expression fires in | `Cadence`: `period_of`, `start_of`, `period_starts` |
| A date it fires on, with the month whose day it names | `Candidate` (`date`, `target_month`), from `candidates_in_period` |
| The times of day it fires at | `DailyTimes`: fixed times or interval slots |
| Trailing clauses | `Clauses`: `allows`, `clamp`, `ends_search`, `farthest_except_date` |
| A found occurrence | `Occurrence` (`instant`, and the `date` it is scheduled on), kept while `could_beat` holds |
| Wall time on a date | `fixed_time_on` (shifted out of a gap), `slot_on` (none in a gap); both take a repeated time's first pass |
| Supported range | `RANGE_START`, `RANGE_END`, `in_supported_range` |

And it follows these rules:

- Direction enters only through `Direction` and the clause and cadence primitives. Only the interval-slot scan on a date may be mirrored, because a fall-back overlap is not symmetric; a scan that keeps a date's slots in instant order (each slot's first-pass instant, or its gap's end) and searches them needs no mirror.
- A search prepares its schedule once: zone, cadence, times and clauses, with ISO dates parsed once.
- Numbers that bound a loop are named constants with their reason: `HORIZON_MARGIN_PERIODS`, `MAX_SHIFT_DAYS`, `NAMED_UNTIL_MAX_YEARS`. There are no fixed scan spans.
- Calendar arithmetic and wall-clock resolution live in their own units, apart from the search.
- `matches` is defined through the forward search, so the two cannot disagree.

Implementations may also take these shortcuts, each proven not to change a result:

- Number periods by their calendar index instead of their first date, where a date type cannot hold December of year 0 or building dates is costly.
- Skip a candidate more than `MAX_SHIFT_DAYS` behind the instant's local date, and a month `during` rejects before computing its dates.
- Bound `could_beat` by the times' own shift: `MAX_SHIFT_DAYS` for fixed times, which a gap pushes forward, and 0 for interval slots, which a gap skips.
- Bound `could_beat` by the best occurrence's landing date instead of its scheduled date: stop forward once a candidate's date is past it, and backward once the candidate's date plus the times' shift is before it. An occurrence lands on or after its scheduled date, on a first pass, and first passes keep wall-clock order. The `Occurrence` then keeps that landing date.
- End `matches`' forward search on the minute's wall date: an occurrence never lands before the date it is scheduled on.
- Drop an instant outside the supported range where it is resolved instead of filtering the result: the nearest instant is out of range only when every farther one is.

## Pull Requests

- Create a branch from `main`
- Keep changes focused — one logical change per PR
- Write clear commit messages (we use [conventional commits](https://www.conventionalcommits.org/))
- **All commits must be signed** — see [GitHub's guide on commit signing](https://docs.github.com/en/authentication/managing-commit-signature-verification/signing-commits)
- CI must pass before merge

## Releases

Releases are managed by the maintainer via `just release <version>`. See the justfile for details.

## AI-Assisted Contributions

LLM-assisted contributions are welcome. If you're using an AI coding agent, please follow [AGENTS.md](AGENTS.md) and stick to the repo's existing styles and conventions.

## Questions & Feedback

We use [GitHub Discussions](https://github.com/simpllyf/hron/discussions) for questions, ideas, and general conversation — issues are disabled in favor of a more open-ended format. Feel free to open a discussion or comment on an existing one.
