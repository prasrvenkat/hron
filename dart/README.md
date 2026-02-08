# hron (Dart)

Native Dart implementation of [hron](https://github.com/prasrvenkat/hron) — human-readable cron expressions for Flutter and Dart.

## Install

```sh
dart pub add hron
```

## Usage

```dart
import 'package:hron/hron.dart';
import 'package:timezone/data/latest.dart' as tz;

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

  // Convert to cron (expressible subset only)
  final cron = Schedule.parse('every day at 9:00').toCron();

  // Convert from cron
  final fromCron = Schedule.fromCron('0 9 * * *');

  // Canonical string (roundtrip-safe)
  print(schedule.toString());
}
```

## Timezone Support

This package depends on the [`timezone`](https://pub.dev/packages/timezone) package for IANA timezone support. You must call `initializeTimeZones()` before using hron:

```dart
import 'package:timezone/data/latest.dart' as tz;
tz.initializeTimeZones();
```

## Tests

```sh
dart test
```

Conformance tests driven by `spec/tests.json`.

## License

MIT
