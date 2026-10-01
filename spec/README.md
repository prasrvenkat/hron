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

### Writing a runner

A conformance runner must fail any case it cannot check: a section it does not know, a case with no assertion field it understands, or an invariant rule it does not implement. Silently skipping is a pass that checked nothing. A field that is present with the value `null` or `[]` is an assertion (no occurrence, empty list), not an absent field. The assertion fields per `eval` section are:

- **`matches`** - `datetime`; asserts `expected` (boolean) for `matches(datetime)`.
- **`previous_from`** - `now`; asserts `expected` (timestamp or null) for `previousFrom(now)`.
- **`occurrences`** - `from`, `take`; asserts `expected` (list) for the first `take` elements of `occurrences(from)`.
- **`between`** - `from`, `to`; asserts `expected` (list) or `expected_count` (number) for `between(from, to)`.
- **every other section** (`day_repeat`, `interval_repeat`, `week_repeat`, `month_repeat`, `year_repeat`, `single_date`, `leap_year`, `dst_spring_forward`, `dst_fall_back`, ...) - optional `now` (defaults to the top-level `now`); asserts one or more of `next` (timestamp or null for `nextFrom`), `next_date` (the date of `nextFrom` in the schedule's timezone), `next_n` (list from `nextNFrom(now, next_n_count)`, where `next_n_count` defaults to the list length, so an empty `next_n` always comes with an explicit `next_n_count`) and `next_n_length` (length of `nextNFrom(now, next_n_count)`).

The other sections:

- **`parse.*`** - `input`; asserts that `toString(parse(input))` equals `canonical`, and that parsing `canonical` again gives `canonical`.
- **`parse_errors`** - `input` and `error` (`kind`, `message`, `span` as `[start, end]`, and `suggestion` when there is one); asserts that `parse(input)` fails with exactly that kind, message and span, with that suggestion or none, and that `validate(input)` is false. When `display` is present, asserts that `displayRich()` of the error equals it.
- **`cron.to_cron`** - `hron`; asserts `toCron(parse(hron))` equals `cron`. **`cron.to_cron_errors`** - `hron`, `error`; asserts `toCron(parse(hron))` fails with a `cron` error whose message equals `error`.
- **`cron.from_cron`** - `cron`; asserts `toString(fromCron(cron))` equals `hron`. **`cron.from_cron_errors`** - `cron`, `error`; asserts `fromCron(cron)` fails with a `cron` error whose message equals `error`.
- **`cron.roundtrip`** - `hron`; with `c = toCron(parse(hron))`, asserts `toCron(fromCron(c))` equals `c`.
- **`invariants`** - entries carry `name`, `expression` and `now`; every rule in `invariants.rules` applies to every entry.

`name` and `description` are labels, not assertions.

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

Each error has:

1. **kind**: `lex`, `parse`, `eval` or `cron`.
2. **message**: exactly the text this spec gives for its condition.
3. **span** (`lex` and `parse` only): `[start, end)`, counted in Unicode code points of the input, never in bytes or UTF-16 units. A lone surrogate counts as one code point, and so does each byte of invalid UTF-8.
4. **input** (`lex` and `parse` only): the input as given.
5. **suggestion** (`parse` only, and only where this spec gives one): text to put in place of the span, where `YYYY-MM-DD` is left for the user to fill in.

Every invalid expression fails in `parse` (and `validate` returns false) with a `lex` or `parse` error; evaluating a parsed schedule never fails, and no input raises any other exception. `eval` is reserved for schedules built in code.

### Words

Words match in any ASCII case. Spellings joined by "or", or listed on a row headed by a word, are the same word:

| Word | Spellings |
|---|---|
| keywords | `every`, `on`, `at`, `from`, `to`, `in`, `of`, `the`, `last`, `except`, `until`, `starting`, `during`, `nearest`, `next`, `previous` |
| `day` | `day`, `days` |
| `weekday` | `weekday`, `weekdays` |
| `weekend` | `weekend`, `weekends` |
| `week` | `week`, `weeks` |
| `month` | `month`, `months` |
| `year` | `year`, `years` |
| `min` | `min`, `mins`, `minute`, `minutes` |
| `hours` | `hour`, `hours`, `hr`, `hrs` |
| day names | `monday` or `mon`, `tuesday` or `tue`, `wednesday` or `wed`, `thursday` or `thu`, `friday` or `fri`, `saturday` or `sat`, `sunday` or `sun` |
| month names | `january` or `jan`, `february` or `feb`, `march` or `mar`, `april` or `apr`, `may`, `june` or `jun`, `july` or `jul`, `august` or `aug`, `september` or `sep`, `october` or `oct`, `november` or `nov`, `december` or `dec` |
| ordinals | `first`, `second`, `third`, `fourth`, `fifth` |

### Tokens

`parse` first splits the whole input into tokens, then parses them. Splitting stops at the first `lex` error, which wins over any `parse` error. Spaces, tabs, carriage returns and line feeds separate tokens, but tokens need no whitespace between them: `30min` is `30` and `min`. Reading from the start:

- Right after the word `in` and any whitespace, the run of characters up to the next whitespace or the end is a **timezone**, whatever its characters. Only that one run is: in `in UTC UTC`, the second `UTC` is a word.
- `,` is a token.
- A **word** is an ASCII letter followed by ASCII letters, digits and `_`. It must be one of the words above.
- A run of ASCII **digits** is read as follows, in order:
  - A run of exactly four digits, then `-`, two digits, `-` and two digits, forms an **ISO date** of those ten characters.
  - A run followed by `:` is a **time**. Its text runs through the `:` and the run of digits after it. It must be one or two digits, `:` and exactly two digits; then the hour must be 0-23 and the minute 0-59.
  - Otherwise the run is a **number**, which must be at most 2147483647; leading zeros are allowed. When the next two characters are `st`, `nd`, `rd` or `th` in any ASCII case, they join it as an **ordinal day** (`1st`, `15TH`).
- Any other character is an error.

### Lex errors

| Condition | Message | Span |
|---|---|---|
| A character that starts no token | `unexpected character '{c}'` for a character from U+0021 to U+007E other than `'`, `unexpected character U+{XXXX}` for any other, with at least four uppercase hex digits | that character |
| A word not in the table above | `unknown keyword '{word}'` | the word |
| A time not written as one or two digits, `:` and two digits | `time must be H:MM or HH:MM, got {text}` | the time |
| A time out of range | `time must be 00:00-23:59, got {text}` | the time |
| A number above 2147483647 | `number must be at most 2147483647` | the digits, without an ordinal suffix |

`{word}`, `{text}` and `{c}` are the input as written. A lone surrogate is reported by its own value (`U+D800`), and a byte of invalid UTF-8 as `U+FFFD`; a binding that converts its input to UTF-8 before parsing, as WebAssembly does, sees a lone surrogate as U+FFFD. JSON cannot carry these portably, so each implementation whose strings can hold them tests them itself.

### Parse errors

When the parser needs one thing and finds another, the message is `expected {what}, got '{found}'`, with `{found}` the text of the token as written, or `expected {what}, got end of input`. The span is that token, or at the end of input the empty span at the end of the last token. `{what}` depends on the position:

| Position | `{what}` |
|---|---|
| The first token | `'every' or 'on'` |
| After `every` | `'day', 'weekday', 'weekend', a day name, 'week', 'month', 'year' or a number` |
| After `every` and a number | `a unit ('min', 'hours', 'days', 'weeks', 'months' or 'years')` |
| Before a time list, and after the date of a first-token `on` | `'at'` |
| A time: after `at`, after `,` in a time list, after `from`, after an interval's `to` | `a time (HH:MM)` |
| After an interval's unit | `'from'` |
| After `from` and its time | `'to'` |
| After an interval window's `on` | `'day', 'weekday', 'weekend' or a day name` |
| After `week`, `month` or `year` | `'on'` |
| A day name: in a week's list of day names, after `,` in a list of day names, after `first` to `fifth` | `a day name` |
| After a month repeat's `on` | `'the'` |
| After a month repeat's `the` | `a day such as 15th, 'last', an ordinal such as 'first', 'next', 'previous' or 'nearest'` |
| After a month repeat's `last` | `'day', 'weekday' or a day name` |
| After `next` or `previous` | `'nearest'` |
| After `nearest` | `'weekday'` |
| After `nearest weekday` | `'to'` |
| A day of the month: after `nearest weekday to`, after `,` in a list of days of the month, after `to` in a day range | `a day such as 15th` |
| After a year repeat's `on` | `a month name or 'the'` |
| After a year repeat's `the` | `a day such as 15th, 'last' or an ordinal such as 'first'` |
| After a year repeat's `last` | `'weekday' or a day name` |
| After a year repeat's ordinal and day name, its `last` and day name, its `last weekday`, or its day such as 15th | `'of'` |
| A month name: after `of`, after `during`, after `,` in a `during` list | `a month name` |
| After a month name in a date | `a day number` |
| After the first-token `on`, after `except`, after `,` in an `except` list, after `until` | `a date (YYYY-MM-DD, or a month and day)` |
| After `starting` | `a date (YYYY-MM-DD)` |
| After `in` | `a timezone` |

The parser checks a value as soon as it reads its token, before it reads the next one; a number right after `every` is the interval. A day that depends on its month is checked once the parser has read both the day and its month. These checks fail with:

| Condition | Message | Span |
|---|---|---|
| No tokens | `empty expression` | `[0, 0)` |
| An interval of 0 | `interval must be 1-2147483647, got {n}` | the number |
| A day outside 1-31 | `day must be 1-31, got {d}` | the day |
| A day from 1-31 beyond its month's last (February has 29) | `day must be 1-{max} for {mon}, got {d}` | the day |
| A day range whose start is after its end | `day range must not run backwards: {a} to {b}` | the start day through the end day |
| An interval window whose `from` is after its `to` | `time window must not run backwards: {from} to {to} (a window cannot cross midnight)` | the `from` time through the `to` time |
| An ISO date that is not a calendar date in years 0001-9999 | `date must be a calendar date from 0001-01-01 to 9999-12-31, got {date}` | the date |
| A timezone other than `UTC` or an `Area/Location` IANA name (see Parse-time validation) | `timezone must be UTC or an Area/Location name such as America/New_York, got {name}` | the timezone |

`{n}`, `{d}`, `{a}`, `{b}`, `{from}`, `{to}`, `{date}` and `{name}` are the input as written, a day with its suffix (`32nd`); `{mon}` is the month's three-letter name in lowercase.

After the expression, its clauses must come in the order `except`, `until`, `starting`, `during`, `in`, each at most once. A token left over after the last clause fails:

| Leftover token | Message | Span |
|---|---|---|
| The keyword of a clause already read | `duplicate '{kw}' clause` | the keyword |
| The keyword of a clause not yet read, which belongs before the last clause read | `'{kw}' must come before '{last}'` | the keyword |
| Anything else | `unexpected '{found}' after the schedule` | the token |

`{kw}` and `{last}` are the keywords in lowercase.

Only once the whole input has parsed does a named `until` date without `starting` fail, with `until {mon} {day} has no year: add a starting date, or use an ISO date`. The span runs from `until` through the date, and the suggestion is `until {mon} {day} starting YYYY-MM-DD`, with `{mon}` the month's three-letter name in lowercase and `{day}` the day's number without leading zeros or a suffix.

### Rich Display

`displayRich()` renders a `lex` or `parse` error as three lines joined by `\n`:

```
error: {message}
  {input}
  {spaces}{carets}
```

In `{input}`, each tab, carriage return and line feed shows as one space. `{spaces}` is `start` spaces and `{carets}` is `end - start` carets (`^`), at least one, both counted in code points, so wide characters and combining marks can shift the carets. When there is a suggestion, the last line ends with ` try: "{suggestion}"`. There is no trailing newline. An `eval` or `cron` error renders as `error: {message}` alone.

## Behavioral Semantics

These rules govern evaluation behavior across all implementations. Third-party implementations must follow these semantics to pass the conformance suite.

### Parse-time validation

These are parse errors, not evaluation errors:

- **Named `until` without `starting`**: `until dec 31` has no year, so it needs a `starting` date (or use an ISO date, `until 2026-12-31`); the error message says so and mentions `starting`.
- **Reversed time range**: `from 17:00 to 09:00`. `from` equal to `to` is valid and gives one slot a day.
- **Timezone names**: only `UTC` or an `Area/Location` name from the IANA database (`Etc/GMT+5` included). Abbreviations and offsets (`EST`, `GMT`, `Z`, `+05:30`) and unknown names are errors. Names match in any case and display with the IANA capitalization (`in utc` displays `in UTC`, `in america/new_york` displays `in America/New_York`); a link keeps its own name (`in us/eastern` displays `in US/Eastern`). Timezone names are ASCII, so non-ASCII input is rejected (a Kelvin sign is not a `k`), and names under `SystemV/`, `posix/` and `right/` are rejected.
- **Numbers**: an interval is 1 to 2147483647. Every numeric field rejects values out of its range (including very long digit strings) with a hron error.
- **ISO dates**: years 0001 to 9999 of the proleptic Gregorian calendar, so `1582-10-10` exists and `1500-02-29` does not.

### Named `until`

`until MON DAY` with `starting S` means the first such date on or after `S`, in the schedule's calendar: `until jan 15 starting 2026-06-01` ends on 2027-01-15, `until mar 1 starting 2026-03-01` on 2026-03-01 (inclusive), and `until feb 29 starting 2097-03-01` on 2104-02-29, the first real Feb 29. After that it behaves like the ISO date it resolves to. Display keeps the named form.

### Exception recurrence

Named exceptions (e.g., `except dec 25`) recur every year. ISO exceptions (e.g., `except 2026-12-25`) apply only to that specific date. This means `every day at 09:00 except dec 25` will skip December 25th every year, while `every day at 09:00 except 2026-12-25` will only skip it in 2026.

### Contradictory schedules

Schedules with mutually exclusive constraints parse successfully but return no occurrences. For example, `every month on the 31st at 09:00 during feb` is valid but `nextFrom` always returns null, because February never has a 31st. Implementations must never error or loop on contradictory schedules.

### DST spring-forward (gaps)

A fixed time (`at HH:MM`, including single dates) that does not exist because clocks spring forward fires at that time shifted forward by the length of the gap: 02:30 becomes 03:30 in `America/New_York` and `Australia/Sydney`, 01:30 becomes 02:30 in `Europe/London`, and 02:15 becomes 02:45 in `Australia/Lord_Howe` (a 30-minute gap). The rule is the same in every zone, including zones whose transition instant falls on the previous UTC date (Sydney, Lord Howe) and zones that change at midnight. The shift can carry an occurrence onto the next date: in `America/Nuuk` clocks jump from 23:00 to 00:00, so 23:30 on 2026-03-28 fires at 00:30 on 2026-03-29, ordered by instant among that date's own times (and returned once if one of them is the same instant). A shifted occurrence keeps its scheduled date (the date whose wall time did not exist) for the day filter and for `during`, `except`, `until` and `starting`, so `every day at 23:30 except mar 28` in Nuuk has no occurrence at 2026-03-29T00:30; unlike nearest weekday, where the date the occurrence lands on is the intended date and `except`, `until` and `starting` see that date. A whole skipped day (`Pacific/Apia` on 2011-12-30) is a 24-hour gap: its fixed times fire on the next day, and its interval slots are skipped. See the `dst_spring_forward` cases in `tests.json`.

### Interval slots in a spring-forward gap

Interval slots are `from + k × interval` in wall-clock time, from the `from` time up to and including the `to` time. An interval below 1, which only a schedule built in code can hold, counts as 1 of its unit: `0 hours` steps by an hour. A slot whose wall time does not exist is skipped, not shifted: on 2026-03-08 in `America/New_York`, `every 45 min from 00:00 to 04:00` fires at 01:30 EST and then 03:00 EDT (02:15 does not exist). Fixed times shift so a daily event is not lost; interval slots skip because the cadence continues.

### DST fall-back (ambiguous times)

When a schedule fires at a time that occurs twice during a DST fall-back transition (e.g., 01:30 when clocks go from 02:00 back to 01:00), implementations must use the **first** (pre-transition) occurrence. This applies in every timezone, including zones that shift by 30 minutes (`Australia/Lord_Howe`); the schedule already fired at the first pass, so the repeated wall time is not a second occurrence. Interval repeats resolve each wall-clock slot the same way.

### Comparisons use instants

`nextFrom`, `previousFrom`, `between` and `matches` compare instants, not wall-clock times. Inside a fall-back overlap 01:10 EST is later than 01:30 EDT, so from 01:10 EST the previous occurrence of `every day at 01:30` is 01:30 EDT the same night and the next is 01:30 the following day.

### Iterators return every occurrence

`nextNFrom`, `occurrences` and `between` return every occurrence in order, including occurrences one minute apart (`every day at 09:00, 09:01`, `every 1 min from 09:00 to 09:03`, or 23:59 followed by 00:00 the next day). Each instant appears once, even when two listed times resolve to the same instant.

### previousFrom mirrors nextFrom

`previousFrom(now)` returns the latest occurrence strictly before `now`, using the same day-skipping, interval-alignment (including dates before 1970), `during`, `except`, `until` and `starting` rules as `nextFrom`. A missing day is skipped rather than moved to the month's end, and a named date such as `on feb 29` returns the most recent real Feb 29. Before 1970, interval offsets from the anchor are negative whole days, months or years (floor, not truncation).

### Nearest weekday and `during`

`nearest weekday to Nth` moves a weekend target to the closest weekday within the same month (cron `W`). `next nearest` always moves forward to Monday and `previous nearest` always moves back to Friday, and both may cross into the adjacent month. The target month (the month whose day is named) is used for `during` and for interval alignment; `except`, `until` and `starting` apply to the date the occurrence lands on. So `every month on the previous nearest weekday to 1st during mar` fires on Friday 2026-02-27 because its target, Sunday 2026-03-01, is in March. June has no 31st, so `every month on the nearest weekday to 31st during jun` never fires.

### matches is true exactly when the minute containing t is an occurrence

`matches(t)` drops the seconds (and sub-seconds) of `t` on the schedule's wall clock (in the schedule's timezone), then is true if and only if the start of that minute is an occurrence. So 09:00:30 matches `every day at 09:00` but 09:01:30 does not; on DST days the shifted time of a skipped fixed time matches, and only the first pass of a repeated time matches (01:30:30 EST does not match `every day at 01:30`). Only `matches` drops seconds; `nextFrom`, `previousFrom` and `between` compare exact instants.

