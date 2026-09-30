import 'package:hron/hron.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart';

void main() {
  // Timezone data must be loaded once before any schedule is evaluated.
  tz.initializeTimeZones();
  final nyc = getLocation('America/New_York');

  final schedule = Schedule.parse(
    'every weekday at 09:00, 17:00 in America/New_York',
  );
  print('Schedule: $schedule');

  final now = TZDateTime.now(nyc);
  print('Next occurrence: ${schedule.nextFrom(now)}');

  print('Next 5 occurrences:');
  for (final dt in schedule.nextNFrom(now, 5)) {
    print('  $dt');
  }

  final monday9am = TZDateTime(nyc, 2025, 1, 6, 9, 0);
  print('Monday 09:00 matches: ${schedule.matches(monday9am)}');

  final fromCron = Schedule.fromCron('0 9 * * 1-5');
  print('From cron "0 9 * * 1-5": $fromCron');
  print('Back to cron: ${fromCron.toCron()}');

  print('Valid expression: ${Schedule.validate('every day at 12:00')}');
  print('Invalid expression: ${Schedule.validate('every day at noon')}');
}
