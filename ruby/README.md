# hron

**Human-readable cron** — scheduling expressions that read like English and convert to and from cron.

```ruby
require 'hron'

schedule = Hron::Schedule.parse("every weekday at 9:00 in America/New_York")
```

## Install

```sh
gem install hron
```

Or add to your Gemfile:

```ruby
gem 'hron'
```

## Usage

```ruby
require 'hron'

# Parse an expression
schedule = Hron::Schedule.parse("every weekday at 9:00 except dec 25, jan 1 in America/New_York")

# Get next occurrence
now = Time.now
next_time = schedule.next_from(now)
puts next_time

# Get next 5 occurrences
upcoming = schedule.next_n_from(now, 5)
upcoming.each { |t| puts t }

# Check if a time matches
schedule.matches(Time.new(2026, 2, 9, 9, 0, 0, "-05:00"))  # true: 09:00 in New York

# Convert to/from cron
simple = Hron::Schedule.parse("every day at 9:00")
puts simple.to_cron  # "0 9 * * *"

from_cron = Hron::Schedule.from_cron("*/30 * * * *")
puts from_cron  # "every 30 min from 00:00 to 23:59"

# Validate without exceptions
Hron::Schedule.validate("every day at 9:00")  # true
Hron::Schedule.validate("invalid")  # false
```

## Expression Syntax

See the full [expression reference](https://github.com/simpllyf/hron#expression-syntax).

## API

### `Hron::Schedule.parse(input) -> Schedule`
Parse an hron expression string.

### `Hron::Schedule.from_cron(cron_expr) -> Schedule`
Convert a 5-field cron expression to a Schedule that fires at the same times. This ignores the timezone and DST transitions, where cron schedulers differ. Raises `Hron::HronError` with `kind` `:cron` for invalid cron, for crons that restrict both the day of month and the day of week (`0 9 15 * 1`), and for more than 24 times a day, unless they are evenly spaced on days an interval can carry (`*/7 * * * *` fires 216 times at uneven gaps).

### `Hron::Schedule.validate(input) -> Boolean`
Check if an input string is a valid hron expression.

### `schedule.next_from(now) -> Time | nil`
Compute the next occurrence after `now`.

### `schedule.next_n_from(now, n) -> Array<Time>`
Compute the next `n` occurrences after `now`.

### `schedule.matches(time) -> Boolean`
Check if a time matches this schedule.

### `schedule.to_cron -> String`
Convert to a 5-field cron expression that fires at the same times. Yearly schedules, ordinal weekdays and partial-day intervals convert (`every 15 min from 09:00 to 17:45 on weekday` is `*/15 9-17 * * 1-5`). Raises `Hron::HronError` with `kind` `:cron` when no cron fires at the same times, as for `except`, `until`, `starting`, ISO dates, repeats every `n > 1` days, weeks, months or years, a directional nearest weekday, a `during` that excludes a yearly or named date's month, a schedule built in code with no days or no times, and times that are not every combination of their minutes and hours (`at 09:00, 17:30`). The timezone is not part of the cron: run it in the schedule's timezone. The [spec](https://github.com/simpllyf/hron/blob/main/spec/README.md#cron-conversion) has the full rules and every error message.

### `schedule.to_s -> String`
Render as the canonical string form (roundtrip-safe).

### `schedule.timezone -> String | nil`
The IANA timezone name with its canonical capitalization (`in utc` gives `"UTC"`), if specified.

### `schedule.expression -> ScheduleExpr`
The underlying schedule expression AST.

## Requirements

- Ruby >= 4.0
- TZInfo gem for timezone support. TZInfo generates DST rules only about 100 years ahead of the current year; past that it keeps the zone's last offset, which is summer time for a southern-hemisphere zone such as Australia/Sydney.

## License

MIT
