# AGENTS.md

## Project

hron (human-readable cron) — a language spec + native implementations for parsing/evaluating human-readable schedule expressions. Monorepo with per-language directories.

## Repo Layout

```
VERSION           # Single source of truth for all package versions
.tool-versions    # Pinned language versions (mise/asdf compatible)
justfile          # Build/test/release commands
spec/             # Language-agnostic grammar (EBNF) + conformance tests (JSON)
rust/             # Rust lib + CLI + WASM bindings
ts/               # Native TypeScript implementation
dart/             # Native Dart implementation
python/           # Native Python implementation
```

## Code Style

- Write self-describing code. Avoid comments unless they explain something not obvious from reading the code itself.
- No unnecessary abstractions. Three similar lines is better than a premature helper.
- Keep functions short and focused. If a name needs a comment to explain it, rename it.

## Git Workflow

- Never commit directly to main. Always use feature branches.
- Use [conventional commits](https://www.conventionalcommits.org/): `fix:`, `feat:`, `refactor:`, `docs:`, `ci:`, `test:`, `perf:`, `chore:`. Scope is optional: `fix(eval):`.
- Lowercase after prefix: `fix: leap year edge case in eval`, not `fix: Leap Year Edge Case In Eval`.
- Keep commit messages short and intent-focused. Skip detailed descriptions unless the "why" isn't obvious.
- Squash merge PRs.

## Spec

- `spec/grammar.ebnf` defines the language grammar.
- `spec/tests.json` is the conformance test suite. All implementations must pass every case.
- Trailing clause order is strict: `<expr> [except ...] [until ...] [starting ...] [during ...] [in <tz>]`
- Tests use a fixed "now": `2026-02-06T12:00:00+00:00[UTC]` (a Friday). Never use real time in tests.
- Display must roundtrip: `parse(display(parse(input))) == parse(input)` always.

## Adding a New Language

1. Create `<language>/` at repo root with native build tooling
2. Implement parser + evaluator passing all cases in `spec/tests.json`
3. Add `just test-<lang>` target, add to `test-all`
4. Add `.github/workflows/<lang>.yml` (use `jdx/mise-action` with `install_args`)
5. Add conformance job to `.github/workflows/spec.yml`
6. Pin language version in `.tool-versions`
7. Update packages table in `README.md`

## Versioning

Lock-step across all packages. `VERSION` file at root is stamped into each language's manifest at release time. One tag, CI publishes everything.

## Commands

```sh
just test-all         # All languages
just test-rust        # Rust only
just test-ts          # TypeScript only
just test-dart        # Dart only
just test-python      # Python only
just build-wasm       # WASM target
just stamp-versions   # Stamp VERSION into all package manifests
just release          # Tag + prep release
```
