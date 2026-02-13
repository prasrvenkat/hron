import 'package:hron/hron.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart';

void main() {
  // Initialize timezone data (required once at startup)
  tz.initializeTimeZones();
  final nyc = getLocation('America/New_York');

  // Parse a human-readable schedule
  final schedule = Schedule.parse('every weekday at 9am, 5pm');
  print('Schedule: $schedule');

  // Find next occurrence
  final now = TZDateTime.now(nyc);
  final next = schedule.nextFrom(now);
  print('Next occurrence: $next');

  // Find next 5 occurrences
  final nextFive = schedule.nextNFrom(now, 5);
  print('Next 5 occurrences:');
  for (final dt in nextFive) {
    print('  $dt');
  }

  // Check if a datetime matches
  final testTime = TZDateTime(nyc, 2025, 1, 6, 9, 0); // Monday 9am
  print('Monday 9am matches: ${schedule.matches(testTime)}');

  // Convert to cron (if expressible)
  print('As cron: ${schedule.toCron()}');

  // Parse from cron
  final fromCron = Schedule.fromCron('0 9 * * 1-5');
  print('From cron "0 9 * * 1-5": $fromCron');

  // Validate without throwing
  print('Valid expression: ${Schedule.validate("every day at noon")}');
  print('Invalid expression: ${Schedule.validate("every xyz")}');
}
