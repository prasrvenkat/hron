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

`Schedule.Parse` and `Schedule.FromCron` are the only ways to make a `Schedule`, and a schedule never
changes once made.

## API

### `Schedule.Parse(string input)`: `Schedule`
Parses an hron expression. Throws a `HronException` whose `Kind` is `ErrorKind.Lex` or
`ErrorKind.Parse` on an invalid expression (see [Error Handling](#error-handling)), and an
`ArgumentNullException` for null.

### `Schedule.FromCron(string cronExpr)`: `Schedule`
Converts a 5-field cron expression to a schedule that fires at the same times (see
[Cron Conversion](#cron-conversion)). Throws a `HronException` whose `Kind` is `ErrorKind.Cron` when
the input is not valid cron or has no exact hron equivalent, and an `ArgumentNullException` for null.

### `Schedule.Validate(string input)`: `bool`
`false` for anything `Parse` rejects, unknown timezones included. Throws an `ArgumentNullException`
for null rather than returning `false`.

### `schedule.NextFrom(DateTimeOffset now)`: `DateTimeOffset?`
The next occurrence strictly after `now`, or null if there is none.

### `schedule.NextNFrom(DateTimeOffset now, int n)`: `IReadOnlyList<DateTimeOffset>`
Up to `n` occurrences strictly after `now`: fewer if the schedule ends, none if `n <= 0`.

### `schedule.PreviousFrom(DateTimeOffset now)`: `DateTimeOffset?`
The most recent occurrence strictly before `now`, or null if there is none, such as before a
`starting` date.

### `schedule.Matches(DateTimeOffset dateTime)`: `bool`
True when the minute containing `dateTime`, on the schedule's wall clock, is an occurrence.

### `schedule.Occurrences(DateTimeOffset from)`: `IEnumerable<DateTimeOffset>`
Lazily yields the occurrences strictly after `from`, unbounded unless an `until` ends the schedule.

### `schedule.Between(DateTimeOffset from, DateTimeOffset to)`: `IEnumerable<DateTimeOffset>`
Lazily yields the occurrences where `from < occurrence <= to`.

### `schedule.ToCron()`: `string`
A 5-field cron expression that fires at the same times. Throws a `HronException` whose `Kind` is
`ErrorKind.Cron` when there is none (see [Cron Conversion](#cron-conversion)).

### `schedule.ToString()`: `string`
The canonical expression, which parses back to an equal schedule.

```csharp
var schedule = Schedule.Parse("every weekday at 09:00 in America/New_York");
var now = new DateTimeOffset(2026, 2, 6, 12, 0, 0, TimeSpan.Zero); // a Friday, 07:00 in New York

Console.WriteLine(schedule.PreviousFrom(now)?.ToString("o")); // 2026-02-05T09:00:00.0000000-05:00
foreach (var occurrence in schedule.Occurrences(now).Take(2))
{
    Console.WriteLine(occurrence.ToString("o")); // 2026-02-06T09:00:00.0000000-05:00, then 2026-02-09T09:00:00.0000000-05:00
}
Console.WriteLine(schedule.Between(now, now.AddDays(7)).Count()); // 5
```

### Getters

Read-only properties, one per part. Every part is an immutable record or enum from `Hron.Ast`, and
every list an `IReadOnlyList<T>` that no cast can change, so nothing a getter returns can change the
schedule. Constructing a part makes a value no method takes:
`Parse` and `FromCron` remain the only ways to make a schedule.

| Property | Type | |
|---|---|---|
| `schedule.Expression` | `IScheduleExpr` | The repeat: a `DayRepeat`, `IntervalRepeat`, `WeekRepeat`, `MonthRepeat`, `YearRepeat` or `SingleDate`. |
| `schedule.Timezone` | `string?` | The IANA timezone name with its canonical capitalization; null without an `in` clause. |
| `schedule.Except` | `IReadOnlyList<ExceptionSpec>` | The except dates; empty without an except clause. |
| `schedule.Until` | `UntilSpec?` | The until date; null without an until clause. |
| `schedule.Starting` | `string?` | The starting date as `YYYY-MM-DD`; null without a starting clause. |
| `schedule.During` | `IReadOnlyList<MonthName>` | The during months; empty without a during clause. |

```csharp
using Hron.Ast;

var schedule = Schedule.Parse(
    "every weekday at 9:00 except dec 25 starting 2026-01-05 during jan, dec in america/new_york");

if (schedule.Expression is DayRepeat { Days.Kind: DayFilterKind.Weekday } repeat)
{
    Console.WriteLine(string.Join(", ", repeat.Times)); // 09:00
}
Console.WriteLine(schedule.Except[0]);                // ExceptionSpec { Kind = Named, Month = December, Day = 25, Date =  }
Console.WriteLine(schedule.Until is null);            // True
Console.WriteLine(schedule.Starting);                 // 2026-01-05
Console.WriteLine(string.Join(", ", schedule.During)); // January, December
Console.WriteLine(schedule.Timezone);                 // America/New_York
```

### Equality

`schedule.Equals(other)`, `==` and `!=` compare parts: two schedules are equal when every getter is,
however they were made. `every day at 9:00` equals `every day at 09:00`, and a schedule from
`FromCron` equals the parse of its `ToString()`. Lists compare in order, duplicates included, as
`ToString()` writes them. Equal schedules have equal `GetHashCode()`s, so a schedule works as a
dictionary key. Comparing with null or anything that is not a `Schedule` is `false`, never an
exception.

```csharp
Console.WriteLine(Schedule.Parse("every day at 9:00") == Schedule.Parse("every day at 09:00"));              // True
Console.WriteLine(Schedule.FromCron("0 9 * * 1-5").Equals(Schedule.Parse("every weekday at 09:00")));         // True
Console.WriteLine(Schedule.Parse("every day at 09:00, 17:00") == Schedule.Parse("every day at 17:00, 09:00")); // False
Console.WriteLine(Schedule.Parse("every day at 09:00").Equals(null));                                         // False
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

## Timestamps

Every method takes a `DateTimeOffset`, and only its instant matters: the offset it is written in
changes nothing. Every result has the offset of the schedule's timezone at that instant, or
`+00:00` when the schedule has none. `DateTimeOffset` has no zone name; `schedule.Timezone` gives it.

```csharp
var schedule = Schedule.Parse("every day at 09:00 in America/New_York");
var tokyo = new DateTimeOffset(2026, 2, 6, 21, 0, 0, TimeSpan.FromHours(9));
Console.WriteLine(schedule.NextFrom(tokyo)?.ToString("o")); // 2026-02-06T09:00:00.0000000-05:00
```

A `DateTime` converts to `DateTimeOffset` implicitly, as the host's local time unless its `Kind` is
`Utc`. Pass a `DateTimeOffset`, or a `DateTime` whose `Kind` is `Utc`, when the host's timezone
should not matter.

`NextNFrom(now, n)` returns at most `n` occurrences, and none when `n <= 0`. `n` only caps the
list, so `int.MaxValue` returns at once, with every occurrence through the end of the supported
range.

The supported range is `0001-01-02T00:00:00Z` up to but not including `9999-12-30T00:00:00Z`. An
argument outside it, `DateTimeOffset.MinValue` and `MaxValue` included, is not an error: `NextFrom`
and `PreviousFrom` return null, `Matches` returns false, and `NextNFrom`, `Occurrences` and
`Between` return nothing.

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
date's month; and times that are not every combination of their minutes and hours
(`at 09:00, 17:30`). The schedule's timezone is not part of the cron: run the cron in the
schedule's timezone.

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

### `HronException`

`HronException` extends `Exception`.

| Member | |
|---|---|
| `Kind` | An `ErrorKind`: `Lex`, `Parse`, `Eval` or `Cron`. `ToValue()` gives `"lex"`, `"parse"`, `"eval"` or `"cron"`. This package never throws `Eval`, which is for schedules built in code. |
| `Message` | The message alone. |
| `Span` | A `Span?`, `Start` and `End` in code points, for lex and parse errors, else null. |
| `Input` | The expression as given for lex and parse errors, else null. |
| `Suggestion` | Text to put in place of the span, when a parse error has one, else null. |
| `DisplayRich()` | The message, then for lex and parse errors the input with carets under the span and any suggestion. |
| `HronException.Lex(message, span, input)`, `HronException.Parse(message, span, input, suggestion)`, `HronException.Eval(message)`, `HronException.Cron(message)` | Build an error of each kind. A null message or input throws an `ArgumentNullException`; a null suggestion is allowed. |

### Usage errors

`Parse`, `Validate` and `FromCron` throw an `ArgumentNullException` for a null input, never a
`HronException` or `false`.

```csharp
try
{
    Schedule.Validate(null!);
}
catch (ArgumentNullException ex)
{
    Console.WriteLine(ex.ParamName); // input
}
```

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
