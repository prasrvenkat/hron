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

### `Schedule.parse(input_text: str) -> Schedule`
Parse an hron expression string. Raises `HronError` with `kind` `"lex"` or `"parse"` on an invalid expression (see [Errors](#errors)), and `TypeError` for anything that is not a `str`, `None` included.

### `Schedule.from_cron(cron_expr: str) -> Schedule`
Convert a 5-field cron expression or `@` shortcut to a Schedule that fires at the same times. This ignores the timezone and DST transitions, where cron schedulers differ. Raises `HronError` with `kind == "cron"` when the input is not valid cron or has no exact hron equivalent: a cron that restricts both the day of month and the day of week (`0 9 15 * 1`), or more than 24 times a day, unless they are evenly spaced on days an interval can carry (`*/7 * * * *` fires 216 times at uneven gaps). Raises `TypeError` for anything that is not a `str`, `None` included.

### `Schedule.validate(input_text: str) -> bool`
Check if an input string is a valid hron expression: `False` for anything `parse` rejects, unknown timezones included. Raises `TypeError` for anything that is not a `str`, `None` included, rather than returning `False`.

### `Schedule(data: ScheduleData) -> Schedule`
Build a schedule from its parts: the `expression` (`IntervalRepeat`, `DayRepeat`, `WeekRepeat`, `MonthRepeat`, `SingleDateExpr` or `YearRepeat`) and the clauses `except_`, `until`, `starting` (a date, as `YYYY-MM-DD`), `during` and `timezone`. The parts are checked with the rules `parse` applies, so a built schedule behaves as a parsed one: `str` of it parses back to an equal schedule, and evaluating it never fails. See [Building in code](#building-in-code).

### `schedule.data -> ScheduleData`
The parts the schedule was built from. Change one with `dataclasses.replace` and build again.

### `schedule.next_from(now: datetime) -> datetime | None`
Compute the next occurrence after `now`.

### `schedule.next_n_from(now: datetime, n: int) -> list[datetime]`
Compute the next `n` occurrences after `now`: fewer if the schedule ends, none if `n <= 0`. `n` only caps the count, so a huge `n` returns every occurrence through the end of the supported range. Raises `TypeError` if `n` is not an integer, that is, anything `operator.index` rejects, such as `2.0`.

### `schedule.previous_from(now: datetime) -> datetime | None`
Compute the most recent occurrence strictly before `now`, or `None` if there is none, such as before a `starting` date.

### `schedule.matches(dt: datetime) -> bool`
Check if a datetime matches this schedule: true when the minute containing `dt`, on the schedule's wall clock, is an occurrence.

### `schedule.occurrences(from_: datetime) -> Iterator[datetime]`
A lazy iterator of the occurrences strictly after `from_`, unbounded unless an `until` ends the schedule.

### `schedule.between(from_: datetime, to: datetime) -> Iterator[datetime]`
A lazy iterator of the occurrences where `from_ < occurrence <= to`.

### `schedule.to_cron() -> str`
Convert to a 5-field cron expression that fires at the same times. Raises `HronError` with `kind == "cron"` for `except`, `until`, `starting`, an ISO date, a repeat every `n > 1` days, weeks, months or years, a directional nearest weekday, a `during` that excludes a yearly or named date's month, and times that are not every combination of their minutes and hours (`at 09:00, 17:30`). The schedule's timezone is not part of the cron: run it in the schedule's timezone. The [spec](https://github.com/simpllyf/hron/blob/main/spec/README.md#cron-conversion) has the full rules and every error message.

### `str(schedule) -> str`
Render as the canonical string form (roundtrip-safe).

### Getters

Read-only properties, one per part. Assigning to one raises `AttributeError`, and what they return is frozen, so nothing can change the schedule.

| Property | Type | |
|---|---|---|
| `schedule.expression` | `ScheduleExpr` | The repeat: `IntervalRepeat`, `DayRepeat`, `WeekRepeat`, `MonthRepeat`, `SingleDateExpr` or `YearRepeat`. |
| `schedule.timezone` | `str \| None` | The IANA timezone name with its canonical capitalization, if specified. |
| `schedule.except_` | `tuple[ExceptionSpec, ...]` | The except dates, `NamedException` or `IsoException`; empty without an except clause. |
| `schedule.until` | `UntilSpec \| None` | The until date, `IsoUntil` or `NamedUntil`, if specified. |
| `schedule.starting` | `str \| None` | The starting date as `YYYY-MM-DD`, if specified. |
| `schedule.during` | `tuple[MonthName, ...]` | The during months; empty without a during clause. |

```python
from hron import Schedule

schedule = Schedule.parse("every weekday at 9:00 except dec 25 starting 2026-01-05 during jan, dec")
schedule.except_   # (NamedException(month=<MonthName.DEC: 'dec'>, day=25),)
schedule.until     # None
schedule.starting  # "2026-01-05"
schedule.during    # (<MonthName.JAN: 'jan'>, <MonthName.DEC: 'dec'>)
```

### `schedule == other`
Schedules are equal, and hash alike, when their parts are equal, however they were built: `every day at 9:00` equals `every day at 09:00`. Lists compare in order, duplicates included, as `str` writes them. A schedule never equals anything but a schedule, `None` included, and comparing never raises.

## Building in code

```python
import dataclasses
from hron import DayFilterWeekday, DayRepeat, HronError, Schedule, ScheduleData, TimeOfDay

schedule = Schedule(
    ScheduleData(DayRepeat(1, DayFilterWeekday(), (TimeOfDay(9, 0),)), timezone="america/new_york")
)
print(schedule)  # every weekday at 09:00 in America/New_York
schedule == Schedule.parse("every weekday at 9:00 in America/New_York")  # True

try:
    Schedule(dataclasses.replace(schedule.data, timezone="EST"))
except HronError as error:
    error.kind  # "eval"
    print(error.display_rich())
    # error: timezone must be UTC or an Area/Location name such as America/New_York, got EST
```

A part that breaks a rule raises `HronError` with `kind == "eval"`, the exact message of the [spec](https://github.com/simpllyf/hron/blob/main/spec/README.md#schedules-built-in-code), and no `span`, `input` or `suggestion`. The first part in the spec's order decides the message; its table lists every rule: an interval outside 1-2147483647, a `DayRepeat` with an interval above 1 on days other than `DayFilterEvery()`, a time outside 00:00-23:59, a window that runs backwards, no times or no days, a day outside 1-31 or beyond its month, a day range that runs backwards, a date that is not a calendar `YYYY-MM-DD` from 0001-01-01 to 9999-12-31, a timezone other than `UTC` or an IANA `Area/Location` name, and a `NamedUntil` without `starting`. Any value where an expression, day filter, day spec, month or year target, date, exception or until goes that is none of its classes, `None` included, raises `unknown {kind} {value!r}`: `unknown day filter None`.

A value of the wrong type is a `TypeError`, not a `HronError`: anything but a member of the name's `Enum` where a `Weekday`, `MonthName`, `OrdinalPosition`, `IntervalUnit` or `NearestDirection` goes (`"monday"`, `1` and `None` included, though `None` is a `NearestWeekdayTarget`'s plain nearest direction), a `str`, `float` or `bool` where an `int` goes, anything but a `list` or `tuple` where a sequence goes (`None` included), anything but a `str` for a date, `starting` or `timezone`, and anything but a `TimeOfDay` for a time.

Building copies the parts, so changing a list afterwards does not change the schedule; lists are kept as tuples. `ScheduleData` and every part are frozen, so nothing a getter returns can change the schedule either. An empty `except_` or `during` is no clause, and the timezone is kept in its IANA capitalization, as `parse` keeps it.

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

`Schedule(ScheduleData(...))` raises `HronError` with `kind` `"eval"` (see [Building in code](#building-in-code)). `Schedule.parse` raises `HronError` with `kind` `"lex"` or `"parse"`, `message` (also `str(error)`) the exact message of the spec, `input` the expression as given, and `span` the part of it the error points at. A parse error may carry a `suggestion`, text to put in place of the span. `display_rich()` renders the error with carets under the span:

```python
from hron import HronError, Schedule

try:
    Schedule.parse("every weekday at 09:00 until dec 31")
except HronError as error:
    error.kind        # "parse"
    error.message     # "until dec 31 has no year: add a starting date, or use an ISO date"
    error.input       # "every weekday at 09:00 until dec 31"
    error.span        # Span(start=23, end=35)
    error.suggestion  # "until dec 31 starting YYYY-MM-DD"
    print(error.display_rich())
    # error: until dec 31 has no year: add a starting date, or use an ISO date
    #   every weekday at 09:00 until dec 31
    #                          ^^^^^^^^^^^^ try: "until dec 31 starting YYYY-MM-DD"
```

A span is `[start, end)` in code points, which is how Python indexes a `str`, so `error.input[error.span.start:error.span.end]` is the text it points at. For the UTF-8 byte offset of position `n`, use `len(error.input[:n].encode("utf-8", "surrogatepass"))`.

### `HronError`

| Member | |
|---|---|
| `kind` | `"lex"`, `"parse"`, `"eval"` or `"cron"` (`HronErrorKind`). |
| `message` | The message alone; `str(error)` is the same. |
| `span` | A `Span(start, end)` for lex and parse errors, else `None`. |
| `input` | The expression as given for lex and parse errors, else `None`. |
| `suggestion` | Text to put in place of the span, when a parse error has one, else `None`. |
| `display_rich()` | The message, then for lex and parse errors the input with carets under the span and any suggestion. |
| `HronError.lex(message, span, input)`, `HronError.parse(message, span, input, suggestion=None)`, `HronError.eval(message)`, `HronError.cron(message)` | Build an error of each kind. Raises `TypeError` if `message` or `input` is not a `str`, `span` is not a `Span`, or `suggestion` is neither a `str` nor `None`. |
| `HronError(kind, message, span=None, input=None, suggestion=None)` | Build an error from its members. Raises `TypeError` if `message` is not a `str`, `span` is neither a `Span` nor `None`, or `input` or `suggestion` is neither a `str` nor `None`. |

### Usage errors

A bad argument raises Python's `TypeError`, never `HronError`: an input to `parse`, `validate` or `from_cron` that is not a `str`, a timestamp that is not a `datetime`, an `n` that is not an integer, a part of the wrong type in `ScheduleData` (see [Building in code](#building-in-code)), and a `message`, `span`, `input` or `suggestion` of the wrong type when building a `HronError`.

## License

MIT