### Search horizon

Implementations must find any occurrence that exists. The (proleptic) Gregorian calendar repeats every 400 years, so a schedule with an interval of `n` years, months, weeks or days repeats every lcm(400 years, `n` of those units), except that a one-off ISO `except` date removes an occurrence without repeating. Going forward, the search starts at the later of `now` and the `starting` date and runs through one such span past the later of that start and the last ISO `except` date; going backward, it starts at the earlier of `now` and the `until` date and runs through one span before the earlier of that start and the first ISO `except` date. That finds the occurrence if one exists, and the result is null otherwise. For example, `every 11 years on the fifth sunday of february` next fires 406 years ahead (2432-02-29), and `every 400 years on jan 1 at 00:00 except 2400-01-01 starting 2000-01-01` next fires in 2800. Each call restarts the search from its own `now`.

### Supported range

Supported instants are those with `0001-01-02T00:00:00Z <= t < 9999-12-30T00:00:00Z` (proleptic Gregorian calendar). The day of margin at each end lets every platform represent the local time of any supported instant in any timezone. An occurrence outside the range does not exist, so the result is null: `every 9000 years on jan 1 at 09:00` has no next occurrence after 1970 (the next aligned year would be 10970), while `every 8000 years on jan 1 at 09:00` next fires in 9970. A `now`, `from`, `to` or `datetime` outside the range is not an error: `nextFrom` and `previousFrom` return null, `matches` returns false, and `nextNFrom`, `occurrences` and `between` return nothing.

