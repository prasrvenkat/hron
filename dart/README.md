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
