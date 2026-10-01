/// Wall-clock times on dates in a time zone. A wall time a fall-back repeats
/// takes its first pass (spec/README.md, "DST fall-back (ambiguous times)").
library;

import 'package:timezone/timezone.dart';

import '../ast.dart';
import 'calendar.dart';

const minutesPerHour = 60;

const hoursPerDay = 24;

const _minutesPerDay = hoursPerDay * minutesPerHour;

int minuteOfDay(TimeOfDay time) => time.hour * minutesPerHour + time.minute;

/// The date [t] falls on in its own location.
DateTime dateOf(TZDateTime t) => DateTime.utc(t.year, t.month, t.day);

/// [t]'s wall-clock time in minutes after midnight on [date]: negative when
/// [t] falls on an earlier date, a day or more when on a later one.
int minutesAfterMidnight(DateTime date, TZDateTime t) =>
    daysBetween(date, dateOf(t)) * _minutesPerDay + _wallMinute(t);

TZDateTime startOfMinute(TZDateTime t) => t.subtract(
  Duration(
    seconds: t.second,
    milliseconds: t.millisecond,
    microseconds: t.microsecond,
  ),
);

/// How many minutes [t]'s minute is past the first pass of its wall time:
/// the overlap's length in the second pass of a fall-back, otherwise zero.
int minutesPastFirstPass(TZDateTime t) {
  final firstPass = fixedTimeOn(dateOf(t), _wallMinute(t), t.location);
  return startOfMinute(t).difference(firstPass).inMinutes;
}

int _wallMinute(TZDateTime t) => t.hour * minutesPerHour + t.minute;

/// The instant [minute] minutes after midnight on [date] names in [zone],
/// shifted forward by the gap's length when it falls in a spring-forward gap
/// (spec/README.md, "DST spring-forward (gaps)").
TZDateTime fixedTimeOn(DateTime date, int minute, Location zone) =>
    _resolve(date, minute, zone).instant;

/// The instant of the interval slot [minute] minutes after midnight on
/// [date], or null when that wall time falls in a spring-forward gap
/// (spec/README.md, "Interval slots in a spring-forward gap").
TZDateTime? slotOn(DateTime date, int minute, Location zone) {
  final (:instant, :inGap) = _resolve(date, minute, zone);
  return inGap ? null : instant;
}

/// Tries the offset in force a day before the wall time, then the one a day
/// after: the first that maps the wall time to an instant with that same
/// offset names it, so a repeated time takes its first pass. A time in a gap
/// maps with neither, and the earlier offset puts it the gap's length later.
({TZDateTime instant, bool inGap}) _resolve(
  DateTime date,
  int minute,
  Location zone,
) {
  final wall =
      date.millisecondsSinceEpoch + minute * Duration.millisecondsPerMinute;
  int offsetAt(int ms) => zone.timeZone(ms).offset.inMilliseconds;
  TZDateTime at(int ms) => TZDateTime.fromMillisecondsSinceEpoch(zone, ms);

  final before = offsetAt(wall - Duration.millisecondsPerDay);
  final after = offsetAt(wall + Duration.millisecondsPerDay);
  if (offsetAt(wall - before) == before) {
    return (instant: at(wall - before), inGap: false);
  }
  if (offsetAt(wall - after) == after) {
    return (instant: at(wall - after), inGap: false);
  }
  return (instant: at(wall - before), inGap: true);
}