### Timezone data

Behaviour with UTC offsets that are not whole minutes (local mean time before standard time was adopted, and Monrovia until 1972) is outside this spec. A platform that keeps offsets in whole minutes, as .NET does, moves such an occurrence by up to a minute, which can put it on the other side of `now` and skip it. DST rules far in the future depend on each platform's tz data: past the end of its data a platform keeps the zone's last offset (`package:timezone` has no rules after 2037, which leaves a southern-hemisphere zone on summer time), while `tzinfo` generates rules about 100 years ahead. The conformance suite therefore pins DST behaviour only before 2038 and only for transitions that are the same across tz data versions; after 2037 it uses only dates whose offset is the same under every platform's data, such as New York in winter. Which timezone names are accepted also follows each platform's tz data version: a name removed from IANA may still be accepted where the platform keeps it.

### End-of-month day handling

When a monthly schedule specifies a day that doesn't exist in a given month (e.g., `every month on the 31st` in a 30-day month), that month is skipped. The schedule does **not** cascade to the last available day — it waits for a month that actually has the specified day.

### The `starting` clause

`starting S` does two things. It is the anchor for interval alignment (`every 3 days`, `every 2 weeks`, `every 2 months`, `every 2 years`) in place of the default epoch anchor, and it is a lower bound: no occurrence falls on a date before `S`, in every method and for every expression kind, including interval windows and single dates (a single date before `S` never fires). The bound applies to the same date the other clauses see: the scheduled date of a DST-shifted time and the landing date of a nearest weekday. So `every 2 weeks on monday, friday starting 2026-02-11` (a Wednesday) anchors on the week of Monday 2026-02-09 but first fires on Friday 2026-02-13. For interval repeats (`every 30 min from 09:00 to 17:00`), the slots within a day always start at the `from` time; `starting` only decides which days fire.

