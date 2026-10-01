// Reads spec/tests.json through dart:io, which the web platforms lack.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart';

import 'package:hron/hron.dart';

import 'support/spec_cases.dart';

late Map<String, dynamic> spec;
late TZDateTime defaultNow;

TZDateTime parseZoned(String s) {
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

const knownTopLevelKeys = {
  r'$schema',
  'version',
  'description',
  'now',
  '_eval_assertion_types',
  '_behavioral_notes',
  'parse',
  'parse_errors',
  'eval',
  'cron',
  'invariants',
};

const knownCronSections = {
  'to_cron',
  'to_cron_errors',
  'from_cron',
  'from_cron_errors',
  'roundtrip',
};

String? formatOrNull(TZDateTime? t) => t == null ? null : formatZoned(t);

String formatDate(TZDateTime t) =>
    '${t.year.toString().padLeft(4, '0')}-'
    '${t.month.toString().padLeft(2, '0')}-'
    '${t.day.toString().padLeft(2, '0')}';

Matcher throwsCronError(Object? message) => throwsA(
  isA<HronError>()
      .having((e) => e.kind, 'kind', HronErrorKind.cron)
      .having((e) => e.message, 'message', message),
);

void checkNext(Map<String, dynamic> tc) {
  checkFields(tc, {
    'expression',
    'now',
    'next',
    'next_date',
    'next_n',
    'next_n_count',
    'next_n_length',
  });
  requireAssertion(tc, ['next', 'next_date', 'next_n', 'next_n_length']);
  final schedule = Schedule.parse(tc['expression'] as String);
  final now = tc.containsKey('now')
      ? parseZoned(tc['now'] as String)
      : defaultNow;

  if (tc.containsKey('next')) {
    expect(formatOrNull(schedule.nextFrom(now)), tc['next'], reason: 'next');
  }
  if (tc.containsKey('next_date')) {
    final next = schedule.nextFrom(now);
    expect(
      next == null ? null : formatDate(next),
      tc['next_date'],
      reason: 'next_date',
    );
  }
  if (tc.containsKey('next_n')) {
    final expected = (tc['next_n'] as List).cast<String>();
    final count = (tc['next_n_count'] ?? expected.length) as int;
    expect(
      schedule.nextNFrom(now, count).map(formatZoned).toList(),
      expected,
      reason: 'next_n',
    );
  }
  if (tc.containsKey('next_n_length')) {
    final count = tc['next_n_count'] as int;
    expect(
      schedule.nextNFrom(now, count).length,
      tc['next_n_length'],
      reason: 'next_n_length',
    );
  }
}

void checkMatches(Map<String, dynamic> tc) {
  checkFields(tc, {'expression', 'datetime', 'expected'});
  requireAssertion(tc, ['expected']);
  final schedule = Schedule.parse(tc['expression'] as String);
  final datetime = parseZoned(tc['datetime'] as String);
  expect(schedule.matches(datetime), tc['expected'] as bool);
}

void checkPreviousFrom(Map<String, dynamic> tc) {
  checkFields(tc, {'expression', 'now', 'expected'});
  requireAssertion(tc, ['expected']);
  final schedule = Schedule.parse(tc['expression'] as String);
  final now = parseZoned(tc['now'] as String);
  expect(formatOrNull(schedule.previousFrom(now)), tc['expected']);
}

void checkOccurrences(Map<String, dynamic> tc) {
  checkFields(tc, {'expression', 'from', 'take', 'expected'});
  requireAssertion(tc, ['expected']);
  final schedule = Schedule.parse(tc['expression'] as String);
  final from = parseZoned(tc['from'] as String);
  expect(
    schedule.occurrences(from).take(tc['take'] as int).map(formatZoned),
    tc['expected'] as List,
  );
}

void checkBetween(Map<String, dynamic> tc) {
  checkFields(tc, {'expression', 'from', 'to', 'expected', 'expected_count'});
  requireAssertion(tc, ['expected', 'expected_count']);
  final schedule = Schedule.parse(tc['expression'] as String);
  final from = parseZoned(tc['from'] as String);
  final to = parseZoned(tc['to'] as String);
  final results = schedule.between(from, to).map(formatZoned).toList();
  if (tc.containsKey('expected')) {
    expect(results, tc['expected'] as List, reason: 'expected');
  }
  if (tc.containsKey('expected_count')) {
    expect(results.length, tc['expected_count'], reason: 'expected_count');
  }
}

/// Sections with their own assertion fields; every other eval section
/// asserts on nextFrom and nextNFrom (spec/README.md "Writing a runner").
const evalChecks = <String, void Function(Map<String, dynamic>)>{
  'matches': checkMatches,
  'previous_from': checkPreviousFrom,
  'occurrences': checkOccurrences,
  'between': checkBetween,
};

String? instant(DateTime? t) => t == null
    ? null
    : DateTime.fromMicrosecondsSinceEpoch(
        t.microsecondsSinceEpoch,
        isUtc: true,
      ).toIso8601String();

List<String?> instants(Iterable<DateTime> ts) => ts.map(instant).toList();

typedef InvariantRule =
    void Function(Schedule schedule, TZDateTime now, int count);

void nextMatches(Schedule schedule, TZDateTime now, int count) {
  final t = schedule.nextFrom(now);
  if (t == null) return;
  expect(schedule.matches(t), isTrue, reason: 'matches(${instant(t)})');
}

void nextAfterNow(Schedule schedule, TZDateTime now, int count) {
  final t = schedule.nextFrom(now);
  if (t == null) return;
  expect(t.isAfter(now), isTrue, reason: '${instant(t)} after now');
}

void nextNChain(Schedule schedule, TZDateTime now, int count) {
  final list = schedule.nextNFrom(now, count);
  final first = schedule.nextFrom(now);
  if (first == null) {
    expect(instants(list), isEmpty, reason: 'nextFrom is null');
    return;
  }
  expect(instant(list.first), instant(first), reason: 'first element');
  for (var i = 1; i < list.length; i++) {
    expect(
      list[i].isAfter(list[i - 1]),
      isTrue,
      reason: 'element $i increases',
    );
    expect(
      instant(schedule.nextFrom(list[i - 1])),
      instant(list[i]),
      reason: 'element $i is nextFrom(${instant(list[i - 1])})',
    );
  }
}

void occurrencesPrefix(Schedule schedule, TZDateTime now, int count) {
  expect(
    instants(schedule.occurrences(now).take(count)),
    instants(schedule.nextNFrom(now, count)),
  );
}

void betweenWindow(Schedule schedule, TZDateTime now, int count) {
  final list = schedule.nextNFrom(now, count);
  if (list.isEmpty) return;
  expect(
    instants(schedule.between(now, list.last)),
    instants(list),
    reason: 'between(now, ${instant(list.last)})',
  );
}

void prevInverse(Schedule schedule, TZDateTime now, int count) {
  final list = schedule.nextNFrom(now, count);
  for (var i = 1; i < list.length; i++) {
    expect(
      instant(schedule.previousFrom(list[i])),
      instant(list[i - 1]),
      reason: 'previousFrom(${instant(list[i])})',
    );
  }
}

void prevBeforeNow(Schedule schedule, TZDateTime now, int count) {
  final p = schedule.previousFrom(now);
  if (p == null) return;
  expect(p.isBefore(now), isTrue, reason: '${instant(p)} before now');
  expect(schedule.matches(p), isTrue, reason: 'matches(${instant(p)})');
  final next = schedule.nextFrom(p);
  expect(
    next == null || !next.isBefore(now),
    isTrue,
    reason: 'nextFrom(${instant(p)}) = ${instant(next)}',
  );
}

void displayRoundtrip(Schedule schedule, TZDateTime now, int count) {
  final display = schedule.toString();
  expect(Schedule.parse(display).toString(), display);
}

const invariantRules = <String, InvariantRule>{
  'next_matches': nextMatches,
  'next_after_now': nextAfterNow,
  'next_n_chain': nextNChain,
  'occurrences_prefix': occurrencesPrefix,
  'between_window': betweenWindow,
  'prev_inverse': prevInverse,
  'prev_before_now': prevBeforeNow,
  'display_roundtrip': displayRoundtrip,
};

void main() {
  tz.initializeTimeZones();

  var dir = Directory.current.path;
  if (p.basename(dir) == 'dart') {
    dir = p.dirname(dir);
  }
  final specPath = p.join(dir, 'spec', 'tests.json');
  spec = jsonDecode(File(specPath).readAsStringSync()) as Map<String, dynamic>;
  defaultNow = parseZoned(spec['now'] as String);

  test('spec has no section this runner does not check', () {
    expect(spec.keys.toSet().difference(knownTopLevelKeys), isEmpty);
    final cronSections = (spec['cron'] as Map<String, dynamic>).keys.toSet();
    expect(cronSections.difference(knownCronSections), isEmpty);
  });

  group('parse roundtrip', () {
    final parseMap = spec['parse'] as Map<String, dynamic>;
    final parseSections = parseMap.keys.where((s) => s != 'description');

    for (final section in parseSections) {
      group(section, () {
        final sectionData = parseMap[section] as Map<String, dynamic>;
        final tests = sectionData['tests'] as List<dynamic>;
        for (final tc in tests) {
          final name = (tc['name'] ?? tc['input']) as String;
          final input = tc['input'] as String;
          test(name, () {
            checkFields(tc as Map<String, dynamic>, {'input', 'canonical'});
            final schedule = Schedule.parse(input);
            final display = schedule.toString();
            expect(display, equals(tc['canonical']));

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
      test(name, () => checkParseError(tc as Map<String, dynamic>));
    }
  });

  group('eval', () {
    final evalMap = spec['eval'] as Map<String, dynamic>;
    for (final MapEntry(key: section, value: data) in evalMap.entries) {
      if (section == 'description') continue;
      final check = evalChecks[section] ?? checkNext;
      group(section, () {
        for (final tc in (data as Map<String, dynamic>)['tests'] as List) {
          final testCase = tc as Map<String, dynamic>;
          test(
            (testCase['name'] ?? testCase['expression']) as String,
            () => check(testCase),
          );
        }
      });
    }
  });

  group('invariants', () {
    final invariants = spec['invariants'] as Map<String, dynamic>;
    final count = invariants['count'] as int;

    test('covers every rule in the spec', () {
      final specRules = (invariants['rules'] as Map<String, dynamic>).keys;
      expect(invariantRules.keys.toSet(), equals(specRules.toSet()));
    });

    for (final tc in invariants['tests'] as List<dynamic>) {
      test(tc['name'] as String, () {
        checkFields(tc as Map<String, dynamic>, {'expression', 'now'});
        final schedule = Schedule.parse(tc['expression'] as String);
        final now = parseZoned(tc['now'] as String);
        for (final MapEntry(key: rule, value: check)
            in invariantRules.entries) {
          try {
            check(schedule, now, count);
          } on TestFailure catch (e) {
            fail('$rule: ${e.message}');
          }
        }
      });
    }
  });

  group('cron', () {
    final cronMap = spec['cron'] as Map<String, dynamic>;

    group('to_cron', () {
      final tests =
          (cronMap['to_cron'] as Map<String, dynamic>)['tests']
              as List<dynamic>;
      for (final tc in tests) {
        final name = (tc['name'] ?? tc['hron']) as String;
        test(name, () {
          checkFields(tc as Map<String, dynamic>, {'hron', 'cron'});
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
          checkFields(tc as Map<String, dynamic>, {'hron', 'error'});
          requireAssertion(tc, ['error']);
          final schedule = Schedule.parse(tc['hron'] as String);
          expect(() => schedule.toCron(), throwsCronError(tc['error']));
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
          checkFields(tc as Map<String, dynamic>, {'cron', 'hron'});
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
          checkFields(tc as Map<String, dynamic>, {'cron', 'error'});
          requireAssertion(tc, ['error']);
          expect(
            () => Schedule.fromCron(tc['cron'] as String),
            throwsCronError(tc['error']),
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
          checkFields(tc as Map<String, dynamic>, {'hron'});
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
