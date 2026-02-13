# hron

**Human-readable cron** — scheduling expressions that are a superset of what cron can express.

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
schedule.matches(Time.new(2026, 2, 9, 9, 0, 0))  # true

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

See the full [expression reference](https://github.com/prasrvenkat/hron#expression-syntax).

## API

### `Hron::Schedule.parse(input) -> Schedule`
Parse an hron expression string.

### `Hron::Schedule.from_cron(cron_expr) -> Schedule`
Convert a 5-field cron expression to a Schedule.

### `Hron::Schedule.validate(input) -> Boolean`
Check if an input string is a valid hron expression.

### `schedule.next_from(now) -> Time | nil`
Compute the next occurrence after `now`.

### `schedule.next_n_from(now, n) -> Array<Time>`
Compute the next `n` occurrences after `now`.

### `schedule.matches(time) -> Boolean`
Check if a time matches this schedule.

### `schedule.to_cron -> String`
Convert to a 5-field cron expression. Raises `Hron::HronError` if the schedule can't be expressed as cron.

### `schedule.to_s -> String`
Render as the canonical string form (roundtrip-safe).

### `schedule.timezone -> String | nil`
The timezone, if specified.

### `schedule.expression -> ScheduleExpr`
The underlying schedule expression AST.

## Requirements

- Ruby >= 3.2
- TZInfo gem for timezone support

## License

MIT
