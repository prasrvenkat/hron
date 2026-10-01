# hron

**Human-readable cron** — scheduling expressions that read like English and convert to and from cron.

```python
from hron import Schedule

schedule = Schedule.parse("every weekday at 9:00 in America/New_York")
```

## Install

```sh
pip install hron
```

## Usage

```python
from datetime import datetime
from zoneinfo import ZoneInfo
from hron import Schedule

# Parse an expression
schedule = Schedule.parse("every weekday at 9:00 except dec 25, jan 1 in America/New_York")

# Get next occurrence
now = datetime.now(ZoneInfo("America/New_York"))
next_time = schedule.next_from(now)
print(next_time)

# Get next 5 occurrences
upcoming = schedule.next_n_from(now, 5)
for dt in upcoming:
    print(dt)

# Check if a datetime matches
schedule.matches(datetime(2026, 2, 9, 9, 0, tzinfo=ZoneInfo("America/New_York")))  # True

# Convert to/from cron
simple = Schedule.parse("every day at 9:00")
print(simple.to_cron())  # "0 9 * * *"

from_cron = Schedule.from_cron("*/15 9-17 * * 1-5")
print(from_cron)  # "every 15 min from 09:00 to 17:45 on weekday"

# Validate without exceptions
Schedule.validate("every day at 9:00")  # True
Schedule.validate("invalid")  # False
```

## Expression Syntax

See the full [expression reference](https://github.com/simpllyf/hron#expression-syntax).

## API

### `Schedule.parse(input: str) -> Schedule`
Parse an hron expression string. Raises `HronError` with `kind` `"lex"` or `"parse"` on an invalid expression (see [Errors](#errors)).

### `Schedule.from_cron(cron_expr: str) -> Schedule`
Convert a 5-field cron expression or `@` shortcut to a Schedule that fires at the same times. This ignores the timezone and DST transitions, where cron schedulers differ. Raises `HronError` with `kind == "cron"` when the input is not valid cron or has no exact hron equivalent: a cron that restricts both the day of month and the day of week (`0 9 15 * 1`), or more than 24 times a day, unless they are evenly spaced on days an interval can carry (`*/7 * * * *` fires 216 times at uneven gaps).

### `Schedule.validate(input: str) -> bool`
Check if an input string is a valid hron expression.

### `schedule.next_from(now: datetime) -> datetime | None`
Compute the next occurrence after `now`.

### `schedule.next_n_from(now: datetime, n: int) -> list[datetime]`
Compute the next `n` occurrences after `now`: fewer if the schedule ends, none if `n <= 0`. `n` only caps the count, so a huge `n` returns every occurrence through the end of the supported range. Raises `TypeError` if `n` is not an integer, that is, anything `operator.index` rejects, such as `2.0`.

### `schedule.matches(dt: datetime) -> bool`
Check if a datetime matches this schedule.

### `schedule.to_cron() -> str`
Convert to a 5-field cron expression that fires at the same times. Raises `HronError` with `kind == "cron"` for `except`, `until`, `starting`, an ISO date, a repeat every `n > 1` days, weeks, months or years, a directional nearest weekday, a `during` that excludes a yearly or named date's month, a schedule built in code with no days or no times, and times that are not every combination of their minutes and hours (`at 09:00, 17:30`). The schedule's timezone is not part of the cron: run it in the schedule's timezone. The [spec](https://github.com/simpllyf/hron/blob/main/spec/README.md#cron-conversion) has the full rules and every error message.

### `str(schedule) -> str`
Render as the canonical string form (roundtrip-safe).

### `schedule.timezone -> str | None`
The IANA timezone name with its canonical capitalization, if specified.

### `schedule.expression -> ScheduleExpr`
The underlying schedule expression AST.

## Timestamps

Each `now`, `from_`, `to` and `dt` names an instant, and the zone it is written in changes nothing. A naive `datetime` is read as the host's local time. Every returned `datetime` is aware and in the schedule's `ZoneInfo`, or `ZoneInfo("UTC")` when it has none. No method modifies its arguments.

```python
from datetime import datetime
from zoneinfo import ZoneInfo
from hron import Schedule

schedule = Schedule.parse("every day at 09:00 in America/New_York")
tokyo = datetime(2026, 2, 6, 21, 0, tzinfo=ZoneInfo("Asia/Tokyo"))  # 07:00 in New York
print(schedule.next_from(tokyo))  # 2026-02-06 09:00:00-05:00
schedule.next_from(tokyo).tzinfo  # zoneinfo.ZoneInfo(key='America/New_York')
```

A timestamp outside the supported range, `0001-01-02T00:00:00Z <= t < 9999-12-30T00:00:00Z`, is not an error, even at `datetime.min` and `datetime.max`: `next_from` and `previous_from` return `None`, `matches` returns `False`, and `next_n_from`, `occurrences` and `between` return nothing. A timestamp that is not a `datetime`, such as a `str`, a `date` or `None`, raises `TypeError`, and so does `occurrences` or `between` at the call, before anything is iterated.

## Errors

`Schedule.parse` raises `HronError` with `kind` `"lex"` or `"parse"`, `str(error)` the exact message of the spec, `input_text` the expression as given, and `span` the part of it the error points at. A parse error may carry a `suggestion`, text to put in place of the span. `display_rich()` renders the error with carets under the span:

```python
from hron import HronError, Schedule

try:
    Schedule.parse("every weekday at 09:00 until dec 31")
except HronError as error:
    error.kind        # "parse"
    str(error)        # "until dec 31 has no year: add a starting date, or use an ISO date"
    error.span        # Span(start=23, end=35)
    error.suggestion  # "until dec 31 starting YYYY-MM-DD"
    print(error.display_rich())
    # error: until dec 31 has no year: add a starting date, or use an ISO date
    #   every weekday at 09:00 until dec 31
    #                          ^^^^^^^^^^^^ try: "until dec 31 starting YYYY-MM-DD"
```

A span is `[start, end)` in code points, which is how Python indexes a `str`, so `error.input_text[error.span.start:error.span.end]` is the text it points at. For the UTF-8 byte offset of position `n`, use `len(error.input_text[:n].encode("utf-8", "surrogatepass"))`.

## License

MIT
