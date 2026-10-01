# Hron - Human-Readable Cron for .NET

A .NET library for parsing and evaluating human-readable scheduling expressions.

## Installation

```bash
dotnet add package Hron
```

## Usage

```csharp
using Hron;

// Parse a schedule expression
var schedule = Schedule.Parse("every weekday at 9:00 in America/New_York");

// Get the next occurrence
var next = schedule.NextFrom(DateTimeOffset.Now);
if (next.HasValue)
{
    Console.WriteLine($"Next: {next.Value}");
}

// Get multiple occurrences
var nextFive = schedule.NextNFrom(DateTimeOffset.Now, 5);
foreach (var occurrence in nextFive)
{
    Console.WriteLine(occurrence);
}

// Check if a time matches
var isMatch = schedule.Matches(new DateTimeOffset(2026, 2, 10, 9, 0, 0, TimeSpan.FromHours(-5)));

// Convert to cron; throws a HronException when no cron fires at exactly the same times
var cron = schedule.ToCron();

// Get canonical string representation
var canonical = schedule.ToString();

// Access timezone
var timezone = schedule.Timezone; // "America/New_York" or null
```

## Expression Syntax

```
every day at 09:00
every weekday at 9:00, 17:00
every monday, wednesday, friday at 10:00
every 2 weeks on monday at 09:00
every month on the 1st at 09:00
every month on the last weekday at 17:00
every month on the first monday at 09:00
every year on dec 25 at 00:00
every 30 min from 09:00 to 17:00
on feb 14 at 09:00
```

### Modifiers

```
every day at 09:00 except dec 25
every day at 09:00 until 2026-12-31
every 3 days at 09:00 starting 2026-01-01
every day at 09:00 during jan, feb, mar
every day at 09:00 in America/New_York
```

### Timezones

A timezone is `UTC` or an IANA `Area/Location` name such as `America/New_York`; abbreviations
(`EST`), offsets (`+05:30`) and unknown names are parse errors. Where the platform has a zoneinfo
directory (Linux, macOS), names match in any case and display with the IANA capitalization, so
`in america/new_york` becomes `in America/New_York`. On Windows, a name must use its exact IANA
capitalization. Which names are accepted follows the platform's tz data.

`DateTimeOffset` and `TimeZoneInfo` keep offsets in whole minutes, so where a zone's offset had
seconds (local mean time before standard time was adopted, into the 1950s in some zones) an occurrence can be
up to a minute off, or skipped when the rounding moves it past `now`. The spec leaves such offsets
out of scope.

## Cron Conversion

Conversion is exact in both directions: the result fires at the same times on the same dates, or
the method throws a `HronException` of kind `ErrorKind.Cron` whose message says why. This ignores
the timezone and DST transitions, where cron schedulers differ.

```csharp
// From hron to cron
var schedule = Schedule.Parse("every day at 09:00");
var cron = schedule.ToCron(); // "0 9 * * *"
Schedule.Parse("every year on dec 25 at 00:00").ToCron(); // "0 0 25 12 *"
Schedule.Parse("every 15 min from 09:00 to 17:45 on weekday").ToCron(); // "*/15 9-17 * * 1-5"

// From cron to hron
var schedule2 = Schedule.FromCron("0 9 * * 1-5");
Console.WriteLine(schedule2); // "every weekday at 09:00"
Console.WriteLine(Schedule.FromCron("0 16 * * 5L")); // "every month on the last friday at 16:00"
```

`ToCron()` throws for `except`, `until` and `starting`; ISO dates; repeats every `n > 1` days,
weeks, months or years; a directional nearest weekday; a `during` that excludes a yearly or named
date's month; a schedule built in code with no days or no times; and times that are not every
combination of their minutes and hours (`at 09:00, 17:30`). The schedule's timezone is not part of
the cron: run the cron in the schedule's timezone.

`FromCron()` throws for crons that restrict both the day of month and the day of week
(`0 9 15 * 1`), and for more than 24 times a day, unless they are evenly spaced on days an
interval can carry (`*/7 * * * *` fires 216 times at uneven gaps). The [spec](https://github.com/simpllyf/hron/blob/main/spec/README.md#cron-conversion)
has the full rules and every error message.

## Error Handling

`Schedule.Parse` throws a `HronException` of kind `ErrorKind.Lex` or `ErrorKind.Parse` with the
exact message of the spec, the `Input`, and a `Span` that counts Unicode code points, not UTF-16
`char`s. A parse error may carry a `Suggestion`. `DisplayRich()` renders the error with carets
under the span:

```csharp
try
{
    Schedule.Parse("every weekday at 09:00 until dec 31");
}
catch (HronException ex)
{
    Console.WriteLine(ex.Kind);          // Parse
    Console.WriteLine(ex.Message);       // until dec 31 has no year: add a starting date, or use an ISO date
    Console.WriteLine(ex.Span);          // Span { Start = 23, End = 35, Length = 12 }
    Console.WriteLine(ex.Suggestion);    // until dec 31 starting YYYY-MM-DD
    Console.WriteLine(ex.DisplayRich());
}
```

```text
error: until dec 31 has no year: add a starting date, or use an ISO date
  every weekday at 09:00 until dec 31
                         ^^^^^^^^^^^^ try: "until dec 31 starting YYYY-MM-DD"
```

A surrogate pair is one code point, and so is a lone surrogate. To turn a span into a `char` index,
walk the input and step over two `char`s wherever `char.IsSurrogatePair(input, i)` is true.
`StringInfo` counts graphemes and `EnumerateRunes` turns a lone surrogate into U+FFFD, so neither
gives the same count.

## Validation

```csharp
if (Schedule.Validate("every day at 09:00"))
{
    Console.WriteLine("Valid!");
}
```

## Requirements

- .NET 10.0 or later

## License

MIT
