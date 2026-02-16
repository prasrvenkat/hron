import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart';

import 'package:hron/hron.dart';

late Map<String, dynamic> spec;
late TZDateTime defaultNow;

TZDateTime parseZoned(String s) {
  // Format: 2026-02-06T12:00:00+00:00[UTC]
  // Or: 2026-02-06T09:00:00-05:00[America/New_York]
  // Or: 2026-03-08T03:00:00-04:00[America/New_York] (DST spring forward)

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

  final loc = tzName == 'UTC' ? UTC : getLocation(tzName);
  // DateTime.parse converts offset strings to UTC internally.
  // Use fromMillisecondsSinceEpoch to correctly reconstruct in the target timezone.
  final dt = DateTime.parse(isoStr);
  return TZDateTime.fromMillisecondsSinceEpoch(loc, dt.millisecondsSinceEpoch);
}

String formatZoned(TZDateTime dt) {
  final offset = dt.timeZoneOffset;
  final sign = offset.isNegative ? '-' : '+';
  final h = offset.inHours.abs().toString().padLeft(2, '0');
  final m = (offset.inMinutes.abs() % 60).toString().padLeft(2, '0');
  final offsetStr = '$sign$h:$m';

  final y = dt.year.toString().padLeft(4, '0');
  final mo = dt.month.toString().padLeft(2, '0');
  final d = dt.day.toString().padLeft(2, '0');
  final hr = dt.hour.toString().padLeft(2, '0');
  final mi = dt.minute.toString().padLeft(2, '0');
  final se = dt.second.toString().padLeft(2, '0');

  return '$y-$mo-${d}T$hr:$mi:$se$offsetStr[${dt.location.name}]';
}

