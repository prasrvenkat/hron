import 'package:hron/hron.dart';
import 'package:test/test.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

void main() {
  tz.initializeTimeZones();

  test('an hour step past a day fires once a day, at the from time', () {
    final schedule = Schedule.parse(
      'every 2147483647 hours from 00:00 to 23:59',
    );
    final now = tz.TZDateTime.utc(2026, 2, 6, 12);

    expect(schedule.nextNFrom(now, 3).map((t) => t.toUtc()), [
      DateTime.utc(2026, 2, 7),
      DateTime.utc(2026, 2, 8),
      DateTime.utc(2026, 2, 9),
    ]);
    expect(schedule.previousFrom(now)?.toUtc(), DateTime.utc(2026, 2, 6));
  });
}
