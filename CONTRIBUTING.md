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
2. Walk the cadence's aligned periods in the search direction: `per_400_years / gcd(per_400_years, interval)` of them plus `HORIZON_MARGIN_PERIODS`, extended to the farthest ISO `except` date (spec/README.md, "Search horizon"). Skip a day or month period whose month `during` rejects. The walk ends early at the calendar's edge: the first period past years 1 to 9999, with one period of slack on each side (a nearest weekday in December of year 0 lands on 0001-01-01), or sooner where the platform's dates end.
3. Take each period's candidate dates in direction order. Stop once a candidate can no longer beat the best occurrence found (`could_beat`), or is past the clause bound the search moves toward (`ends_search`). Skip a candidate that lies wholly behind the instant (`is_behind`) or that the clauses reject. Otherwise find its occurrence nearest the instant (`nearest_on_date`), and replace the best only when it is strictly nearer.

`could_beat` and `is_behind` rest on one fact: an occurrence lands on a first pass, from its scheduled date to `max_shift_days` after it (one for fixed times, which a gap pushes forward; none for interval slots, which a gap skips), and first passes keep wall-clock order. Forward, a candidate can beat the best only on or before the best's landing date; backward, only within `max_shift_days` of it. A candidate is behind the instant forward when its dates end before the instant's wall date, and backward when it is more than `MAX_OVERLAP_DAYS` after it: from the second pass of a fall-back that crosses midnight, the wall date reads one behind a date that has begun.

Each concept has one name, in the language's casing:

| Concept | Name |
|---|---|
| Search direction | `Direction` (`Forward`, `Backward`) with `sign` and `precedes` |
| A schedule prepared for searching | `Search`, with `nearest(now, direction)` and `nearest_on_date` |
| The periods an expression fires in | `Cadence`: `period_of`, `start_of`, `period_starts` |
| A date it fires on, with the month whose day it names | `Candidate` (`date`, `target_month`), from `candidates_in_period` |
| The times of day it fires at | `DailyTimes`: fixed times or interval slots, with `max_shift_days` |
| Trailing clauses | `Clauses`: `allows`, `allows_month`, `clamp`, `ends_search`, `end_on`, `farthest_except_date` |
| A found occurrence | `Occurrence` (`instant`, and the `landing` date it falls on), kept while `could_beat` holds |
| Wall time on a date | `fixed_time_on` (shifted out of a gap), `slot_on` (a `Slot` with its `key` and, outside a gap, its `instant`); both take a repeated time's first pass |
| Supported range | `RANGE_START`, `RANGE_END`, `in_supported_range` |

And it follows these rules:

- Direction enters only through `Direction` and the clause and cadence primitives. A date's slots are found by one binary search on their keys, which never decrease in wall-clock order (a slot's instant, or the instant its gap ends), so nothing is mirrored.
- A date's fixed times are all compared, in one pass: a time shifted out of a gap can land after a later wall time.
- A search prepares its schedule once: zone, cadence, times and clauses, with ISO dates parsed once.
- Numbers that bound a loop are named constants with their reason: `HORIZON_MARGIN_PERIODS`, `MAX_SHIFT_DAYS`, `MAX_OVERLAP_DAYS`, `NAMED_UNTIL_MAX_YEARS`. There are no fixed scan spans.
- Calendar arithmetic and wall-clock resolution live in their own units, apart from the search.
- `matches` is the forward search from just before the minute, ended on the minute's wall date (`end_on`), so the two cannot disagree: an occurrence never lands before the date it is scheduled on.

Where a platform needs it, an implementation may also:

- Number periods by their calendar index instead of their first date, where a date type cannot hold December of year 0 or building dates is costly.
- Drop an instant outside the supported range where it is resolved instead of filtering the result: the nearest instant is out of range only when every farther one is.
- Find a date's slots from the index of the instant's wall minute instead of a binary search on keys, where resolving a slot is costly: forward from the next slot, backward from the slot at the wall minute read on its first pass. These are the two slot scans that may be mirrored.
- Resolve a date's slots once into an ascending list of instants, gap slots dropped, and binary-search that list: it needs no gap keys.
- Find a gap's end without a transition API by binary-searching whole seconds between the wall time read with the offsets after and before the gap: every slot instant is a whole second, so the first second at or after the transition is as good a key.
- Narrow a date's binary search with the UTC offsets a day either side of it, where offset changes are days apart: on a date without a change, the keys follow from the wall minutes.

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

We use [GitHub Discussions](https://github.com/prasrvenkat/hron/discussions) for questions, ideas, and general conversation — issues are disabled in favor of a more open-ended format. Feel free to open a discussion or comment on an existing one.
