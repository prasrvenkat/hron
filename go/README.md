# hron Go Package

Go implementation of hron (human-readable cron).

## Installation

```sh
go get github.com/simpllyf/hron/go/v2
```

## Usage

```go
package main

import (
    "fmt"
    "time"

    "github.com/simpllyf/hron/go/v2"
)

func main() {
    // Parse an hron expression
    schedule, err := hron.ParseSchedule("every weekday at 9:00 except dec 25 in America/New_York")
    if err != nil {
        panic(err)
    }

    // Get the next occurrence
    next := schedule.NextFrom(time.Now())
    if next != nil {
        fmt.Println("Next occurrence:", next)
    }

    // Get the next 5 occurrences
    nextN := schedule.NextNFrom(time.Now(), 5)
    for i, t := range nextN {
        fmt.Printf("Occurrence %d: %v\n", i+1, t)
    }

    // Check if a time matches the schedule
    testTime := time.Date(2026, 2, 10, 9, 0, 0, 0, time.UTC)
    if schedule.Matches(testTime) {
        fmt.Println("Time matches the schedule")
    }

    // Convert to cron (if expressible)
    cron, err := schedule.ToCron()
    if err == nil {
        fmt.Println("Cron expression:", cron)
    }

    // Get the canonical string representation
    fmt.Println("Schedule:", schedule.String())

    // Get the timezone
    fmt.Println("Timezone:", schedule.Timezone())
}
```

## API

### Parse Functions

