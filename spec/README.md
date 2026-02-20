# hron Specification

This directory contains the language-agnostic specification for hron (human-readable cron).

## Files

### `grammar.ebnf`

The formal grammar specification in [ISO 14977 EBNF](https://en.wikipedia.org/wiki/Extended_Backus%E2%80%93Naur_form) notation. This defines the syntax of valid hron expressions.

All language implementations use hand-written [recursive descent parsers](https://en.wikipedia.org/wiki/Recursive_descent_parser) based on this grammar (not generated from the EBNF).

### `tests.json`

The conformance test suite covering three categories:

- **parse** - Tests for valid expression parsing and roundtrip (parse → toString → parse)
- **eval** - Tests for schedule evaluation (nextFrom, previousFrom, matches, occurrences, between, DST handling)
- **cron** - Tests for cron conversion (toCron, fromCron)

All language implementations must pass all conformance tests. Test cases are loaded dynamically at runtime/compile-time.

### `api.json`

The API contract specification defining:

- **schedule.staticMethods** - `parse`, `fromCron`, `validate`
- **schedule.instanceMethods** - `nextFrom`, `nextNFrom`, `previousFrom`, `matches`, `occurrences`, `between`, `toCron`, `toString`
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

## Behavioral Semantics

These rules govern evaluation behavior across all implementations. Third-party implementations must follow these semantics to pass the conformance suite.

### Exception recurrence

Named exceptions (e.g., `except dec 25`) recur every year. ISO exceptions (e.g., `except 2026-12-25`) apply only to that specific date. This means `every day at 09:00 except dec 25` will skip December 25th every year, while `every day at 09:00 except 2026-12-25` will only skip it in 2026.

### Contradictory schedules

Schedules with mutually exclusive constraints parse successfully but return no occurrences. For example, `every weekend at 09:00 except sat, sun` is valid but `nextFrom` always returns null. Implementations must never error or loop on contradictory schedules.

### DST fall-back (ambiguous times)

When a schedule fires at a time that occurs twice during a DST fall-back transition (e.g., 01:30 when clocks go from 02:00 back to 01:00), implementations must use the **first** (pre-transition) occurrence.

### End-of-month day handling

When a monthly schedule specifies a day that doesn't exist in a given month (e.g., `every month on the 31st` in a 30-day month), that month is skipped. The schedule does **not** cascade to the last available day — it waits for a month that actually has the specified day.

### IntervalRepeat and the `starting` clause

The `starting` clause overrides the anchor date for alignment of multi-interval schedules (e.g., `every 3 days`). However, for `IntervalRepeat` expressions (e.g., `every 30 min from 09:00 to 17:00`), the interval timing within each day is determined by the `from` time, not the anchor. The `starting` clause only affects which days the schedule fires on when combined with a day filter.

### WeekRepeat epoch alignment

`WeekRepeat` schedules with `interval > 1` align to **epoch Monday** (1970-01-05), not epoch (1970-01-01, a Thursday). This ensures week-based intervals align naturally to week boundaries. The `starting` clause overrides this default anchor.

### Evaluation order for trailing clauses

When multiple trailing clauses are present, they are applied in this order:

1. **`during`** — filter to only the specified months
2. **`except`** — exclude matching dates from the filtered set
3. **`until`** — stop after the cutoff date

## Versioning

The spec version is stored in `api.json` and `tests.json` under the `version` field, and in the `grammar.ebnf` header comment. These are stamped automatically by `just stamp-versions`.