### WeekRepeat epoch alignment

`WeekRepeat` schedules with `interval > 1` align to **epoch Monday** (1970-01-05), not epoch (1970-01-01, a Thursday). This ensures week-based intervals align naturally to week boundaries. With `starting`, the anchor is the Monday of the starting date's week.

### Evaluation order for trailing clauses

When multiple trailing clauses are present, they are applied in this order:

1. **`during`** — filter to only the specified months
2. **`except`** — exclude matching dates from the filtered set
3. **`until`** — stop after the cutoff date
4. **`starting`** — start on the starting date (it also sets the interval anchor)

## Cron Conversion

`fromCron` and `toCron` convert exactly or fail with a `cron` error. Exact means both fire at the same local times on the same dates. It ignores the timezone and DST transitions, where hron follows Behavioral Semantics and cron schedulers differ. When `fromCron(c)` succeeds, `toCron` of the result succeeds and fires as `c`. When `toCron(s)` succeeds, `fromCron` of the result fires as `s`, unless `s` fires more than 24 times a day and those times cannot be written as an interval on its days.

### Cron syntax

Leading and trailing spaces, tabs, carriage returns and line feeds are trimmed; between fields, one or more spaces (U+0020) or tabs (U+0009) separate. After trimming, input that starts with `@` is a shortcut, in any ASCII case: `@yearly` and `@annually` (`0 0 1 1 *`), `@monthly` (`0 0 1 * *`), `@weekly` (`0 0 * * 0`), `@daily` and `@midnight` (`0 0 * * *`), and `@hourly` (`0 * * * *`). Any other input is five fields separated by whitespace: minute (0-59), hour (0-23), day of month (1-31), month (1-12, or `jan` to `dec`) and day of week (0-7, or `sun` to `sat`, where 0 and 7 are Sunday).

