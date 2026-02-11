# hron

**Human-readable cron** — scheduling expressions that are a superset of what cron can express.

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

from_cron = Schedule.from_cron("*/30 * * * *")
print(from_cron)  # "every 30 min from 00:00 to 23:59"

# Validate without exceptions
Schedule.validate("every day at 9:00")  # True
Schedule.validate("invalid")  # False
```

## Expression Syntax

See the full [expression reference](https://github.com/prasrvenkat/hron#expression-syntax).

## API

### `Schedule.parse(input: str) -> Schedule`
Parse an hron expression string.

### `Schedule.from_cron(cron_expr: str) -> Schedule`
Convert a 5-field cron expression to a Schedule.

### `Schedule.validate(input: str) -> bool`
Check if an input string is a valid hron expression.

### `schedule.next_from(now: datetime) -> datetime | None`
Compute the next occurrence after `now`.

### `schedule.next_n_from(now: datetime, n: int) -> list[datetime]`
Compute the next `n` occurrences after `now`.

### `schedule.matches(dt: datetime) -> bool`
Check if a datetime matches this schedule.

### `schedule.to_cron() -> str`
Convert to a 5-field cron expression. Raises `HronError` if the schedule can't be expressed as cron.

### `str(schedule) -> str`
Render as the canonical string form (roundtrip-safe).

### `schedule.timezone -> str | None`
The timezone, if specified.

### `schedule.expression -> ScheduleExpr`
The underlying schedule expression AST.

## License

MIT
