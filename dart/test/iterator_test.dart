// Iterator-specific tests for `occurrences()` and `between()` methods.
//
// These tests verify Dart-specific iterable behavior beyond conformance tests:
// - Laziness (iterables don't evaluate eagerly)
// - Early termination
// - Integration with Iterable methods (take, where, map, etc.)
// - For-in loop patterns
import 'package:hron/hron.dart';
import 'package:test/test.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

void main() {
  tz.initializeTimeZones();

  tz.TZDateTime parseZoned(String s) {
    // Parse '2026-02-06T12:00:00+00:00[UTC]' format
    final bracketIdx = s.indexOf('[');
    String tzName;
    String isoStr;

    if (bracketIdx >= 0) {
      tzName = s.substring(bracketIdx + 1, s.length - 1);
      isoStr = s.substring(0, bracketIdx);
    } else {
      tzName = 'UTC';
      isoStr = s;
    }

    final loc = tzName == 'UTC' ? tz.UTC : tz.getLocation(tzName);
    final dt = DateTime.parse(isoStr);
    return tz.TZDateTime.fromMillisecondsSinceEpoch(
      loc,
      dt.millisecondsSinceEpoch,
    );
  }

  // ===========================================================================
  // Laziness Tests
  // ===========================================================================

  group('laziness', () {
    test('occurrences is lazy - does not evaluate unbounded schedule', () {
      // An unbounded schedule should not hang or OOM when creating the iterator
      final schedule = Schedule.parse('every day at 09:00 in UTC');
      final from = parseZoned('2026-02-01T00:00:00+00:00[UTC]');

      // Creating the iterable should be instant (lazy)
      final iter = schedule.occurrences(from);

      // Taking just 1 should work without evaluating the rest
      final results = iter.take(1).toList();
      expect(results.length, equals(1));
    });

    test('between is lazy - does not evaluate entire range at once', () {
      final schedule = Schedule.parse('every day at 09:00 in UTC');
      final from = parseZoned('2026-02-01T00:00:00+00:00[UTC]');
      final to = parseZoned('2026-12-31T23:59:00+00:00[UTC]');

      // Creating the iterable should be instant
      final iter = schedule.between(from, to);

      // Taking just 3 should not evaluate all ~330 days
      final results = iter.take(3).toList();
      expect(results.length, equals(3));
    });
  });

  // ===========================================================================
  // Early Termination Tests
  // ===========================================================================

  group('early termination', () {
    test('occurrences early termination with take', () {
      final schedule = Schedule.parse('every day at 09:00 in UTC');
      final from = parseZoned('2026-02-01T00:00:00+00:00[UTC]');

      final results = schedule.occurrences(from).take(5).toList();

      expect(results.length, equals(5));
    });

    test('occurrences early termination with takeWhile', () {
      final schedule = Schedule.parse('every day at 09:00 in UTC');
      final from = parseZoned('2026-02-01T00:00:00+00:00[UTC]');
      final cutoff = parseZoned('2026-02-05T00:00:00+00:00[UTC]');

      final results = schedule
          .occurrences(from)
          .takeWhile((dt) => dt.isBefore(cutoff))
          .toList();

      // Feb 1, 2, 3, 4 at 09:00 (4 occurrences before Feb 5 00:00)
      expect(results.length, equals(4));
    });

    test('occurrences early termination with break', () {
      final schedule = Schedule.parse('every day at 09:00 in UTC');
      final from = parseZoned('2026-02-01T00:00:00+00:00[UTC]');

      final results = <tz.TZDateTime>[];
      for (final dt in schedule.occurrences(from)) {
        results.add(dt);
        if (results.length >= 5) break;
      }

      expect(results.length, equals(5));
    });

    test('occurrences find with firstWhere', () {
      final schedule = Schedule.parse('every day at 09:00 in UTC');
      final from = parseZoned('2026-02-01T00:00:00+00:00[UTC]');

      // Find the first Saturday occurrence (weekday 6 in Dart)
      final saturday = schedule
          .occurrences(from)
          .firstWhere((dt) => dt.weekday == 6);

      // Feb 7, 2026 is a Saturday
      expect(saturday.day, equals(7));
    });
  });

  // ===========================================================================
  // Iterable Methods Tests
  // ===========================================================================

  group('iterable methods', () {
    test('works with where (filter)', () {
      final schedule = Schedule.parse('every day at 09:00 in UTC');
      final from = parseZoned('2026-02-01T00:00:00+00:00[UTC]');

      // Filter to only weekends from first 14 days
      final weekends = schedule
          .occurrences(from)
          .take(14)
          .where((dt) => dt.weekday == 6 || dt.weekday == 7)
          .toList();

      // 2 weekends in 2 weeks = 4 days
      expect(weekends.length, equals(4));
    });

    test('works with map', () {
      final schedule = Schedule.parse('every day at 09:00 in UTC');
      final from = parseZoned('2026-02-01T00:00:00+00:00[UTC]');

      // Map to just the day number
      final days = schedule
          .occurrences(from)
          .take(5)
          .map((dt) => dt.day)
          .toList();

      expect(days, equals([1, 2, 3, 4, 5]));
    });

    test('works with skip', () {
      final schedule = Schedule.parse('every day at 09:00 in UTC');
      final from = parseZoned('2026-02-01T00:00:00+00:00[UTC]');

      // Skip first 5, take next 3
      final results = schedule.occurrences(from).skip(5).take(3).toList();

      expect(results.length, equals(3));
      // Should be Feb 6, 7, 8
      expect(results[0].day, equals(6));
      expect(results[1].day, equals(7));
      expect(results[2].day, equals(8));
    });

    test('between works with length', () {
      final schedule = Schedule.parse('every day at 09:00 in UTC');
      final from = parseZoned('2026-02-01T00:00:00+00:00[UTC]');
      final to = parseZoned('2026-02-10T23:59:00+00:00[UTC]');

      // Count occurrences in range
      final count = schedule.between(from, to).length;

      // Feb 1-10 inclusive = 10 days
      expect(count, equals(10));
    });

    test('between works with last', () {
      final schedule = Schedule.parse('every day at 09:00 in UTC');
      final from = parseZoned('2026-02-01T00:00:00+00:00[UTC]');
      final to = parseZoned('2026-02-10T23:59:00+00:00[UTC]');

      final last = schedule.between(from, to).last;

      expect(last.day, equals(10));
    });

    test('works with indexed access via elementAt', () {
      final schedule = Schedule.parse(
        'every day at 09:00 until 2026-02-10 in UTC',
      );
      final from = parseZoned('2026-02-01T00:00:00+00:00[UTC]');

      final iter = schedule.occurrences(from);

      expect(iter.elementAt(0).day, equals(1));
      expect(iter.elementAt(4).day, equals(5));
    });
  });

  // ===========================================================================
  // Collect Patterns
  // ===========================================================================

  group('collect patterns', () {
    test('occurrences collect to list', () {
      final schedule = Schedule.parse(
        'every day at 09:00 until 2026-02-05 in UTC',
      );
      final from = parseZoned('2026-02-01T00:00:00+00:00[UTC]');

      final results = schedule.occurrences(from).toList();

      expect(results.length, equals(5)); // Feb 1-5
    });

    test('between collect to list', () {
      final schedule = Schedule.parse('every day at 09:00 in UTC');
      final from = parseZoned('2026-02-01T00:00:00+00:00[UTC]');
      final to = parseZoned('2026-02-07T23:59:00+00:00[UTC]');

      final results = schedule.between(from, to).toList();

      expect(results.length, equals(7));
    });
  });

  // ===========================================================================
  // For-in Patterns
  // ===========================================================================

  group('for-in patterns', () {
    test('occurrences for-in with break', () {
      final schedule = Schedule.parse('every day at 09:00 in UTC');
      final from = parseZoned('2026-02-01T00:00:00+00:00[UTC]');

      var count = 0;
      for (final dt in schedule.occurrences(from)) {
        count++;
        if (dt.day >= 5) break;
      }

      expect(count, equals(5));
    });

    test('between for-in loop', () {
      final schedule = Schedule.parse('every day at 09:00 in UTC');
      final from = parseZoned('2026-02-01T00:00:00+00:00[UTC]');
      final to = parseZoned('2026-02-03T23:59:00+00:00[UTC]');

      final days = <int>[];
      for (final dt in schedule.between(from, to)) {
        days.add(dt.day);
      }

      expect(days, equals([1, 2, 3]));
    });
  });

  // ===========================================================================
  // Edge Cases
  // ===========================================================================

  group('edge cases', () {
    test('occurrences empty when past until', () {
      final schedule = Schedule.parse(
        'every day at 09:00 until 2026-01-01 in UTC',
      );
      final from = parseZoned('2026-02-01T00:00:00+00:00[UTC]');

      final results = schedule.occurrences(from).take(10).toList();

      expect(results.length, equals(0));
    });

    test('between empty range', () {
      final schedule = Schedule.parse('every day at 09:00 in UTC');
      final from = parseZoned('2026-02-01T12:00:00+00:00[UTC]');
      final to = parseZoned('2026-02-01T13:00:00+00:00[UTC]');

      final results = schedule.between(from, to).toList();

      expect(results.length, equals(0));
    });

    test('occurrences single date terminates', () {
      final schedule = Schedule.parse('on 2026-02-14 at 14:00 in UTC');
      final from = parseZoned('2026-02-01T00:00:00+00:00[UTC]');

      // Request many but should only get 1
      final results = schedule.occurrences(from).take(100).toList();

      expect(results.length, equals(1));
    });
  });

  // ===========================================================================
  // Timezone Handling
  // ===========================================================================

  group('timezone handling', () {
    test('occurrences preserves timezone', () {
      final schedule = Schedule.parse('every day at 09:00 in America/New_York');
      final from = parseZoned('2026-02-01T00:00:00-05:00[America/New_York]');

      final results = schedule.occurrences(from).take(3).toList();

      for (final dt in results) {
        expect(dt.location.name, equals('America/New_York'));
      }
    });

    test('between handles DST transition', () {
      // March 8, 2026 is DST spring forward in America/New_York
      // 2:00 AM springs forward to 3:00 AM, so 02:30 shifts to 03:30
      final schedule = Schedule.parse('every day at 02:30 in America/New_York');
      final from = parseZoned('2026-03-07T00:00:00-05:00[America/New_York]');
      final to = parseZoned('2026-03-10T00:00:00-04:00[America/New_York]');

      final results = schedule.between(from, to).toList();

      // Mar 7 at 02:30, Mar 8 at 03:30 (shifted), Mar 9 at 02:30
      expect(results.length, equals(3));
      expect(results[0].hour, equals(2)); // Mar 7 02:30
      expect(results[1].hour, equals(3)); // Mar 8 03:30 (shifted due to DST)
      expect(results[2].hour, equals(2)); // Mar 9 02:30
    });
  });

  // ===========================================================================
  // Multiple Times Per Day
  // ===========================================================================

  group('multiple times per day', () {
    test('occurrences multiple times per day', () {
      final schedule = Schedule.parse(
        'every day at 09:00, 12:00, 17:00 in UTC',
      );
      final from = parseZoned('2026-02-01T00:00:00+00:00[UTC]');

      final results = schedule
          .occurrences(from)
          .take(9)
          .toList(); // 3 days worth

      expect(results.length, equals(9));
      // First day: 09:00, 12:00, 17:00
      expect(results[0].hour, equals(9));
      expect(results[1].hour, equals(12));
      expect(results[2].hour, equals(17));
    });
  });

  // ===========================================================================
  // Complex Iterator Chains
  // ===========================================================================

  group('complex chains', () {
    test('complex chain', () {
      final schedule = Schedule.parse('every day at 09:00 in UTC');
      final from = parseZoned('2026-02-01T00:00:00+00:00[UTC]');

      // Complex chain: skip weekends, take first 5 weekdays, get their day numbers
      final weekdayDays = schedule
          .occurrences(from)
          .take(14) // Two weeks to ensure we have enough
          .where((dt) => dt.weekday >= 1 && dt.weekday <= 5) // Monday-Friday
          .take(5)
          .map((dt) => dt.day)
          .toList();

      // Feb 2026: 2,3,4,5,6 are Mon-Fri
      expect(weekdayDays, equals([2, 3, 4, 5, 6]));
    });
  });

  // ===========================================================================
  // Iterator Type Checks
  // ===========================================================================

  group('type checks', () {
    test('occurrences returns Iterable', () {
      final schedule = Schedule.parse('every day at 09:00 in UTC');
      final from = parseZoned('2026-02-01T00:00:00+00:00[UTC]');

      final iter = schedule.occurrences(from);

      expect(iter, isA<Iterable<tz.TZDateTime>>());
    });

    test('between returns Iterable', () {
      final schedule = Schedule.parse('every day at 09:00 in UTC');
      final from = parseZoned('2026-02-01T00:00:00+00:00[UTC]');
      final to = parseZoned('2026-02-05T00:00:00+00:00[UTC]');

      final iter = schedule.between(from, to);

      expect(iter, isA<Iterable<tz.TZDateTime>>());
    });

    test('can get iterator from iterable', () {
      final schedule = Schedule.parse('every day at 09:00 in UTC');
      final from = parseZoned('2026-02-01T00:00:00+00:00[UTC]');

      final iterable = schedule.occurrences(from);
      final iterator = iterable.iterator;

      expect(iterator.moveNext(), isTrue);
      expect(iterator.current.day, equals(1));
    });
  });
}
