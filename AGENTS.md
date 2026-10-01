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
go/               # Native Go implementation
java/             # Native Java implementation
csharp/           # Native C# implementation
ruby/             # Native Ruby implementation
```

## Code Style

- Write self-describing code. No unnecessary abstractions: three similar lines is better than a premature helper.
- Keep functions short and focused. If a name needs a comment to explain it, rename it.

## Comments

A comment is a claim about the code that nothing checks, so every comment must earn its place for the life of the code. Keep one only if it tells a future reader something the code cannot, and is unlikely to go stale:

- **Why**, when the code cannot show it: a spec rule, a platform or library quirk, a workaround and what it works around, or a fact the reader would otherwise look up, such as the weekday of a date a test asserts.
- **Public API contract**, in a line or two: what it returns, when it returns nothing, what it throws, and what the signature cannot carry (a numbering, what null means). IDEs and package registries show these. Public means what the package's documentation shows a user, not every symbol a language happens to export.

Non-public functions, types, constants and fields get no doc comment unless it states a why: their names and code say what they do, and a second description of the same thing is the first to go stale.

Everything else goes:

- Restating what the code does, or labelling the next line.
- Examples and usage. They belong in the language README, where readers look for them. Examples the toolchain runs are tests and stay: Rust doctests, Go `Example` functions, `dart/example/`.
- History ("previously", "now uses", "fixed"). That is what git is for.
- Section banners and dividers.
- TODOs. Raise the work in GitHub Discussions instead.
- Copies of the spec. Name the rule in `spec/README.md`, or the `spec/tests.json` case, instead of re-explaining it.

When you change code, fix or delete every comment it makes untrue.

Tool directives (`# frozen_string_literal`, `// biome-ignore`, `# noqa` and the like) are code, not comments. Before committing, run `just comments` and give every line it lists one of the two reasons above, or delete it. A reviewer does the same, line by line, and reports any comment without a reason.

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

## Tool Management

[mise](https://mise.jdx.dev/) manages all language runtimes. Always run commands through `mise exec` to ensure correct tool versions:

```sh
mise exec -- just test-all
mise exec -- just test-rust
```

Or activate mise in your shell (`mise activate`) so `just` commands use the right versions automatically.

## Commands

```sh
just test-all         # All languages
just test-rust        # Rust only
just test-ts          # TypeScript only
just test-dart        # Dart only
just test-python      # Python only
just test-go          # Go only
just test-java        # Java only
just test-csharp      # C# only
just test-ruby        # Ruby only
just build-wasm       # WASM target
just lint             # Lint all languages
just fmt              # Format all languages
just stamp-versions   # Stamp VERSION into all package manifests
just release          # Tag + prep release
```
