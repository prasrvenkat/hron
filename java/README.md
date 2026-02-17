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
```

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
    Schedule.parse("invalid expression");
} catch (HronException e) {
    System.out.println("Error kind: " + e.kind()); // PARSE
    System.out.println("Message: " + e.getMessage());
    System.out.println(e.displayRich()); // Rich formatted error with underline
}
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
| `matches(ZonedDateTime datetime)` | Check if `datetime` matches this schedule |
| `toCron()` | Convert to a 5-field cron expression |
| `toString()` | Get the canonical string form |
| `timezone()` | Get the IANA timezone name (if specified) |

### HronException

Exception thrown for parsing, evaluation, and conversion errors.

#### Factory Methods

| Method | Description |
|--------|-------------|
| `lex(message, span, input)` | Create a lexer error |
| `parse(message, span, input, suggestion)` | Create a parser error |
| `eval(message)` | Create an evaluation error |
| `cron(message)` | Create a cron conversion error |

#### Instance Methods

| Method | Description |
|--------|-------------|
| `kind()` | Get the error kind (LEX, PARSE, EVAL, CRON) |
| `span()` | Get the error location (Optional) |
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
