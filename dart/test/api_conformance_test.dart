// API conformance test — verifies Dart exposes all methods from spec/api.json.
//
// Dart doesn't have runtime reflection, so we verify each method exists and
// returns the correct type by calling them directly.

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart';

import 'package:hron/hron.dart';

late Map<String, dynamic> apiSpec;

void main() {
  tz.initializeTimeZones();

  // Find spec/api.json relative to the dart/ directory
  var dir = Directory.current.path;
  if (p.basename(dir) == 'dart') {
    dir = p.dirname(dir);
  }
  final specPath = p.join(dir, 'spec', 'api.json');
  apiSpec = jsonDecode(File(specPath).readAsStringSync()) as Map<String, dynamic>;

  final scheduleMap = apiSpec['schedule'] as Map<String, dynamic>;

  group('API conformance', () {
    // Static methods
    group('static methods', () {
      test('parse', () {
        final schedule = Schedule.parse('every day at 09:00');
        expect(schedule, isA<Schedule>());
      });

      test('fromCron', () {
        final schedule = Schedule.fromCron('0 9 * * *');
        expect(schedule, isA<Schedule>());
      });

      test('validate', () {
        final valid = Schedule.validate('every day at 09:00');
        expect(valid, isTrue);
        final invalid = Schedule.validate('not a schedule');
        expect(invalid, isFalse);
      });
    });

    // Instance methods
    group('instance methods', () {
      final schedule = Schedule.parse('every day at 09:00');
      final now = TZDateTime(getLocation('UTC'), 2026, 2, 6, 12, 0, 0);

      test('nextFrom', () {
        final result = schedule.nextFrom(now);
        expect(result, isA<TZDateTime?>());
      });

      test('nextNFrom', () {
        final results = schedule.nextNFrom(now, 3);
        expect(results, isA<List<TZDateTime>>());
        expect(results.length, equals(3));
      });

      test('matches', () {
        final result = schedule.matches(now);
        expect(result, isA<bool>());
      });

      test('toCron', () {
        final cron = schedule.toCron();
        expect(cron, isA<String>());
      });

      test('toString', () {
        final display = schedule.toString();
        expect(display, isA<String>());
        expect(display, equals('every day at 09:00'));
      });
    });

    // Getters
    group('getters', () {
      test('timezone (null)', () {
        final schedule = Schedule.parse('every day at 09:00');
        expect(schedule.timezone, isNull);
      });

      test('timezone (present)', () {
        final schedule = Schedule.parse('every day at 09:00 in America/New_York');
        expect(schedule.timezone, equals('America/New_York'));
      });
    });

    // Verify all spec methods are covered
    group('spec coverage', () {
      final staticMethods = (scheduleMap['staticMethods'] as List<dynamic>)
          .map((m) => m['name'] as String)
          .toList();
      final instanceMethods = (scheduleMap['instanceMethods'] as List<dynamic>)
          .map((m) => m['name'] as String)
          .toList();
      final getters = (scheduleMap['getters'] as List<dynamic>)
          .map((g) => g['name'] as String)
          .toList();

      test('all static methods tested', () {
        expect(staticMethods, containsAll(['parse', 'fromCron', 'validate']));
      });

      test('all instance methods tested', () {
        expect(instanceMethods,
            containsAll(['nextFrom', 'nextNFrom', 'matches', 'toCron', 'toString']));
      });

      test('all getters tested', () {
        expect(getters, containsAll(['timezone']));
      });
    });
  });
}
