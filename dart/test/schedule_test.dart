import 'package:test/test.dart';
import 'package:timezone/data/latest_all.dart' as tz;

import 'package:hron/hron.dart';

// Each pair differs in one part, so each field of each part type is compared.
const unequalPairs = [
  ['every day at 09:00', 'every day at 09:01'],
  ['every day at 09:00', 'every day at 10:00'],
  ['every day at 09:00', 'every 2 days at 09:00'],
  ['every day at 09:00', 'every weekday at 09:00'],
  ['every weekday at 09:00', 'every weekend at 09:00'],
  ['every weekend at 09:00', 'every saturday, sunday at 09:00'],
  ['every monday at 09:00', 'every tuesday at 09:00'],
  ['every monday, tuesday at 09:00', 'every tuesday, monday at 09:00'],
  ['every monday at 09:00', 'every monday, monday at 09:00'],
  ['every day at 09:00, 17:00', 'every day at 17:00, 09:00'],
  ['every day at 09:00', 'every day at 09:00, 09:00'],
  ['every 30 min from 09:00 to 17:00', 'every 15 min from 09:00 to 17:00'],
  ['every 2 min from 09:00 to 17:00', 'every 2 hours from 09:00 to 17:00'],
  ['every 30 min from 09:00 to 17:00', 'every 30 min from 08:00 to 17:00'],
  ['every 30 min from 09:00 to 17:00', 'every 30 min from 09:00 to 18:00'],
  [
    'every 30 min from 09:00 to 17:00',
    'every 30 min from 09:00 to 17:00 on weekday',
  ],
  [
    'every 30 min from 09:00 to 17:00 on monday',
    'every 30 min from 09:00 to 17:00 on friday',
  ],
  ['every 2 weeks on monday at 09:00', 'every 3 weeks on monday at 09:00'],
  ['every 2 weeks on monday at 09:00', 'every 2 weeks on friday at 09:00'],
  ['every 2 weeks on monday at 09:00', 'every 2 weeks on monday at 10:00'],
  ['every week on monday at 09:00', 'every monday at 09:00'],
  ['every month on the 1st at 09:00', 'every 2 months on the 1st at 09:00'],
  ['every month on the 1st at 09:00', 'every month on the 2nd at 09:00'],
  ['every month on the 1st at 09:00', 'every month on the 1st at 10:00'],
  [
    'every month on the 1st, 15th at 09:00',
    'every month on the 15th, 1st at 09:00',
  ],
  [
    'every month on the 1st to 5th at 09:00',
    'every month on the 2nd to 5th at 09:00',
  ],
  [
    'every month on the 1st to 5th at 09:00',
    'every month on the 1st to 6th at 09:00',
  ],
  [
    'every month on the 15th at 09:00',
    'every month on the 15th to 15th at 09:00',
  ],
  [
    'every month on the last day at 09:00',
    'every month on the last weekday at 09:00',
  ],
  [
    'every month on the nearest weekday to 15th at 09:00',
    'every month on the nearest weekday to 16th at 09:00',
  ],
  [
    'every month on the nearest weekday to 15th at 09:00',
    'every month on the next nearest weekday to 15th at 09:00',
  ],
  [
    'every month on the next nearest weekday to 15th at 09:00',
    'every month on the previous nearest weekday to 15th at 09:00',
  ],
  [
    'every month on the first monday at 09:00',
    'every month on the second monday at 09:00',
  ],
  [
    'every month on the first monday at 09:00',
    'every month on the first friday at 09:00',
  ],
  ['every year on dec 25 at 09:00', 'every 2 years on dec 25 at 09:00'],
  ['every year on dec 25 at 09:00', 'every year on dec 26 at 09:00'],
  ['every year on dec 25 at 09:00', 'every year on nov 25 at 09:00'],
  ['every year on dec 25 at 09:00', 'every year on dec 25 at 10:00'],
  ['every year on dec 25 at 09:00', 'every year on the 25th of dec at 09:00'],
  [
    'every year on the 15th of mar at 09:00',
    'every year on the 16th of mar at 09:00',
  ],
  [
    'every year on the 15th of mar at 09:00',
    'every year on the 15th of apr at 09:00',
  ],
  [
    'every year on the first monday of mar at 09:00',
    'every year on the second monday of mar at 09:00',
  ],
  [
    'every year on the first monday of mar at 09:00',
    'every year on the first friday of mar at 09:00',
  ],
  [
    'every year on the first monday of mar at 09:00',
    'every year on the first monday of apr at 09:00',
  ],
  [
    'every year on the last weekday of mar at 09:00',
    'every year on the last weekday of apr at 09:00',
  ],
  [
    'every year on the last friday of mar at 09:00',
    'every year on the last weekday of mar at 09:00',
  ],
  ['on 2026-03-15 at 09:00', 'on 2026-03-16 at 09:00'],
  ['on 2026-03-15 at 09:00', 'on 2026-03-15 at 10:00'],
  ['on mar 15 at 09:00', 'on mar 16 at 09:00'],
  ['on mar 15 at 09:00', 'on apr 15 at 09:00'],
  ['on 2026-03-15 at 09:00', 'on mar 15 at 09:00'],
  ['every day at 09:00', 'every day at 09:00 except dec 25'],
  ['every day at 09:00 except dec 25', 'every day at 09:00 except dec 26'],
  ['every day at 09:00 except dec 25', 'every day at 09:00 except nov 25'],
  [
    'every day at 09:00 except 2026-12-25',
    'every day at 09:00 except 2026-12-26',
  ],
  ['every day at 09:00 except dec 25', 'every day at 09:00 except 2026-12-25'],
  [
    'every day at 09:00 except dec 25, jan 1',
    'every day at 09:00 except jan 1, dec 25',
  ],
  [
    'every day at 09:00 except dec 25',
    'every day at 09:00 except dec 25, dec 25',
  ],
  ['every day at 09:00', 'every day at 09:00 until 2026-12-31'],
  [
    'every day at 09:00 until 2026-12-31',
    'every day at 09:00 until 2026-12-30',
  ],
  [
    'every day at 09:00 until dec 31 starting 2026-01-01',
    'every day at 09:00 until dec 30 starting 2026-01-01',
  ],
  [
    'every day at 09:00 until dec 30 starting 2026-01-01',
    'every day at 09:00 until nov 30 starting 2026-01-01',
  ],
  [
    'every day at 09:00 until 2026-12-31 starting 2026-01-01',
    'every day at 09:00 until dec 31 starting 2026-01-01',
  ],
  ['every day at 09:00', 'every day at 09:00 starting 2026-01-01'],
  [
    'every day at 09:00 starting 2026-01-01',
    'every day at 09:00 starting 2026-01-02',
  ],
  ['every day at 09:00', 'every day at 09:00 during jan'],
  ['every day at 09:00 during jan', 'every day at 09:00 during feb'],
  ['every day at 09:00 during jan, feb', 'every day at 09:00 during feb, jan'],
  ['every day at 09:00 during jan', 'every day at 09:00 during jan, jan'],
  ['every day at 09:00', 'every day at 09:00 in UTC'],
  [
    'every day at 09:00 in America/New_York',
    'every day at 09:00 in America/Chicago',
  ],
];