void main() {
  tz.initializeTimeZones();

  // Find spec/tests.json relative to the dart/ directory
  var dir = Directory.current.path;
  // If we're inside dart/, go up one level
  if (p.basename(dir) == 'dart') {
    dir = p.dirname(dir);
  }
  final specPath = p.join(dir, 'spec', 'tests.json');
  spec = jsonDecode(File(specPath).readAsStringSync()) as Map<String, dynamic>;
  defaultNow = parseZoned(spec['now'] as String);

  // =========================================================================
  // Parse conformance
  // =========================================================================

  group('parse roundtrip', () {
    const parseSections = [
      'day_repeat',
      'interval_repeat',
      'week_repeat',
      'month_repeat',
      'ordinal_repeat',
      'single_date',
      'year_repeat',
      'except_clause',
      'until_clause',
      'starting_clause',
      'during_clause',
      'timezone_clause',
      'combined_clauses',
      'case_insensitivity',
    ];

    final parseMap = spec['parse'] as Map<String, dynamic>;

    for (final section in parseSections) {
      group(section, () {
        final sectionData = parseMap[section] as Map<String, dynamic>;
        final tests = sectionData['tests'] as List<dynamic>;
        for (final tc in tests) {
          final name = (tc['name'] ?? tc['input']) as String;
          final input = tc['input'] as String;
          test(name, () {
            final schedule = Schedule.parse(input);
            final display = schedule.toString();
            expect(display, equals(tc['canonical']));

            // Idempotency
            final s2 = Schedule.parse(tc['canonical'] as String);
            expect(s2.toString(), equals(tc['canonical']));
          });
        }
      });
    }
  });

  group('parse errors', () {
    final parseErrors = spec['parse_errors'] as Map<String, dynamic>;
    final tests = parseErrors['tests'] as List<dynamic>;
    for (final tc in tests) {
      final name = (tc['name'] ?? tc['input']) as String;
      test(name, () {
        expect(
          () => Schedule.parse(tc['input'] as String),
          throwsA(isA<HronError>()),
        );
      });
    }
  });

  // =========================================================================
  // Eval conformance
  // =========================================================================

  group('eval', () {
    // Dynamically discover eval sections (skip non-test entries)
    const skipSections = {
      'description',
      'matches',
      'occurrences',
      'between',
      'previous_from',
    };

    final evalMap = spec['eval'] as Map<String, dynamic>;
    final evalSections = evalMap.keys
        .where((s) => !skipSections.contains(s))
        .toList();

    for (final section in evalSections) {
      group(section, () {
        final sectionData = evalMap[section] as Map<String, dynamic>;
        final tests = sectionData['tests'] as List<dynamic>;
        for (final tc in tests) {
          final name = (tc['name'] ?? tc['expression']) as String;
          final expr = tc['expression'] as String;
          test(name, () {
            final schedule = Schedule.parse(expr);
            final now = tc.containsKey('now')
                ? parseZoned(tc['now'] as String)
                : defaultNow;

            // next (full timestamp)
            if (tc.containsKey('next')) {
              final result = schedule.nextFrom(now);
              if (tc['next'] == null) {
                expect(result, isNull);
              } else {
                expect(result, isNotNull);
                expect(formatZoned(result!), equals(tc['next']));
              }
            }

            // next_date (date-only check)
            if (tc.containsKey('next_date')) {
              final result = schedule.nextFrom(now);
              expect(result, isNotNull);
              final dateStr =
                  '${result!.year}-${result.month.toString().padLeft(2, '0')}-${result.day.toString().padLeft(2, '0')}';
              expect(dateStr, equals(tc['next_date']));
            }

            // next_n (list of timestamps)
            if (tc.containsKey('next_n')) {
              final expected = (tc['next_n'] as List<dynamic>).cast<String>();
              final nCount = (tc['next_n_count'] ?? expected.length) as int;
              final results = schedule.nextNFrom(now, nCount);
              expect(results.length, equals(expected.length));
              for (var j = 0; j < expected.length; j++) {
                expect(formatZoned(results[j]), equals(expected[j]));
              }
            }

            // next_n_length (just check count)
            if (tc.containsKey('next_n_length')) {
              final expectedLen = tc['next_n_length'] as int;
              final nCount = tc['next_n_count'] as int;
              final results = schedule.nextNFrom(now, nCount);
              expect(results.length, equals(expectedLen));
            }
          });
        }
      });
    }
  });

  group('eval matches', () {
    final evalMap = spec['eval'] as Map<String, dynamic>;
    final matchesData = evalMap['matches'] as Map<String, dynamic>;
    final tests = matchesData['tests'] as List<dynamic>;
    for (final tc in tests) {
      final name = (tc['name'] ?? tc['expression']) as String;
      test(name, () {
        final schedule = Schedule.parse(tc['expression'] as String);
        final dt = parseZoned(tc['datetime'] as String);
        expect(schedule.matches(dt), equals(tc['expected']));
      });
    }
  });

  group('eval previous_from', () {
    final evalMap = spec['eval'] as Map<String, dynamic>;
    final previousFromData = evalMap['previous_from'] as Map<String, dynamic>;
    final tests = previousFromData['tests'] as List<dynamic>;
    for (final tc in tests) {
      final name = (tc['name'] ?? tc['expression']) as String;
      test(name, () {
        final schedule = Schedule.parse(tc['expression'] as String);
        final now = parseZoned(tc['now'] as String);
        final result = schedule.previousFrom(now);
        if (tc['expected'] == null) {
          expect(result, isNull);
        } else {
          expect(result, isNotNull);
          expect(formatZoned(result!), equals(tc['expected']));
        }
      });
    }
  });

  // =========================================================================
  // Occurrences conformance
  // =========================================================================

  group('occurrences', () {
    final evalMap = spec['eval'] as Map<String, dynamic>;
    final occurrencesData = evalMap['occurrences'] as Map<String, dynamic>;
    final tests = occurrencesData['tests'] as List<dynamic>;
    for (final tc in tests) {
      final name = (tc['name'] ?? tc['expression']) as String;
      test(name, () {
        final schedule = Schedule.parse(tc['expression'] as String);
        final from = parseZoned(tc['from'] as String);
        final take = tc['take'] as int;
        final expected = (tc['expected'] as List<dynamic>).cast<String>();

        final results = schedule.occurrences(from).take(take).toList();

        expect(results.length, equals(expected.length));
        for (var i = 0; i < expected.length; i++) {
          expect(
            formatZoned(results[i]),
            equals(expected[i]),
            reason: 'occurrences[$i] mismatch',
          );
        }
      });
    }
  });

  // =========================================================================
  // Between conformance
  // =========================================================================

  group('between', () {
    final evalMap = spec['eval'] as Map<String, dynamic>;
    final betweenData = evalMap['between'] as Map<String, dynamic>;
    final tests = betweenData['tests'] as List<dynamic>;
    for (final tc in tests) {
      final name = (tc['name'] ?? tc['expression']) as String;
      test(name, () {
        final schedule = Schedule.parse(tc['expression'] as String);
        final from = parseZoned(tc['from'] as String);
        final to = parseZoned(tc['to'] as String);

        final results = schedule.between(from, to).toList();

        if (tc.containsKey('expected')) {
          final expected = (tc['expected'] as List<dynamic>).cast<String>();
          expect(results.length, equals(expected.length));
          for (var i = 0; i < expected.length; i++) {
            expect(
              formatZoned(results[i]),
              equals(expected[i]),
              reason: 'between[$i] mismatch',
            );
          }
        } else if (tc.containsKey('expected_count')) {
          expect(results.length, equals(tc['expected_count']));
        }
      });
    }
  });

  // =========================================================================
  // Eval errors conformance
  // =========================================================================

  group('eval errors', () {
    final evalErrors = spec['eval_errors'] as Map<String, dynamic>;
    final tests = evalErrors['tests'] as List<dynamic>;
    for (final tc in tests) {
      final name = (tc['name'] ?? tc['expression']) as String;
      test(name, () {
        // Dart validates timezone at eval time, so parse may succeed
        // but nextFrom should throw. If parse throws, that's also acceptable.
        // The error may be HronError or a native timezone error.
        Schedule schedule;
        try {
          schedule = Schedule.parse(tc['expression'] as String);
        } catch (_) {
          return; // caught at parse — acceptable
        }
        expect(() => schedule.nextFrom(defaultNow), throwsException);
      });
    }
  });

  // =========================================================================
  // Cron conformance
  // =========================================================================

  group('cron', () {
    final cronMap = spec['cron'] as Map<String, dynamic>;

    group('to_cron', () {
      final tests =
          (cronMap['to_cron'] as Map<String, dynamic>)['tests']
              as List<dynamic>;
      for (final tc in tests) {
        final name = (tc['name'] ?? tc['hron']) as String;
        test(name, () {
          final schedule = Schedule.parse(tc['hron'] as String);
          expect(schedule.toCron(), equals(tc['cron']));
        });
      }
    });

    group('to_cron errors', () {
      final tests =
          (cronMap['to_cron_errors'] as Map<String, dynamic>)['tests']
              as List<dynamic>;
      for (final tc in tests) {
        final name = (tc['name'] ?? tc['hron']) as String;
        test(name, () {
          final schedule = Schedule.parse(tc['hron'] as String);
          expect(() => schedule.toCron(), throwsA(isA<HronError>()));
        });
      }
    });

    group('from_cron', () {
      final tests =
          (cronMap['from_cron'] as Map<String, dynamic>)['tests']
              as List<dynamic>;
      for (final tc in tests) {
        final name = (tc['name'] ?? tc['cron']) as String;
        test(name, () {
          final schedule = Schedule.fromCron(tc['cron'] as String);
          expect(schedule.toString(), equals(tc['hron']));
        });
      }
    });

    group('from_cron errors', () {
      final tests =
          (cronMap['from_cron_errors'] as Map<String, dynamic>)['tests']
              as List<dynamic>;
      for (final tc in tests) {
        final name = (tc['name'] ?? tc['cron']) as String;
        test(name, () {
          expect(
            () => Schedule.fromCron(tc['cron'] as String),
            throwsA(isA<HronError>()),
          );
        });
      }
    });

    group('roundtrip', () {
      final tests =
          (cronMap['roundtrip'] as Map<String, dynamic>)['tests']
              as List<dynamic>;
      for (final tc in tests) {
        final name = (tc['name'] ?? tc['hron']) as String;
        test(name, () {
          final schedule = Schedule.parse(tc['hron'] as String);
          final cron1 = schedule.toCron();
          final back = Schedule.fromCron(cron1);
          final cron2 = back.toCron();
          expect(cron1, equals(cron2));
        });
      }
    });
  });
}