Each field denotes a set of values. A field is a list of items separated by commas, none empty. An item is `*`, a value, or a range `a-b` with `a <= b`, each optionally followed by `/n` with `n >= 1`: `*/n` steps through the whole field, `a-b/n` through the range, and `a/n` from `a` to the field's maximum. A value is ASCII decimal digits, of any length and with leading zeros allowed; in the month and day-of-week fields it may also be a three-letter name in any ASCII case, wherever a value goes (`mon-fri/2`, `mon/2`, `fri#2`, `friL`), where `sun` is 0. A step count `n` and an ordinal `n` are always digits. For the day of week, `*` and `a/n` cover 0-6, 7 is Sunday only where written, and `7/n` is Sunday. A step larger than its range selects only the start.

`?` alone in the day of month or the day of week means `*`. The day of month may instead be `L` (the last day), `LW` (the last weekday) or `nW` (the weekday nearest day `n`, within the month; in a month without day `n` it never fires). The day of week may instead be `d#n` (the `n`-th weekday `d` of the month, `n` from 1 to 5) or `dL` (the last weekday `d` of the month). These letter forms take any ASCII case and are the whole field: no list, range or step. A day field is unrestricted only when it is exactly `*` or `?`. When both are restricted, cron fires on a day that matches either (Vixie cron and its descendants instead require both when a field starts with `*`, as in `*/2`), and no hron schedule expresses either reading.

