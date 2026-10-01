// spec/README.md, "Timestamps and counts" and "Supported range", checked on
// the web platforms too, where spec/tests.json is not run.
import 'package:hron/hron.dart';
import 'package:test/test.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart';

/// DateTime's range on every platform: 100,000,000 days either side of the
/// epoch.
const limitMs = 8640000000000000;

/// TZDateTime throws when the wall time of [ms] in [zone] lies past
/// DateTime's range, as at both limits in Pacific/Kiritimati and at the lower
/// one in Etc/GMT+12, so the instant moves just inside it.
TZDateTime atLimit(Location zone, int ms) {
  final offset = zone.timeZone(ms).offset.inMilliseconds;
  final wall = (ms + offset).clamp(-limitMs, limitMs);
  return TZDateTime.fromMillisecondsSinceEpoch(zone, wall - offset);
}

Location zoneNamed(String name) => name == 'UTC' ? UTC : getLocation(name);

void main() {
  tz.initializeTimeZones();

  group('an argument at the limit of DateTime', () {
    const expressions = [
      'every day at 09:00',
      'every day at 09:00 in Pacific/Kiritimati',
      'every day at 09:00 in Etc/GMT+12',
    ];
    final inRange = TZDateTime.utc(2026, 2, 6, 12);
    for (final zoneName in ['UTC', 'Pacific/Kiritimati', 'Etc/GMT+12']) {
      for (final ms in [-limitMs, limitMs]) {
        for (final expression in expressions) {
          test('$ms ms in $zoneName gives nothing for $expression', () {
            final schedule = Schedule.parse(expression);
            final t = atLimit(zoneNamed(zoneName), ms);
            expect(schedule.nextFrom(t), isNull, reason: 'nextFrom');
            expect(schedule.previousFrom(t), isNull, reason: 'previousFrom');
            expect(schedule.matches(t), isFalse, reason: 'matches');
            expect(schedule.nextNFrom(t, 5), isEmpty, reason: 'nextNFrom');
            expect(schedule.occurrences(t), isEmpty, reason: 'occurrences');
            expect(schedule.between(t, t), isEmpty, reason: 'between');
            final (from, to) = ms < 0 ? (t, inRange) : (inRange, t);
            expect(
              schedule.between(from, to),
              isEmpty,
              reason: 'between with one bound in range',
            );
          });
        }
      }
    }
  });

  group('results are in the schedule zone', () {
    final now = TZDateTime(getLocation('Asia/Tokyo'), 2026, 2, 6, 21);
    for (final (expression, zoneName) in [
      ('every day at 09:00 in America/New_York', 'America/New_York'),
      ('every day at 09:00', 'UTC'),
    ]) {
      test('$expression returns $zoneName from a Tokyo now', () {
        final schedule = Schedule.parse(expression);
        final results = [
          schedule.nextFrom(now)!,
          ...schedule.nextNFrom(now, 2),
          schedule.previousFrom(now)!,
          ...schedule.occurrences(now).take(2),
          ...schedule.between(now, now.add(const Duration(days: 2))),
        ];
        expect(results, hasLength(8));
        expect(results.map((t) => t.location.name), everyElement(zoneName));
      });
    }
  });

  test('the zone an argument is written in does not change any result', () {
    final schedule = Schedule.parse('every day at 09:00 in America/New_York');
    final tokyo = TZDateTime(getLocation('Asia/Tokyo'), 2026, 2, 6, 23, 0, 30);
    String outcome(TZDateTime t) => [
      schedule.nextFrom(t),
      schedule.previousFrom(t),
      schedule.matches(t),
      schedule.nextNFrom(t, 2),
      schedule.occurrences(t).take(2).toList(),
      schedule.between(t.subtract(const Duration(days: 2)), t).toList(),
    ].toString();
    final expected = outcome(tokyo);
    expect(expected, contains('true'), reason: 'matches in Tokyo');
    for (final zone in [UTC, getLocation('America/New_York')]) {
      expect(outcome(TZDateTime.from(tokyo, zone)), expected, reason: '$zone');
    }
  });

  group('nextNFrom count', () {
    final schedule = Schedule.parse('every day at 09:00');
    final now = TZDateTime.utc(2026, 2, 6, 12);
    for (final n in [0, -1, -2147483648, -9007199254740991]) {
      test('$n returns no occurrence', () {
        expect(schedule.nextNFrom(now, n), isEmpty);
      });
    }
    for (final n in [2147483647, 9007199254740991]) {
      test('$n returns the one occurrence there is', () {
        final once = Schedule.parse('on 2026-03-01 at 09:00');
        expect(once.nextNFrom(now, n).map((t) => t.toUtc()), [
          TZDateTime.utc(2026, 3, 1, 9),
        ]);
      });
    }
  });
}
