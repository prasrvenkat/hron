# hron Specification

This directory contains the language-agnostic specification for hron (human-readable cron).

## Files

### `grammar.ebnf`

The formal grammar specification in [ISO 14977 EBNF](https://en.wikipedia.org/wiki/Extended_Backus%E2%80%93Naur_form) notation. This defines the syntax of valid hron expressions.

All language implementations use hand-written [recursive descent parsers](https://en.wikipedia.org/wiki/Recursive_descent_parser) based on this grammar (not generated from the EBNF).

### `tests.json`

The conformance test suite containing 495 test cases across three categories:

- **parse** - Tests for valid expression parsing and roundtrip (parse → toString → parse)
- **eval** - Tests for schedule evaluation (nextFrom, matches, DST handling)
- **cron** - Tests for cron conversion (toCron, fromCron)

All language implementations must pass all conformance tests. Test cases are loaded dynamically at runtime/compile-time.

### `api.json`

The API contract specification defining:

- **schedule.staticMethods** - `parse`, `fromCron`, `validate`
- **schedule.instanceMethods** - `nextFrom`, `nextNFrom`, `matches`, `toCron`, `toString`
- **schedule.getters** - `timezone`
- **error.kinds** - `lex`, `parse`, `eval`, `cron`
- **error.constructors** - Factory methods for each error kind
- **error.methods** - `displayRich`

Language implementations validate their APIs against this specification in their API conformance tests.

## Adding New Tests

When adding new test cases to `tests.json`:

1. Follow the existing structure for the test category (parse/eval/cron)
2. Include both positive and negative (error) test cases
3. Run all language test suites to verify the new tests pass

## Error Message Format

All hron implementations should produce error messages with consistent structure.

### Error Types

| Kind | When |
|------|------|
| `lex` | Invalid characters, malformed tokens |
| `parse` | Syntax errors, invalid grammar |
| `eval` | Runtime evaluation errors |
| `cron` | Cron conversion errors |

### Error Structure

Each error should include:

1. **kind**: One of: lex, parse, eval, cron
2. **message**: Human-readable description
3. **span** (lex/parse only): Start and end positions in input
4. **input** (lex/parse only): The original input string
5. **suggestion** (optional): Helpful hint for fixing the error

### Message Format Guidelines

- Use lowercase for error messages
- Include what was expected: "expected 'at', got 'in'"
- Include position context: "at position 15"
- Be specific: "invalid hour 25, must be 0-23"

### Rich Display

Implementations should provide a `displayRich()` method that formats errors with:
- The error message
- The input line with position indicator
- A caret (^) or underline showing the error location

## Versioning

The spec version is stored in `api.json` under the `version` field. All implementations should validate this version is present.
