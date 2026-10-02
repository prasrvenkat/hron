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

# Get the next occurrence, in the schedule's timezone
now = Time.new(2026, 2, 6, 21, 0, 0, "+09:00")  # 07:00 in New York
puts schedule.next_from(now)  # 2026-02-06 09:00:00 -0500

# Get the next 3 occurrences
schedule.next_n_from(now, 3).each { |t| puts t }
# 2026-02-06 09:00:00 -0500
# 2026-02-09 09:00:00 -0500
# 2026-02-10 09:00:00 -0500

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

# Build from parts, checked as parse checks text
data = Hron::ScheduleData.new(
  expr: Hron::DayRepeat.new(1, Hron::DayFilterWeekday.new, [Hron::TimeOfDay.new(9, 0)]),
  timezone: "america/new_york"
)
puts Hron::Schedule.new(data)  # every weekday at 09:00 in America/New_York
begin
  Hron::Schedule.new(data.with(timezone: "EST"))
rescue Hron::HronError => e
  puts e.message  # timezone must be UTC or an Area/Location name such as America/New_York, got EST
end
```

## Expression Syntax

See the full [expression reference](https://github.com/simpllyf/hron#expression-syntax).

## API

### `Hron::Schedule.parse(input) -> Schedule`
Parse an hron expression string. Raises `Hron::HronError` with `kind` `:lex` or `:parse` when it is invalid (see [Errors](#errors)).

### `Hron::Schedule.from_cron(cron_expr) -> Schedule`
Convert a 5-field cron expression to a Schedule that fires at the same times. This ignores the timezone and DST transitions, where cron schedulers differ. Raises `Hron::HronError` with `kind` `:cron` for invalid cron, for crons that restrict both the day of month and the day of week (`0 9 15 * 1`), and for more than 24 times a day, unless they are evenly spaced on days an interval can carry (`*/7 * * * *` fires 216 times at uneven gaps).

### `Hron::Schedule.validate(input) -> Boolean`
Check if an input string is a valid hron expression.

### `Hron::Schedule.new(data) -> Schedule`
Build a schedule from a `Hron::ScheduleData` (see [Building a schedule](#building-a-schedule)), checked by the rules `parse` applies, so it evaluates, displays and converts as a parsed one does. Raises `Hron::HronError` with `kind` `:eval` and no `span`, `input` or `suggestion` for the first part that breaks a rule, with the message and in the order of the [spec](https://github.com/simpllyf/hron/blob/main/spec/README.md#schedules-built-in-code), and `TypeError` for a part of the wrong type. The schedule keeps a frozen copy of `data`, so changing `data`'s lists or strings afterwards does not change it.

### `schedule.next_from(now) -> Time | nil`
Compute the next occurrence after `now`.

### `schedule.previous_from(now) -> Time | nil`
Compute the most recent occurrence before `now`.

### `schedule.next_n_from(now, n) -> Array<Time>`
Compute up to `n` occurrences after `now`: none when `n <= 0`, and every one through the end of the supported range when there are fewer than `n`. Raises `TypeError` when `n` is not an `Integer`.

### `schedule.matches(time) -> Boolean`
Check if a time matches this schedule.

### `schedule.occurrences(from) -> Enumerator::Lazy<Time>`
Every occurrence after `from`, computed as it is taken.

### `schedule.between(from, to) -> Enumerator::Lazy<Time>`
Every occurrence after `from` and up to and including `to`.

### Times

Every method takes a `Time` in any zone or offset; only its instant counts, and the methods never change it. Anything else, such as a `String`, `Date`, `DateTime` or `nil`, raises `TypeError`. Every `Time` returned is in the schedule's timezone, with that `TZInfo::Timezone` as its `zone`, or UTC when the schedule has none.

### `schedule.to_cron -> String`
Convert to a 5-field cron expression that fires at the same times. Yearly schedules, ordinal weekdays and partial-day intervals convert (`every 15 min from 09:00 to 17:45 on weekday` is `*/15 9-17 * * 1-5`). Raises `Hron::HronError` with `kind` `:cron` when no cron fires at the same times, as for `except`, `until`, `starting`, ISO dates, repeats every `n > 1` days, weeks, months or years, a directional nearest weekday, a `during` that excludes a yearly or named date's month, and times that are not every combination of their minutes and hours (`at 09:00, 17:30`). The timezone is not part of the cron: run it in the schedule's timezone. The [spec](https://github.com/simpllyf/hron/blob/main/spec/README.md#cron-conversion) has the full rules and every error message.

### `schedule.to_s -> String`
Render as the canonical string form (roundtrip-safe).

### `schedule.timezone -> String | nil`
The IANA timezone name with its canonical capitalization (`in utc` gives `"UTC"`), if specified.

### `schedule.expression`
The schedule's expression, one of the classes under [Building a schedule](#building-a-schedule).

### `schedule.data -> ScheduleData`
The parts the schedule was built from, frozen, with the timezone in its IANA capitalization. `Hron::Schedule.new(schedule.data.with(timezone: "UTC"))` builds a changed copy.

### `schedule == other -> Boolean`
Schedules are equal when their parts are: `Hron::Schedule.parse("every day at 9:00")` equals the schedule built from the same parts.

## Building a schedule

`Hron::ScheduleData.new(expr:, timezone: nil, except: [], until: nil, anchor: nil, during: [])` holds a schedule's parts; every class here is a `Data` and takes its fields in this order, positionally or by name. `Hron::Schedule.new` checks them.

| Field | Value |
|---|---|
| `expr` | One expression below. |
| `timezone` | `"UTC"` or an IANA `Area/Location` name in any case, or `nil` for UTC. |
| `except` | An `Array` of `NamedException(month, day)` and `IsoException(date)`; empty means no `except` clause. |
| `until` | `NamedUntil(month, day)`, which needs `anchor`, `IsoUntil(date)`, or `nil`. |
| `anchor` | The `starting` date, or `nil`. |
| `during` | An `Array` of months; empty means no `during` clause. |

| Expression | Fields |
|---|---|
| `IntervalRepeat` | `interval`, `unit` (`:min` or `:hours`), `from_time`, `to_time`, `day_filter` (a day filter or `nil`) |
| `DayRepeat` | `interval`, `days` (a day filter, `DayFilterEvery` when `interval` is above 1), `times` |
| `WeekRepeat` | `interval`, `days` (an `Array` of weekdays), `times` |
| `MonthRepeat` | `interval`, `target`: `DaysTarget(specs)` of `SingleDay(day)` and `DayRange(start, end_day)`, `LastDayTarget`, `LastWeekdayTarget`, `NearestWeekdayTarget(day, direction)` with `direction` `nil`, `:next` or `:previous`, or `OrdinalWeekdayTarget(ordinal, weekday)`; `times` |
| `SingleDateExpr` | `date`: `NamedDate(month, day)` or `IsoDate(date)`; `times` |
| `YearRepeat` | `interval`, `target`: `YearDateTarget(month, day)`, `YearOrdinalWeekdayTarget(ordinal, weekday, month)`, `YearDayOfMonthTarget(day, month)` or `YearLastWeekdayTarget(month)`; `times` |

- `interval`, `day` and the `hour` and `minute` of `TimeOfDay(hour, minute)` are `Integer`s, `times` is an `Array` of `TimeOfDay`, and a date is a `"YYYY-MM-DD"` `String`.
- A day filter is `DayFilterEvery.new`, `DayFilterWeekday.new`, `DayFilterWeekend.new` or `DayFilterDays(days)`, with `days` an `Array` of weekdays.
- Names are `Symbol`s: weekdays `:monday` to `:sunday` (`Hron::Weekday::ALL`), months `:jan` to `:dec` (`Hron::MonthName::ALL`), and ordinals `:first` to `:fifth` and `:last` (`Hron::OrdinalPosition::ALL`). `Hron::OrdinalPosition.to_n` gives 1 to 5 for `:first` to `:fifth` and -1 for `:last`.
- A name of another type, such as `"monday"`, is a `TypeError`; an unknown `Symbol`, such as `:january`, is an `:eval` error (`unknown month :january`), as is any value where an expression, day filter, day spec, target, date, exception or until goes that is none of its classes.

## Errors

`Hron::Schedule.new` raises `Hron::HronError` with `kind` `:eval` and only a message (see [above](#hronschedulenewdata---schedule)); `display_rich` gives `error: {message}`. `Hron::Schedule.parse` raises `Hron::HronError` with `kind` `:lex` or `:parse`, the exact `message` of the [spec](https://github.com/simpllyf/hron/blob/main/spec/README.md#error-message-format), the `input` as given, a `span`, and for some parse errors a `suggestion` (otherwise `nil`). `display_rich` renders the error with carets under the span:

```text
error: until dec 31 has no year: add a starting date, or use an ISO date
  every weekday at 09:00 until dec 31
                         ^^^^^^^^^^^^ try: "until dec 31 starting YYYY-MM-DD"
```

`span.start` and `span.end_pos` mark `[start, end_pos)` in code points, which for a valid UTF-8 string are Ruby's own character indices: `error.input[error.span.start...error.span.end_pos]` is the text the error points at. Each byte of invalid UTF-8 counts as one code point and is reported as `unexpected character U+FFFD`. A binary (`ASCII-8BIT`) string is read as UTF-8 bytes, and a string in any other encoding is converted to UTF-8 first, so a lone UTF-16 surrogate is also U+FFFD.

## Requirements

- Ruby >= 4.0
- TZInfo gem for timezone support. TZInfo generates DST rules only about 100 years ahead of the current year; past that it keeps the zone's last offset, which is summer time for a southern-hemisphere zone such as Australia/Sydney.

## License

MIT
