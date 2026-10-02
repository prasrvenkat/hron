# hron Java

Native Java implementation of the hron scheduling expression language.

## Installation

### Maven

Add the dependency (see [Maven Central](https://central.sonatype.com/artifact/io.hron/hron) for the latest version):

```xml
<dependency>
    <groupId>io.hron</groupId>
    <artifactId>hron</artifactId>
</dependency>
```

### Gradle

```groovy
implementation 'io.hron:hron'
```

## Requirements

- Java 25 or later

## Usage

```java
import io.hron.Schedule;
import io.hron.HronException;

import java.time.ZonedDateTime;

public class Example {
    public static void main(String[] args) throws HronException {
        // Parse a schedule expression
        Schedule schedule = Schedule.parse("every weekday at 9:00 except dec 25 in America/New_York");

        // Get the next occurrence
        ZonedDateTime now = ZonedDateTime.now();
        schedule.nextFrom(now).ifPresent(next -> {
            System.out.println("Next occurrence: " + next);
        });

        // Get the next 5 occurrences
        schedule.nextNFrom(now, 5).forEach(System.out::println);

        // Check if a time matches the schedule
        boolean matches = schedule.matches(now);

        // Get the canonical string form
        System.out.println(schedule.toString());

        // Get the timezone
        schedule.timezone().ifPresent(tz -> {
            System.out.println("Timezone: " + tz);
        });
    }
}
```

### Cron Conversion

```java
import io.hron.Schedule;

// Convert hron to cron
Schedule s = Schedule.parse("every day at 9:00");
String cron = s.toCron(); // "0 9 * * *"

// Convert cron to hron
Schedule s2 = Schedule.fromCron("0 9 * * 1-5");
System.out.println(s2); // "every weekday at 09:00"

// Partial-day windows, ordinals and yearly dates convert too
Schedule.parse("every 15 min from 09:00 to 17:45 on weekday").toCron(); // "*/15 9-17 * * 1-5"
Schedule.parse("every month on the last friday at 16:00").toCron();     // "0 16 * * 5L"
Schedule.parse("every year on dec 25 at 00:00").toCron();               // "0 0 25 12 *"
```

Both directions are exact: the result fires at the same times on the same dates, or the call throws a `HronException` of kind `CRON` whose message says why. This ignores the timezone and DST transitions, where cron schedulers differ.

- `toCron()` fails for `except`, `until` and `starting`; an ISO date; a repeat every `n > 1` days, weeks, months or years; a directional nearest weekday; a `during` that excludes a yearly or named date's month; and times that are not every combination of their minutes and hours (`at 09:00, 17:30`).
- `fromCron()` fails for a cron that restricts both the day of month and the day of week (`0 9 15 * 1`), and for more than 24 times a day, unless they are evenly spaced on days an interval can carry (`*/7 * * * *` fires 216 times at uneven gaps).
- The timezone is not part of the cron: run the cron in the schedule's timezone.

The [spec](../spec/README.md#cron-conversion) has the full rules and every error message.

### Validation

```java
import io.hron.Schedule;

if (Schedule.validate("every day at 9:00")) {
    System.out.println("Valid!");
}
```

### Error Handling

```java
import io.hron.Schedule;
import io.hron.HronException;
import io.hron.ErrorKind;

try {
    Schedule.parse("every weekday at 09:00 until dec 31");
} catch (HronException e) {
    System.out.println("Error kind: " + e.kind()); // parse
    System.out.println("Message: " + e.getMessage());
    System.out.println(e.displayRich());
}
```

`Schedule.parse` throws a `HronException` of kind `LEX` or `PARSE` with the exact message of the [spec](../spec/README.md#error-message-format), the `input`, and a `span` that counts Unicode code points, not UTF-16 `char`s; a parse error may carry a `suggestion`. `displayRich()` renders the error with carets under the span:

```text
error: until dec 31 has no year: add a starting date, or use an ISO date
  every weekday at 09:00 until dec 31
                         ^^^^^^^^^^^^ try: "until dec 31 starting YYYY-MM-DD"
```

`span()` and `input()` are empty only for eval and cron errors. To slice the input with the span, convert each end to a `String` index:

```java
String input = e.input().orElseThrow();
Span span = e.span().orElseThrow();
String spanned =
    input.substring(input.offsetByCodePoints(0, span.start()), input.offsetByCodePoints(0, span.end()));
```

## API Reference

### Schedule (Main Entry Point)

#### Static Methods

| Method | Description |
|--------|-------------|
| `parse(String input)` | Parse an hron expression into a Schedule |
| `fromCron(String cronExpr)` | Convert a 5-field cron expression to a Schedule |
| `validate(String input)` | Check if an input is a valid hron expression |

#### Instance Methods

| Method | Description |
|--------|-------------|
| `nextFrom(ZonedDateTime now)` | Get the next occurrence after `now` |
| `nextNFrom(ZonedDateTime now, int n)` | Get the next `n` occurrences after `now` |
| `previousFrom(ZonedDateTime now)` | Get the most recent occurrence before `now` |
| `matches(ZonedDateTime datetime)` | Check if `datetime` matches this schedule |
| `occurrences(ZonedDateTime from)` | Get a lazy stream of occurrences after `from` |
| `between(ZonedDateTime from, ZonedDateTime to)` | Get a lazy stream of occurrences after `from` and up to `to` |
| `toCron()` | Convert to a 5-field cron expression |
| `toString()` | Get the canonical string form |
| `timezone()` | Get the IANA timezone name with its canonical capitalization (if specified) |
| `data()` | Get the schedule's parts as read-only records from `io.hron.ast` |

A schedule is built only by `parse` and `fromCron`, and cannot change afterwards. The records `data()` returns hold only unmodifiable lists, and nothing builds a schedule back from them. The module `io.hron` exports `io.hron` and `io.hron.ast`; `io.hron.internal` is not API.

#### Timestamps

Only the instant of a `ZonedDateTime` argument matters, not its zone, and every returned `ZonedDateTime` is in the schedule's timezone, or `ZoneId.of("UTC")` when it has none:

```java
Schedule s = Schedule.parse("every day at 09:00 in America/New_York");
ZonedDateTime tokyo = ZonedDateTime.parse("2026-02-06T21:00:00+09:00[Asia/Tokyo]");
s.nextFrom(tokyo); // Optional[2026-02-06T09:00-05:00[America/New_York]]
```

- A timestamp outside the [supported range](../spec/README.md#supported-range), `0001-01-02T00:00:00Z` up to `9999-12-30T00:00:00Z`, is not an error, even at `LocalDateTime.MIN` or `MAX` in any zone: `nextFrom` and `previousFrom` return empty, `matches` returns false, and `nextNFrom`, `occurrences` and `between` return nothing.
- `nextNFrom` returns at most `n` occurrences, and none when `n <= 0`. `n` only caps the count, so `Integer.MAX_VALUE` returns at once, with every occurrence through the end of the supported range.
- A `null` timestamp throws `NullPointerException`.

### HronException

Exception thrown for parsing and cron conversion errors.

#### Factory Methods

| Method | Description |
|--------|-------------|
| `lex(message, span, input)` | Create a lexer error |
| `parse(message, span, input, suggestion)` | Create a parser error |
| `eval(message)` | Create an eval error, the kind for a schedule built in code from parts that break a rule; Java never throws one |
| `cron(message)` | Create a cron conversion error |

#### Instance Methods

| Method | Description |
|--------|-------------|
| `kind()` | Get the error kind (LEX, PARSE, EVAL, CRON) |
| `span()` | Get the error location in code points (Optional) |
| `input()` | Get the original input (Optional) |
| `suggestion()` | Get a suggested fix (Optional) |
| `displayRich()` | Format a rich error message with underline |

## Features

- **Zero dependencies** - Only uses `java.time` from the standard library
- **Full conformance** - Passes the entire conformance test suite
- **DST-aware** - Handles timezone transitions correctly
- **Modern Java** - Uses sealed interfaces, records, and pattern matching

## Development

```bash
# Run tests
cd java && mvn test

# Build
cd java && mvn compile

# Package
cd java && mvn package
```

## License

MIT