### fromCron

The minute and hour fields give a set of times, every combination of a minute and an hour, taken in ascending order within the day. `fromCron` writes them as:

- `at t` for one time;
- `every n min from t1 to t2`, as hron displays it (`every n/60 hours` when 60 divides `n`), for three or more times with equal gaps of `n` minutes, when the day fields allow an interval. `t2` is the last time, or `23:59` when `t1` is `00:00` and the last time plus `n` is `24:00` or later;
- otherwise `at t1, t2, …` for at most 24 times;
- otherwise nothing: `fromCron` fails.

The day fields give the expression, for days that are sets of values:

| Day of month | Day of week | Expression |
|---|---|---|
| `*` | `*`, or all seven days | `every day` |
| `*` | Monday to Friday | `every weekday` |
| `*` | Saturday and Sunday | `every weekend` |
| `*` | other days | `every monday, wednesday`, in order of first appearance, 7 as Sunday, without repeats |
| `*` | `d#n` | `every month on the first monday` |
| `*` | `dL` | `every month on the last friday` |
| all 31 days | `*` | `every day` |
| days | `*` | `every month on the 1st, 15th`, ascending, each run of two or more consecutive days written `1st to 5th` |
| `L` | `*` | `every month on the last day` |
| `LW` | `*` | `every month on the last weekday` |
| `nW` | `*` | `every month on the nearest weekday to 15th` |