- `ParseSchedule(input string) (*Schedule, error)` - Parse an hron expression
- `MustParse(input string) *Schedule` - Parse an hron expression, panics on error
- `FromCronExpr(cronExpr string) (*Schedule, error)` - Convert a 5-field cron expression, or an `@` shortcut, to the Schedule that fires at the same times on the same dates
- `Validate(input string) bool` - Check if an input string is a valid hron expression
- `NewSchedule(data *ScheduleData) (*Schedule, error)` - Build a schedule in code from its parts (see [Building in code](#building-in-code))

### Schedule Methods

- `NextFrom(now time.Time) *time.Time` - Compute the next occurrence after now
- `NextNFrom(now time.Time, n int) []time.Time` - Compute up to n occurrences after now, none when `n <= 0`
- `Matches(dt time.Time) bool` - Report whether the minute containing `dt` (seconds dropped, on the schedule's wall clock) is an occurrence
- `ToCron() (string, error)` - Convert this schedule to the 5-field cron expression that fires at the same times on the same dates; run it in the schedule's timezone
- `String() string` - Render as canonical string (roundtrip-safe)
- `Timezone() string` - Get the IANA timezone name with its canonical capitalization, or empty string if not specified
- `Data() *ScheduleData` - Get a copy of the schedule's parts, to change and pass to `NewSchedule`

### Building in code

`NewSchedule` builds a schedule from its parts and checks them by the rules `ParseSchedule` applies ([spec](../spec/README.md#schedules-built-in-code)), so a built schedule evaluates, displays and converts to cron like a parsed one. It copies the parts, so changing them afterwards does not change the schedule, and `Data()` returns a copy too. The empty `Timezone` and `Anchor` mean none, and an empty `Except` or `During` is no clause:

```go
schedule, err := hron.NewSchedule(&hron.ScheduleData{
    Expr:     hron.NewDayRepeat(1, hron.NewDayFilterWeekday(), []hron.TimeOfDay{{Hour: 9, Minute: 0}}),
    Timezone: "america/new_york",
    Anchor:   "2026-01-05",
})
fmt.Println(schedule) // every weekday at 09:00 starting 2026-01-05 in America/New_York

data := schedule.Data()
data.Expr.Interval = 2
_, err = hron.NewSchedule(data)
fmt.Println(err) // days must be every day when the interval is above 1
```

The first part that breaks a rule fails the build with an `ErrorKindEval` error, which has only a message: no `Span`, `Input` or `Suggestion`.

### Timestamps

Every method reads only the instant of a `time.Time` you pass, whatever its `Location`, and returns times in the schedule's timezone, or UTC when it has none:

```go
s := hron.MustParse("every day at 09:00 in America/New_York")
tokyo, _ := time.LoadLocation("Asia/Tokyo")
next := s.NextFrom(time.Date(2026, 2, 6, 21, 0, 0, 0, tokyo))
fmt.Println(next.Location(), next) // America/New_York 2026-02-06 09:00:00 -0500 EST
```

`n` in `NextNFrom` only caps the count; no room is reserved for it. A time outside the supported range, `0001-01-02T00:00:00Z <= t < 9999-12-30T00:00:00Z`, the zero `time.Time` included, is not an error: `NextFrom` and `PreviousFrom` return nil, `Matches` returns false, and `NextNFrom`, `Occurrences` and `Between` return nothing. An occurrence outside the range does not exist ([spec](../spec/README.md#supported-range)).

### Error Handling

```go
_, err := hron.ParseSchedule("every weekday at 09:00 until dec 31")
var hronErr *hron.HronError
if errors.As(err, &hronErr) {
    fmt.Println(hronErr.Kind, hronErr.Message, *hronErr.Span, hronErr.Suggestion)
    fmt.Println(hronErr.DisplayRich())
}
```

```text
error: until dec 31 has no year: add a starting date, or use an ISO date
  every weekday at 09:00 until dec 31
                         ^^^^^^^^^^^^ try: "until dec 31 starting YYYY-MM-DD"
```

Error kinds:
- `ErrorKindLex` - Lexer error (invalid characters, unknown words, malformed times and numbers)
- `ErrorKindParse` - Parser error (invalid syntax or values)
- `ErrorKindEval` - `NewSchedule` error (parts that break a rule); evaluating a schedule never fails
- `ErrorKindCron` - Cron conversion error

A lex or parse error carries the exact message the [spec](../spec/README.md#error-message-format) gives, the `Input`, a `Span` and, for some parse errors, a `Suggestion`. `Span` is `[Start, End)` counted in Unicode code points, not bytes: each invalid UTF-8 byte counts as one. `string([]rune(input)[span.Start:span.End])` is the spanned text, with any invalid byte as U+FFFD.

Cron conversion is exact or fails with an `ErrorKindCron` error that says why. This ignores the timezone and DST transitions, where cron schedulers differ. Yearly schedules, ordinal weekdays and partial-day intervals convert; `except`, `until`, `starting`, ISO dates, repeats every `n > 1` days, weeks, months or years, directional nearest weekdays, a `during` that excludes a yearly or named date's month, and times that are not every combination of their minutes and hours do not. From cron, `*/7 * * * *` (216 unevenly spaced times a day, too many to list) and crons that restrict both the day of month and the day of week fail. The [spec](../spec/README.md#cron-conversion) has every rule and message.

## Expression Syntax

See the [main README](../README.md) for full expression syntax documentation.

### Quick Examples

```go
// Daily
hron.ParseSchedule("every day at 09:00")
hron.ParseSchedule("every weekday at 9:00")
hron.ParseSchedule("every weekend at 10:00")
hron.ParseSchedule("every monday at 9:00")

// Intervals
hron.ParseSchedule("every 30 min from 09:00 to 17:00")
hron.ParseSchedule("every 2 hours from 00:00 to 23:59")

// Weekly
hron.ParseSchedule("every 2 weeks on monday at 9:00")

// Monthly
hron.ParseSchedule("every month on the 1st at 9:00")
hron.ParseSchedule("every month on the last day at 17:00")
hron.ParseSchedule("every month on the first monday at 10:00")

// Yearly
hron.ParseSchedule("every year on dec 25 at 00:00")
hron.ParseSchedule("every year on the first monday of march at 10:00")

// One-off dates
hron.ParseSchedule("on feb 14 at 9:00")
hron.ParseSchedule("on 2026-03-15 at 14:30")

// Modifiers
hron.ParseSchedule("every weekday at 9:00 except dec 25, jan 1")
hron.ParseSchedule("every day at 09:00 until 2026-12-31")
hron.ParseSchedule("every 2 weeks on monday at 9:00 starting 2026-01-05")
hron.ParseSchedule("every weekday at 9:00 in America/New_York")
hron.ParseSchedule("every day at 9:00 during jan, jun")
```

## Timezone & DST Handling

When a schedule specifies a timezone via the `in` clause, all occurrences are computed in that timezone with full DST awareness:

- **Spring-forward (gap):** A fixed time that does not exist is pushed forward by the gap length; interval slots in the gap are skipped
- **Fall-back (ambiguity):** First occurrence is used

Timezone names match in any case when Go can list a zone database (`$ZONEINFO`, the system zoneinfo directory, or GOROOT's `lib/time/zoneinfo.zip`); with only the embedded `time/tzdata`, names must use the exact IANA capitalization.

```go
// This schedule will handle DST transitions correctly
schedule, _ := hron.ParseSchedule("every day at 02:30 in America/New_York")
```

## Testing

```sh
cd go && go test -v ./...
```

## License

MIT