List<List<Object?>> listsIn(Schedule schedule) {
  List<List<Object?>> inFilter(DayFilter? filter) => switch (filter) {
    SpecificDays(:final days) => [days],
    _ => [],
  };
  final expression = schedule.expression;
  return [
    schedule.except,
    schedule.during,
    ...switch (expression) {
      IntervalRepeat(:final dayFilter) => inFilter(dayFilter),
      DayRepeat(:final days, :final times) => [...inFilter(days), times],
      WeekRepeat(:final days, :final times) => [days, times],
      MonthRepeat(target: DaysTarget(:final specs), :final times) => [
        specs,
        times,
      ],
      MonthRepeat(:final times) => [times],
      SingleDate(:final times) => [times],
      YearRepeat(:final times) => [times],
    },
  ];
}

// Between them they hold every kind of list a schedule has, built by parse
// and by fromCron.
final withLists = {
  'parse': [
    'every monday, friday at 09:00, 17:00 except dec 25, 2026-07-04 '
        'during jan, feb',
    'every 30 min from 09:00 to 17:00 on monday, friday',
    'every 2 weeks on monday, friday at 09:00, 17:00',
    'every month on the 1st, 10th to 15th at 09:00',
    'every month on the last day at 09:00',
    'on mar 15 at 09:00',
    'every year on dec 25 at 09:00',
  ].map(Schedule.parse),
  'fromCron': [
    '0 9,17 1,10-15 1,2 *',
    '0 9,17 * 1,2 1,5',
    '0 9 25 12 *',
    '*/15 9-17 * * 1,5',
  ].map(Schedule.fromCron),
};