An interval needs days that the table writes as `every day`, `every weekday`, `every weekend` or a list of days of the week. Every day adds nothing; otherwise the interval ends `on weekday`, `on weekend` or `on monday, …`.

A month set of fewer than 12 months adds `during`, with the months in ascending order. When the month set is one month that has the day (February has 29), and the day is one value, `d#n`, `dL` or `LW`, the schedule is yearly instead: `every year on dec 25`, `every year on the first monday of mar`, `every year on the last friday of mar` or `every year on the last weekday of dec`. `L`, `nW` and a day the month never has stay monthly: `0 9 30 2 *` is `every month on the 30th at 09:00 during feb`, which never fires, like the cron.

### toCron

`toCron` is the inverse. It fails for:

- `except`, `until` and `starting`, which cron cannot bound;
- an ISO date, which does not repeat;
- a repeat every `n` days, weeks, months or years with `n > 1`, which cron cannot count;
- a directional nearest weekday (`next nearest`, `previous nearest`);
- a `during` that excludes a yearly or named date's month;
- a schedule built in code with no days or no times, which no cron field can write;
- times that are not every combination of their minutes and hours (`at 09:00, 17:30`, `every 45 min from 09:00 to 17:00`).

In every field, all of the field's values (60, 24, 31, 12 or 7) are written `*`. The minute and the hour are each written from their set of values, by the first rule that applies: every value is `*`; one value is that value; `0, n, 2n, …` up to the field's maximum, where `n >= 2` divides 60 (minute) or 24 (hour), is `*/n`; consecutive values `a` to `b` are `a-b`; three or more values `a, a+n, …, b` with `n >= 2` are `a-b/n`; otherwise an ascending list, each run of two or more consecutive values written `a-b`. The day of month, the month and the day of week use only `*`, single values, runs and lists, Sunday as 0: `1-5` for weekdays, `0,6` for the weekend, `L`, `LW`, `nW`, `d#n` and `dL` as above. A yearly or named date writes its own month, and `during` only decides whether it fails; other schedules write the `during` months. Schedules that fire identically can map to different crons. A schedule's timezone is not part of the cron: cron fires on its scheduler's clock, so run it in the schedule's timezone. Computing an interval's times must not overflow, however large its interval.

