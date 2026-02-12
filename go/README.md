# hron Go Package

Go implementation of hron (human-readable cron).

## Installation

```sh
go get github.com/prasrvenkat/hron/go
```

## Usage

```go
package main

import (
    "fmt"
    "time"

    "github.com/prasrvenkat/hron/go"
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
- `FromCronExpr(cronExpr string) (*Schedule, error)` - Convert a 5-field cron expression to a Schedule
- `Validate(input string) bool` - Check if an input string is a valid hron expression

### Schedule Methods

- `NextFrom(now time.Time) *time.Time` - Compute the next occurrence after now
- `NextNFrom(now time.Time, n int) []time.Time` - Compute the next n occurrences after now
- `Matches(dt time.Time) bool` - Check if a datetime matches this schedule
- `ToCron() (string, error)` - Convert this schedule to a 5-field cron expression
- `String() string` - Render as canonical string (roundtrip-safe)
- `Timezone() string` - Get the IANA timezone name, or empty string if not specified

### Error Handling

```go
schedule, err := hron.ParseSchedule("invalid expression")
if err != nil {
    if hronErr, ok := err.(*hron.HronError); ok {
        fmt.Println("Error kind:", hronErr.Kind)
        fmt.Println("Rich error:", hronErr.DisplayRich())
    }
}
```

Error kinds:
- `ErrorKindLex` - Lexer error (invalid characters)
- `ErrorKindParse` - Parser error (invalid syntax)
- `ErrorKindEval` - Evaluation error
- `ErrorKindCron` - Cron conversion error

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
hron.ParseSchedule("first monday of every month at 10:00")

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

- **Spring-forward (gap):** Non-existent times are pushed forward
- **Fall-back (ambiguity):** First occurrence is used

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
