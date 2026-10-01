/// Date arithmetic on the proleptic Gregorian calendar: no time zones, no
/// schedules. A date is a [DateTime] at midnight UTC.
library;

import '../ast.dart';

/// A `YYYY-MM-DD` date, which the parser has validated.
DateTime parseIsoDate(String iso) {
  final [year, month, day] = iso.split('-').map(int.parse).toList();
  return DateTime.utc(year, month, day);
}

/// [year]-[month]-[day], or null when the month has no such day.
DateTime? validDate(int year, int month, int day) {
  final date = DateTime.utc(year, month, day);
  return date.month == month ? date : null;
}

int floorDiv(int a, int b) => (a - a % b) ~/ b;

int epochDay(DateTime date) =>
    date.millisecondsSinceEpoch ~/ Duration.millisecondsPerDay;

int daysBetween(DateTime a, DateTime b) => epochDay(b) - epochDay(a);

DateTime addDays(DateTime date, int days) => date.add(Duration(days: days));

/// Months since January of year 0.
int monthIndex(DateTime date) => date.year * 12 + date.month - 1;

int monthsBetween(DateTime a, DateTime b) => monthIndex(b) - monthIndex(a);

DateTime firstOfMonthIndex(int index) =>
    DateTime.utc(floorDiv(index, 12), index % 12 + 1);

DateTime mondayOfWeek(DateTime date) =>
    addDays(date, DateTime.monday - date.weekday);

bool matchesDayFilter(DateTime date, DayFilter filter) => switch (filter) {
  EveryDay() => true,
  WeekdayFilter() => !_isWeekend(date),
  WeekendFilter() => _isWeekend(date),
  SpecificDays(:final days) => days.any((day) => day.number == date.weekday),
};

bool _isWeekend(DateTime date) =>
    date.weekday == DateTime.saturday || date.weekday == DateTime.sunday;

/// The dates a monthly target names in a month, earliest first.
List<DateTime> monthTargetDates(int year, int month, MonthTarget target) =>
    switch (target) {
      DaysTarget() => [
        for (final day in expandMonthTarget(target).toSet().toList()..sort())
          ?validDate(year, month, day),
      ],
      LastDayTarget() => [_lastDayOfMonth(year, month)],
      LastWeekdayTarget() => [_lastWeekdayOfMonth(year, month)],
      NearestWeekdayTarget(:final day, :final direction) => [
        ?_nearestWeekday(year, month, day, direction),
      ],
      OrdinalWeekdayMonthTarget(:final ordinal, :final weekday) => [
        ?_ordinalWeekday(year, month, ordinal, weekday),
      ],
    };

DateTime? yearTargetDate(int year, YearTarget target) => switch (target) {
  DateTarget(:final month, :final day) ||
  DayOfMonthTarget(
    :final month,
    :final day,
  ) => validDate(year, month.number, day),
  OrdinalWeekdayTarget(:final ordinal, :final weekday, :final month) =>
    _ordinalWeekday(year, month.number, ordinal, weekday),
  LastWeekdayYearTarget(:final month) => _lastWeekdayOfMonth(
    year,
    month.number,
  ),
};

DateTime _lastDayOfMonth(int year, int month) =>
    DateTime.utc(year, month + 1, 0);

/// The last Monday to Friday of a month.
DateTime _lastWeekdayOfMonth(int year, int month) {
  final last = _lastDayOfMonth(year, month);
  final back = switch (last.weekday) {
    DateTime.saturday => 1,
    DateTime.sunday => 2,
    _ => 0,
  };
  return addDays(last, -back);
}

DateTime? _ordinalWeekday(
  int year,
  int month,
  OrdinalPosition ordinal,
  Weekday weekday,
) {
  if (ordinal == OrdinalPosition.last) {
    final last = _lastDayOfMonth(year, month);
    return addDays(last, -((last.weekday - weekday.number) % 7));
  }
  final first = DateTime.utc(year, month);
  final firstMatch = addDays(first, (weekday.number - first.weekday) % 7);
  final date = addDays(firstMatch, 7 * (ordinal.toN - 1));
  return date.month == month ? date : null;
}

/// The weekday nearest [day] of a month, or null when the month is shorter.
/// Without a direction it stays in the month, as cron's `W` does; with one it
/// can cross into the adjacent month (spec/README.md, "Nearest weekday and
/// `during`").
DateTime? _nearestWeekday(
  int year,
  int month,
  int day,
  NearestDirection? toward,
) {
  final date = validDate(year, month, day);
  if (date == null) return null;
  final shift = switch ((date.weekday, toward)) {
    (DateTime.saturday, NearestDirection.next) => 2,
    (DateTime.saturday, NearestDirection.previous) => -1,
    (DateTime.saturday, null) when day == 1 => 2,
    (DateTime.saturday, null) => -1,
    (DateTime.sunday, NearestDirection.next) => 1,
    (DateTime.sunday, NearestDirection.previous) => -2,
    (DateTime.sunday, null) when date == _lastDayOfMonth(year, month) => -2,
    (DateTime.sunday, null) => 1,
    _ => 0,
  };
  return addDays(date, shift);
}
