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

// Convert to cron (if possible)
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

## Cron Conversion

```csharp
// From hron to cron
var schedule = Schedule.Parse("every day at 09:00");
var cron = schedule.ToCron(); // "0 9 * * *"

// From cron to hron
var schedule2 = Schedule.FromCron("0 9 * * 1-5");
Console.WriteLine(schedule2); // "every weekday at 09:00"
```

## Error Handling

```csharp
try
{
    var schedule = Schedule.Parse("invalid expression");
}
catch (HronException ex)
{
    Console.WriteLine(ex.Kind);        // ErrorKind.Parse
    Console.WriteLine(ex.Message);     // Error description
    Console.WriteLine(ex.Span);        // Location in input
    Console.WriteLine(ex.DisplayRich()); // Formatted error with underline
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
