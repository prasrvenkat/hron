# Contributing to hron

Thanks for your interest in contributing to hron! This document covers everything you need to get started.

## Development Setup

### Prerequisites

- [just](https://github.com/casey/just) (command runner)
- [mise](https://mise.jdx.dev/) (tool version manager) — or install manually:
  - Rust 1.93+
  - Node.js 24+ (LTS) with pnpm
  - Dart 3.6+
  - Python 3.11+ with [uv](https://docs.astral.sh/uv/)

### Running Tests

```sh
# Run all tests across all languages
just test-all

# Or per-language
just test-rust
just test-ts
just test-dart
just test-python
```

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

1. Make the change
2. Ensure conformance tests still pass: `just test-all`
3. If the fix is relevant to other implementations, apply it there too

### Adding Conformance Tests

Test cases in `spec/tests.json` are the source of truth. When adding tests:

- Follow the existing structure (sections → cases)
- Include `name`, `expression`, `description`, and the relevant assertion (`next_date`, `next_n`, `matches`, `cron`, etc.)
- Run `just test-all` to verify all implementations pass

## Code Style

- **Rust**: `cargo fmt` + `cargo clippy -D warnings`
- **TypeScript**: `tsc --noEmit` (strict mode)
- **Dart**: `dart analyze` with `package:lints/recommended.yaml`
- **Python**: `ruff check` + `ruff format` + `mypy --strict`

CI enforces all of these. Run them locally before pushing.

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