void main() {
  tz.initializeTimeZones();

  group('getters', () {
    test('return each part of a schedule', () {
      final schedule = Schedule.parse(
        'every weekday at 09:00 except dec 25 until 2027-12-31 '
        'starting 2026-01-01 during jan, dec in america/new_york',
      );
      expect(
        schedule.expression,
        DayRepeat(1, WeekdayFilter(), const [TimeOfDay(9, 0)]),
      );
      expect(schedule.except, [NamedException(MonthName.dec, 25)]);
      expect(schedule.until, IsoUntil('2027-12-31'));
      expect(schedule.starting, '2026-01-01');
      expect(schedule.during, [MonthName.jan, MonthName.dec]);
      expect(schedule.timezone, 'America/New_York');
    });

    test('are empty or null without their clause', () {
      final schedule = Schedule.parse('every day at 09:00');
      expect(schedule.except, isEmpty);
      expect(schedule.until, isNull);
      expect(schedule.starting, isNull);
      expect(schedule.during, isEmpty);
      expect(schedule.timezone, isNull);
    });

    for (final MapEntry(key: builder, value: schedules) in withLists.entries) {
      test('return only unmodifiable lists from $builder', () {
        final modifiable = <String>[];
        for (final schedule in schedules) {
          final shown = schedule.toString();
          final lists = listsIn(schedule);
          expect(lists.where((list) => list.isNotEmpty), isNotEmpty);
          for (final list in lists) {
            final items = '$list';
            try {
              list.clear();
              modifiable.add('$items in $shown');
            } on UnsupportedError {
              continue;
            }
          }
        }
        expect(modifiable, isEmpty);
      });
    }
  });

  group('equality', () {
    test('every day at 9:00 equals every day at 09:00', () {
      final short = Schedule.parse('every day at 9:00');
      final long = Schedule.parse('every day at 09:00');
      expect(short == long, isTrue);
      expect(short.hashCode, long.hashCode);
    });

    test('names in any case are the same parts', () {
      final upper = Schedule.parse(
        'EVERY MONDAY AT 09:00 EXCEPT DEC 25 DURING JAN IN america/new_york',
      );
      final lower = Schedule.parse(
        'every monday at 09:00 except dec 25 during jan in America/New_York',
      );
      expect(upper == lower, isTrue);
      expect(upper.hashCode, lower.hashCode);
    });

    test('a schedule built by fromCron equals the same schedule parsed', () {
      final cron = Schedule.fromCron('0 9 * * 1-5');
      final parsed = Schedule.parse('every weekday at 9:00');
      expect(cron == parsed, isTrue);
      expect(cron.hashCode, parsed.hashCode);
    });

    for (final [a, b] in unequalPairs) {
      test('$a differs from $b', () {
        final first = Schedule.parse(a);
        final second = Schedule.parse(b);
        expect(first == second, isFalse);
        expect(second == first, isFalse);
        expect(first == Schedule.parse(a), isTrue);
        expect(first.hashCode, Schedule.parse(a).hashCode);
      });
    }

    test('a schedule is not equal to null or to any other value', () {
      final schedule = Schedule.parse('every day at 09:00');
      Object? nothing;
      expect(schedule == nothing, isFalse);
      expect(schedule as Object == 'every day at 09:00', isFalse);
      expect(schedule as Object == 42, isFalse);
      expect(schedule as Object == schedule.expression, isFalse);
    });
  });

  test('OrdinalPosition.toN is 1 to 5 for first to fifth and -1 for last', () {
    expect(
      [for (final o in OrdinalPosition.values) o.toN],
      [1, 2, 3, 4, 5, -1],
    );
  });

  group('a null or a value of the wrong type is a usage error', () {
    final entryPoints = {
      'parse': Schedule.parse,
      'validate': Schedule.validate,
      'fromCron': Schedule.fromCron,
    };
    for (final MapEntry(key: name, value: entryPoint) in entryPoints.entries) {
      for (final input in [null, 42, const <String>[]]) {
        test('$name($input) throws a TypeError', () {
          expect(
            () => Function.apply(entryPoint, [input]),
            throwsA(isA<TypeError>()),
          );
        });
      }
    }
  });
}
