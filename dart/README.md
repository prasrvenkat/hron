# hron (Dart)

Native Dart implementation of [hron](https://github.com/simpllyf/hron) — human-readable cron expressions for Flutter and Dart.

## Install

```sh
dart pub add hron
```

## Usage

```dart
import 'package:hron/hron.dart';
import 'package:timezone/data/latest_all.dart' as tz;

void main() {
  // Required: initialize timezone database
  tz.initializeTimeZones();

  // Parse an expression
  final schedule = Schedule.parse('every weekday at 9:00 in America/New_York');

  // Compute next occurrence
  final now = TZDateTime.now(getLocation('America/New_York'));
  final next = schedule.nextFrom(now);

  // Compute next N occurrences
  final nextFive = schedule.nextNFrom(now, 5);

  // Check if a datetime matches
  final matches = schedule.matches(now);

  // Convert to cron: '0 9 * * *'
  final cron = Schedule.parse('every day at 9:00').toCron();

  // Convert from cron: 'every month on the last friday at 16:00'
  final fromCron = Schedule.fromCron('0 16 * * 5L');

  // Canonical string (roundtrip-safe)
  print(schedule.toString());
}
```

## API

A `Schedule` is built only by `Schedule.parse` or `Schedule.fromCron`, and cannot change afterwards.

| Member | Result |
| --- | --- |
| `Schedule.parse(String input)` | `Schedule`; throws `HronError` |
| `Schedule.fromCron(String cronExpr)` | `Schedule`; throws `HronError` |
| `Schedule.validate(String input)` | `bool`: `false` for anything `parse` rejects |
| `nextFrom(TZDateTime now)` | `TZDateTime?`: the next occurrence after `now` |
| `nextNFrom(TZDateTime now, int n)` | `List<TZDateTime>`: at most `n` occurrences after `now` |
| `previousFrom(TZDateTime now)` | `TZDateTime?`: the last occurrence before `now` |
| `matches(TZDateTime datetime)` | `bool` |
| `occurrences(TZDateTime from)` | lazy `Iterable<TZDateTime>` of occurrences after `from` |
| `between(TZDateTime from, TZDateTime to)` | lazy `Iterable<TZDateTime>` of occurrences in `from < t <= to` |
| `toCron()` | `String`; throws `HronError` |
| `toString()` | `String`: the canonical expression, which `parse` reads back to an equal schedule |
| `==`, `hashCode` | equal when the parts are equal |
| `timezone` | `String?`: the IANA name in its canonical capitalization |
| `expression` | `ScheduleExpr`: the repeat, without its clauses |
| `except` | `List<ExceptionSpec>`: empty without an `except` clause |
| `until` | `UntilSpec?` |
| `starting` | `String?`: a `YYYY-MM-DD` date |
| `during` | `List<MonthName>`: empty without a `during` clause |

The arguments are non-nullable, so the analyzer rejects a `null`. A `null` or a value of the wrong type passed through `dynamic` or `Function.apply` throws a `TypeError`, never a `HronError`, and `validate` throws it too rather than returning `false`.

### Parts

The getters return the parts of the schedule: `ScheduleExpr` (`IntervalRepeat`, `DayRepeat`, `WeekRepeat`, `MonthRepeat`, `SingleDate`, `YearRepeat`), the day filters, month and year targets, dates and names under them, `ExceptionSpec` and `UntilSpec`. Each family is a sealed class, so a `switch` over it is exhaustive. Their fields are final and their lists unmodifiable. `OrdinalPosition.toN` is 1 to 5 for `first` to `fifth` and -1 for `last`.

```dart
final schedule = Schedule.parse(
  'every weekday at 9:00 except dec 25 starting 2026-01-01 '
  'during jan, dec in america/new_york',
);
print(schedule.timezone); // America/New_York
print(schedule.starting); // 2026-01-01
print(schedule.until); // null
print(schedule.during); // [MonthName.jan, MonthName.dec]

if (schedule.expression case DayRepeat(
  days: WeekdayFilter(),
  :final times,
)) {
  print(times); // [09:00]
}

final description = switch (schedule.except.single) {
  NamedException(:final month, :final day) => '${month.name} $day',
  IsoException(:final date) => date,
};
print(description); // dec 25

schedule.during.add(MonthName.feb); // throws UnsupportedError
```

### Equality

Two schedules are equal when their parts are, with lists compared in order and duplicates counted. Equal schedules have equal hash codes, so a schedule can be a `Map` key or a `Set` element:

```dart
final nine = Schedule.parse('every day at 9:00');
print(nine == Schedule.parse('every day at 09:00')); // true
print(nine.hashCode == Schedule.parse('every day at 09:00').hashCode); // true
print(Schedule.fromCron('0 9 * * *') == nine); // true
print(
  Schedule.parse('every monday, friday at 09:00') ==
      Schedule.parse('every friday, monday at 09:00'),
); // false
print(nine == Object()); // false
```

## Timestamps

Every method takes and returns `TZDateTime`. An argument stands for its instant: the location it is in changes no result. Every result is in the schedule's timezone, or in a location named `UTC` when the expression has no `in` clause:

```dart
final tokyo = TZDateTime(getLocation('Asia/Tokyo'), 2026, 2, 6, 21);

final schedule = Schedule.parse('every day at 09:00 in America/New_York');
final next = schedule.nextFrom(tokyo)!;
print(next); // 2026-02-06 09:00:00.000-0500
print(next.location.name); // America/New_York

final utc = Schedule.parse('every day at 09:00').nextFrom(tokyo)!;
print(utc.location.name); // UTC
print(utc.isUtc); // false
print(utc.toUtc().isUtc); // true
```

That `UTC` location is hron's own: the `timezone` package names its `UTC` location `Etc/UTC`, and only that one makes `isUtc` true, so call `toUtc()` when you need it.

`nextNFrom(now, n)` returns no more than `n` occurrences, and none when `n <= 0`. A large `n` only caps the count, with no room reserved for it, so `nextNFrom(now, 2147483647)` returns every occurrence through the end of the supported range.

The supported range is `0001-01-02T00:00:00Z <= t < 9999-12-30T00:00:00Z`. A `now`, `from`, `to` or `datetime` outside it is not an error, even at the limits of `DateTime`: `nextFrom` and `previousFrom` return `null`, `matches` returns `false`, and `nextNFrom`, `occurrences` and `between` return nothing.

## Errors

Every error hron throws for an expression is a `HronError`, with these fields:

| Field | Type | Holds |
| --- | --- | --- |
| `kind` | `HronErrorKind` | `lex`, `parse`, `eval` or `cron` |
| `message` | `String` | what went wrong |
| `span` | `Span?` | the part of `input` it points at, for `lex` and `parse` |
| `input` | `String?` | the expression, for `lex` and `parse` |
| `suggestion` | `String?` | a fix, for some `parse` errors |

`displayRich()` formats it for a terminal, and the factories `HronError.lex`, `HronError.parse`, `HronError.eval` and `HronError.cron` build one of each kind.

`Schedule.parse` throws a `HronError` of kind `HronErrorKind.lex` or `HronErrorKind.parse`, with the exact message of the [spec](https://github.com/simpllyf/hron/blob/main/spec/README.md#error-message-format), the `input`, and a `span`. A parse error may carry a `suggestion`. `displayRich()` renders the error with carets under the span:

```text
error: until dec 31 has no year: add a starting date, or use an ISO date
  every weekday at 09:00 until dec 31
                         ^^^^^^^^^^^^ try: "until dec 31 starting YYYY-MM-DD"
```

A span counts code points (`input.runes`), not the UTF-16 code units that `String` indexes, so take the spanned text as `String.fromCharCodes(input.runes.skip(span.start).take(span.end - span.start))`.

One parse error message is not in the spec: `timezone '...' needs timezone data: call initializeTimeZones() from package:timezone/data/latest_all.dart before parsing`, thrown only when an `in` clause names an Area/Location zone and no timezone database has been loaded (see [Timezone Support](#timezone-support)).

A schedule is built only by `Schedule.parse` or `Schedule.fromCron` and cannot change afterwards, so evaluating it never throws. `HronErrorKind.eval` is for schedules that other hron languages build from their parts in code; this package never throws it.

## Cron Conversion

`toCron` and `Schedule.fromCron` convert exactly: the result fires at the same times on the same dates, or they throw a `HronError` of kind `HronErrorKind.cron` whose message says why. This ignores the timezone and DST transitions, where cron schedulers differ. Yearly dates, ordinal weekdays such as `5L` and `1#2`, and intervals over part of the day convert too: `every 15 min from 09:00 to 17:45` is `*/15 9-17 * * *`.

`toCron` throws for `except`, `until` and `starting`, ISO dates, repeats every `n` days, weeks, months or years with `n > 1`, directional nearest weekdays, a `during` that excludes a yearly or named date's month, and times that are not every combination of their minutes and hours (`at 09:00, 17:30`). A schedule's timezone is not part of the cron: run the cron in the schedule's timezone.

`Schedule.fromCron` throws for crons that restrict both the day of month and the day of week (`0 9 15 * 1`), and for more than 24 times a day, unless they are evenly spaced on days an interval can carry (`*/7 * * * *` fires 216 times at uneven gaps). The [spec](https://github.com/simpllyf/hron/blob/main/spec/README.md#cron-conversion) has the full rules and every error message.

## Timezone Support

This package depends on the [`timezone`](https://pub.dev/packages/timezone) package for IANA timezone support. Load its database before parsing an expression with an `in` clause, because `Schedule.parse` checks the name against the loaded database:

```dart
import 'package:timezone/data/latest_all.dart' as tz;
tz.initializeTimeZones();
```

Names match in any case and display with the IANA capitalization (`in america/new_york` displays `in America/New_York`). hron uses whichever database your app loads. `latest_all.dart` includes link names such as `US/Eastern` and `Europe/Amsterdam`; the smaller `latest.dart` does not, so with it those names are parse errors. The `timezone` data has no DST rules after 2037, so later dates keep the offset of each zone's last 2037 transition (standard time in `America/New_York`, daylight time in `Australia/Sydney`).

## Tests

```sh
dart test
```

Conformance tests driven by `spec/tests.json`. `test/cron_test.dart` checks cron conversion against an independent cron matcher.

## License

MIT
