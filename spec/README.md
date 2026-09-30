# hron Specification

This directory contains the language-agnostic specification for hron (human-readable cron).

## Files

### `grammar.ebnf`

The formal grammar specification in [ISO 14977 EBNF](https://en.wikipedia.org/wiki/Extended_Backus%E2%80%93Naur_form) notation. This defines the syntax of valid hron expressions.

All language implementations use hand-written [recursive descent parsers](https://en.wikipedia.org/wiki/Recursive_descent_parser) based on this grammar (not generated from the EBNF).

### `tests.json`

The conformance test suite covering four categories:

- **parse** - Tests for valid expression parsing and roundtrip (parse → toString → parse)
- **eval** - Tests for schedule evaluation (nextFrom, previousFrom, matches, occurrences, between, DST handling)
- **cron** - Tests for cron conversion (toCron, fromCron)
- **invariants** - Self-consistency checks with no expected values (see [Invariants](#invariants))

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

1. Follow the existing structure for the test category (parse/eval/cron/invariants)
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

Schedules with mutually exclusive constraints parse successfully but return no occurrences. For example, `every month on the 31st at 09:00 during feb` is valid but `nextFrom` always returns null, because February never has a 31st. Implementations must never error or loop on contradictory schedules.

### DST spring-forward (gaps)

A fixed time (`at HH:MM`, including single dates) that does not exist because clocks spring forward fires at that time shifted forward by the length of the gap: 02:30 becomes 03:30 in `America/New_York` and `Australia/Sydney`, 01:30 becomes 02:30 in `Europe/London`, and 02:15 becomes 02:45 in `Australia/Lord_Howe` (a 30-minute gap). The rule is the same in every zone, including zones whose transition instant falls on the previous UTC date (Sydney, Lord Howe). See the `dst_spring_forward` cases in `tests.json`.

### Interval slots in a spring-forward gap

Interval slots are `from + k × interval` in wall-clock time, from the `from` time up to and including the `to` time. A slot whose wall time does not exist is skipped, not shifted: on 2026-03-08 in `America/New_York`, `every 45 min from 00:00 to 04:00` fires at 01:30 EST and then 03:00 EDT (02:15 does not exist). Fixed times shift so a daily event is not lost; interval slots skip because the cadence continues.

### DST fall-back (ambiguous times)

When a schedule fires at a time that occurs twice during a DST fall-back transition (e.g., 01:30 when clocks go from 02:00 back to 01:00), implementations must use the **first** (pre-transition) occurrence. This applies in every timezone, including zones that shift by 30 minutes (`Australia/Lord_Howe`); the schedule already fired at the first pass, so the repeated wall time is not a second occurrence. Interval repeats resolve each wall-clock slot the same way.

### Comparisons use instants

`nextFrom`, `previousFrom`, `between` and `matches` compare instants, not wall-clock times. Inside a fall-back overlap 01:10 EST is later than 01:30 EDT, so from 01:10 EST the previous occurrence of `every day at 01:30` is 01:30 EDT the same night and the next is 01:30 the following day.

### Iterators return every occurrence

`nextNFrom`, `occurrences` and `between` return every occurrence in order, including occurrences one minute apart (`every day at 09:00, 09:01`, `every 1 min from 09:00 to 09:03`, or 23:59 followed by 00:00 the next day). Each instant appears once, even when two listed times resolve to the same instant.

### previousFrom mirrors nextFrom

`previousFrom(now)` returns the latest occurrence strictly before `now`, using the same day-skipping, interval-alignment (including dates before 1970), `during`, `except` and `until` rules as `nextFrom`. A missing day is skipped rather than moved to the month's end, and a named date such as `on feb 29` returns the most recent real Feb 29. Before 1970, interval offsets from the anchor are negative whole days, months or years (floor, not truncation). The `starting` clause is outside this rule; see its own cases.

### Nearest weekday and `during`

`nearest weekday to Nth` moves a weekend target to the closest weekday within the same month (cron `W`). `next nearest` always moves forward to Monday and `previous nearest` always moves back to Friday, and both may cross into the adjacent month. The target month (the month whose day is named) is used for `during` and for interval alignment; `except` and `until` apply to the date the occurrence lands on. So `every month on the previous nearest weekday to 1st during mar` fires on Friday 2026-02-27 because its target, Sunday 2026-03-01, is in March. June has no 31st, so `every month on the nearest weekday to 31st during jun` never fires.

### matches is true exactly when the minute containing t is an occurrence

`matches(t)` drops the seconds (and sub-seconds) of `t`, then is true if and only if the start of that minute is an occurrence. So 09:00:30 matches `every day at 09:00` but 09:01:30 does not; on DST days the shifted time of a skipped fixed time matches, and only the first pass of a repeated time matches (01:30:30 EST does not match `every day at 01:30`). Only `matches` drops seconds; `nextFrom`, `previousFrom` and `between` compare exact instants.

### Search horizon

Implementations must find any occurrence that exists. The (proleptic) Gregorian calendar repeats every 400 years, so a schedule with an interval of `n` years, months, weeks or days repeats after lcm(400 years, `n` of those units); searching that span from `now` in the given direction finds the occurrence if one exists, and the result is null otherwise. For example, `every 11 years on the fifth sunday of february` next fires 406 years ahead (2432-02-29). Each call restarts the search from its own `now`.

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

## Invariants

The top-level `invariants` section of `tests.json` lists `{name, expression, now}` entries with no expected values. For each entry an implementation evaluates the expression at `now` with its public API and checks that its answers agree with each other, using `count` as the `n` for `nextNFrom`. Two timestamps are equal when they are the same instant. Entries do not use `starting`, whose semantics are covered by its own cases. The rules (all must hold for every entry):

- **next_matches** - if `nextFrom(now)` is `t`, `matches(t)` is true.
- **next_n_chain** - `nextNFrom(now, count)` is strictly increasing, starts with `nextFrom(now)` (empty when that is null), and each later element is `nextFrom` of the one before it.
- **occurrences_prefix** - taking `count` elements from `occurrences(now)` gives `nextNFrom(now, count)`.
- **between_window** - if `nextNFrom(now, count)` ends with `L`, `between(now, L)` returns the same list.
- **prev_inverse** - for consecutive elements `a`, `b` of `nextNFrom(now, count)`, `previousFrom(b)` is `a`.
- **prev_before_now** - if `previousFrom(now)` is `p`, then `p` is strictly before `now`, `matches(p)` is true, and `nextFrom(p)` is null or not earlier than `now`.
- **display_roundtrip** - `toString` of the re-parsed `toString` output equals the first `toString` output.

## Versioning

The spec version is stored in `api.json` and `tests.json` under the `version` field, and in the `grammar.ebnf` header comment. These are stamped automatically by `just stamp-versions`.