### Cron errors

Each failure is a `cron` error with exactly one of these messages, checked in this order: the shortcut, the field count, then the minute, hour, day of month, month and day of week fields in turn (each field's syntax first, then its items from left to right, and within an item its values, then the range's direction, then the step, then the ordinal), then the two day fields together, then the times.

| Condition | Message |
|---|---|
| Unknown shortcut | `unknown cron shortcut: {text}` |
| Wrong number of fields | `expected 5 cron fields, got {count}` |
| A field that is not valid syntax | `invalid {field}: {text}` |
| A value out of range (including `0W`, `32W`) | `{field} must be {min}-{max}, got {value}` |
| A range whose start exceeds its end | `{field} range must not run backwards: {a}-{b}` |
| A step of 0 | `{field} step must be at least 1` |
| `d#n` with `n` outside 1-5 | `day of week ordinal must be 1-5, got {n}` |
| Both day fields restricted | `not expressible in hron: cron fires on either the day of month or the day of week` |
| More than 24 times with equal gaps, on days an interval cannot carry | `not expressible in hron: an interval runs only on every day, weekdays, the weekend or listed days` |
| More than 24 times without equal gaps | `not expressible in hron: {count} times a day are too many to list` |
| `toCron` on a schedule cron cannot express | `not expressible as cron: {reason}` |

`{field}` is `minute`, `hour`, `day of month`, `month` or `day of week`; `{text}` is the field as written, or the trimmed input for a shortcut; `{value}`, `{a}`, `{b}` and `{n}` echo the input as written; `{count}` is a count. `toCron` reports the first of these reasons that applies, in this order: `except clauses not supported`, `until clauses not supported`, `starting clauses not supported`, `ISO dates do not repeat`, `multi-day repeats not supported`, `multi-week repeats not supported`, `multi-month repeats not supported`, `multi-year repeats not supported`, `directional nearest weekday not supported`, `schedule has no days`, `during excludes the schedule's month`, `schedule has no times`, `times are not every combination of their minutes and hours`.

## Invariants

The top-level `invariants` section of `tests.json` lists `{name, expression, now}` entries with no expected values. For each entry an implementation evaluates the expression at `now` with its public API and checks that its answers agree with each other, using `count` as the `n` for `nextNFrom`. Two timestamps are equal when they are the same instant. The rules (all must hold for every entry):

- **next_matches** - if `nextFrom(now)` is `t`, `matches(t)` is true.
- **next_after_now** - if `nextFrom(now)` is `t`, `t` is strictly after `now`.
- **next_n_chain** - `nextNFrom(now, count)` is strictly increasing, starts with `nextFrom(now)` (empty when that is null), and each later element is `nextFrom` of the one before it.
- **occurrences_prefix** - taking `count` elements from `occurrences(now)` gives `nextNFrom(now, count)`.
- **between_window** - if `nextNFrom(now, count)` ends with `L`, `between(now, L)` returns the same list.
- **prev_inverse** - for consecutive elements `a`, `b` of `nextNFrom(now, count)`, `previousFrom(b)` is `a`.
- **prev_before_now** - if `previousFrom(now)` is `p`, then `p` is strictly before `now`, `matches(p)` is true, and `nextFrom(p)` is null or not earlier than `now`.
- **display_roundtrip** - `toString` of the re-parsed `toString` output equals the first `toString` output.

## Versioning

The spec version is stored in `api.json` and `tests.json` under the `version` field, and in the `grammar.ebnf` header comment. These are stamped automatically by `just stamp-versions`.
