library;

enum Weekday {
  monday,
  tuesday,
  wednesday,
  thursday,
  friday,
  saturday,
  sunday;

  /// ISO 8601: Monday=1, Sunday=7.
  int get number => index + 1;

  /// Sunday=0 … Saturday=6.
  int get cronDow {
    const map = [1, 2, 3, 4, 5, 6, 0];
    return map[index];
  }

  /// Takes cron's 0-7, where 0 and 7 are both Sunday.
  static Weekday fromCronDow(int n) {
    const map = {
      0: Weekday.sunday,
      1: Weekday.monday,
      2: Weekday.tuesday,
      3: Weekday.wednesday,
      4: Weekday.thursday,
      5: Weekday.friday,
      6: Weekday.saturday,
      7: Weekday.sunday,
    };
    return map[n]!;
  }
}

enum MonthName {
  jan,
  feb,
  mar,
  apr,
  may,
  jun,
  jul,
  aug,
  sep,
  oct,
  nov,
  dec;

  /// January=1 … December=12.
  int get number => index + 1;

  static MonthName fromNumber(int n) => MonthName.values[n - 1];
}

enum IntervalUnit { min, hours }

enum OrdinalPosition {
  first,
  second,
  third,
  fourth,
  fifth,
  last;

  /// 1-5 for [first] to [fifth], and -1 for [last].
  int get toN => this == last ? -1 : index + 1;
}

/// A time of day (hour and minute) without timezone.
class TimeOfDay {
  final int hour;
  final int minute;

  const TimeOfDay(this.hour, this.minute);

  @override
  bool operator ==(Object other) =>
      other is TimeOfDay && other.hour == hour && other.minute == minute;

  @override
  int get hashCode => Object.hash(hour, minute);

  @override
  String toString() =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
}

sealed class DayFilter {}

class EveryDay extends DayFilter {
  @override
  bool operator ==(Object other) => other is EveryDay;

  @override
  int get hashCode => (EveryDay).hashCode;
}

/// Matches Monday through Friday.
class WeekdayFilter extends DayFilter {
  @override
  bool operator ==(Object other) => other is WeekdayFilter;

  @override
  int get hashCode => (WeekdayFilter).hashCode;
}

/// Matches Saturday and Sunday.
class WeekendFilter extends DayFilter {
  @override
  bool operator ==(Object other) => other is WeekendFilter;

  @override
  int get hashCode => (WeekendFilter).hashCode;
}

class SpecificDays extends DayFilter {
  final List<Weekday> days;
  SpecificDays(this.days);

  @override
  bool operator ==(Object other) =>
      other is SpecificDays && _listEquals(other.days, days);

  @override
  int get hashCode => Object.hashAll(days);
}

sealed class DayOfMonthSpec {}

class SingleDay extends DayOfMonthSpec {
  final int day;
  SingleDay(this.day);

  @override
  bool operator ==(Object other) => other is SingleDay && other.day == day;

  @override
  int get hashCode => day.hashCode;
}

class DayRange extends DayOfMonthSpec {
  final int start;
  final int end;
  DayRange(this.start, this.end);

  @override
  bool operator ==(Object other) =>
      other is DayRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);
}

/// Direction for nearest weekday (hron extension beyond cron W).
enum NearestDirection {
  /// Always prefer following weekday (can cross to next month).
  next,

  /// Always prefer preceding weekday (can cross to prev month).
  previous,
}

sealed class MonthTarget {}

class DaysTarget extends MonthTarget {
  final List<DayOfMonthSpec> specs;
  DaysTarget(this.specs);

  @override
  bool operator ==(Object other) =>
      other is DaysTarget && _listEquals(other.specs, specs);

  @override
  int get hashCode => Object.hashAll(specs);
}

class LastDayTarget extends MonthTarget {
  @override
  bool operator ==(Object other) => other is LastDayTarget;

  @override
  int get hashCode => (LastDayTarget).hashCode;
}

class LastWeekdayTarget extends MonthTarget {
  @override
  bool operator ==(Object other) => other is LastWeekdayTarget;

  @override
  int get hashCode => (LastWeekdayTarget).hashCode;
}

/// Nearest weekday to [day]. With a null [direction] it never leaves the
/// month, as cron `W` does; with one it can cross into the adjacent month.
class NearestWeekdayTarget extends MonthTarget {
  final int day;
  final NearestDirection? direction;
  NearestWeekdayTarget(this.day, [this.direction]);

  @override
  bool operator ==(Object other) =>
      other is NearestWeekdayTarget &&
      other.day == day &&
      other.direction == direction;

  @override
  int get hashCode => Object.hash(day, direction);
}

class OrdinalWeekdayMonthTarget extends MonthTarget {
  final OrdinalPosition ordinal;
  final Weekday weekday;
  OrdinalWeekdayMonthTarget(this.ordinal, this.weekday);

  @override
  bool operator ==(Object other) =>
      other is OrdinalWeekdayMonthTarget &&
      other.ordinal == ordinal &&
      other.weekday == weekday;

  @override
  int get hashCode => Object.hash(ordinal, weekday);
}

sealed class YearTarget {}

class DateTarget extends YearTarget {
  final MonthName month;
  final int day;
  DateTarget(this.month, this.day);

  @override
  bool operator ==(Object other) =>
      other is DateTarget && other.month == month && other.day == day;

  @override
  int get hashCode => Object.hash(month, day);
}

class OrdinalWeekdayTarget extends YearTarget {
  final OrdinalPosition ordinal;
  final Weekday weekday;
  final MonthName month;
  OrdinalWeekdayTarget(this.ordinal, this.weekday, this.month);

  @override
  bool operator ==(Object other) =>
      other is OrdinalWeekdayTarget &&
      other.ordinal == ordinal &&
      other.weekday == weekday &&
      other.month == month;

  @override
  int get hashCode => Object.hash(ordinal, weekday, month);
}

class DayOfMonthTarget extends YearTarget {
  final int day;
  final MonthName month;
  DayOfMonthTarget(this.day, this.month);

  @override
  bool operator ==(Object other) =>
      other is DayOfMonthTarget && other.day == day && other.month == month;

  @override
  int get hashCode => Object.hash(day, month);
}

class LastWeekdayYearTarget extends YearTarget {
  final MonthName month;
  LastWeekdayYearTarget(this.month);

  @override
  bool operator ==(Object other) =>
      other is LastWeekdayYearTarget && other.month == month;

  @override
  int get hashCode => month.hashCode;
}

sealed class DateSpec {}

class NamedDate extends DateSpec {
  final MonthName month;
  final int day;
  NamedDate(this.month, this.day);

  @override
  bool operator ==(Object other) =>
      other is NamedDate && other.month == month && other.day == day;

  @override
  int get hashCode => Object.hash(month, day);
}

class IsoDate extends DateSpec {
  /// `YYYY-MM-DD`.
  final String date;
  IsoDate(this.date);

  @override
  bool operator ==(Object other) => other is IsoDate && other.date == date;

  @override
  int get hashCode => date.hashCode;
}

/// A date to exclude from a schedule (used in `except` clauses).
sealed class ExceptionSpec {}

class NamedException extends ExceptionSpec {
  final MonthName month;
  final int day;
  NamedException(this.month, this.day);

  @override
  bool operator ==(Object other) =>
      other is NamedException && other.month == month && other.day == day;

  @override
  int get hashCode => Object.hash(month, day);
}

class IsoException extends ExceptionSpec {
  /// `YYYY-MM-DD`.
  final String date;
  IsoException(this.date);

  @override
  bool operator ==(Object other) => other is IsoException && other.date == date;

  @override
  int get hashCode => date.hashCode;
}

/// End date for a schedule (used in `until` clauses).
sealed class UntilSpec {}

class IsoUntil extends UntilSpec {
  /// `YYYY-MM-DD`.
  final String date;
  IsoUntil(this.date);

  @override
  bool operator ==(Object other) => other is IsoUntil && other.date == date;

  @override
  int get hashCode => date.hashCode;
}

class NamedUntil extends UntilSpec {
  final MonthName month;
  final int day;
  NamedUntil(this.month, this.day);

  @override
  bool operator ==(Object other) =>
      other is NamedUntil && other.month == month && other.day == day;

  @override
  int get hashCode => Object.hash(month, day);
}

/// The main pattern of a parsed schedule, without its trailing clauses.
sealed class ScheduleExpr {}

/// Schedule repeating at a minute or hour interval within a daily window.
class IntervalRepeat extends ScheduleExpr {
  final int interval;
  final IntervalUnit unit;
  final TimeOfDay from;
  final TimeOfDay to;

  /// Null without an `on` clause.
  final DayFilter? dayFilter;
  IntervalRepeat(this.interval, this.unit, this.from, this.to, this.dayFilter);

  @override
  bool operator ==(Object other) =>
      other is IntervalRepeat &&
      other.interval == interval &&
      other.unit == unit &&
      other.from == from &&
      other.to == to &&
      other.dayFilter == dayFilter;

  @override
  int get hashCode => Object.hash(interval, unit, from, to, dayFilter);
}

/// Schedule repeating on matching days, optionally every N days.
class DayRepeat extends ScheduleExpr {
  final int interval;
  final DayFilter days;
  final List<TimeOfDay> times;
  DayRepeat(this.interval, this.days, this.times);

  @override
  bool operator ==(Object other) =>
      other is DayRepeat &&
      other.interval == interval &&
      other.days == days &&
      _listEquals(other.times, times);

  @override
  int get hashCode => Object.hash(interval, days, Object.hashAll(times));
}

/// Schedule repeating on given weekdays every N weeks.
class WeekRepeat extends ScheduleExpr {
  final int interval;
  final List<Weekday> days;
  final List<TimeOfDay> times;
  WeekRepeat(this.interval, this.days, this.times);

  @override
  bool operator ==(Object other) =>
      other is WeekRepeat &&
      other.interval == interval &&
      _listEquals(other.days, days) &&
      _listEquals(other.times, times);

  @override
  int get hashCode =>
      Object.hash(interval, Object.hashAll(days), Object.hashAll(times));
}

/// Schedule repeating on a day-of-month target every N months.
class MonthRepeat extends ScheduleExpr {
  final int interval;
  final MonthTarget target;
  final List<TimeOfDay> times;
  MonthRepeat(this.interval, this.target, this.times);

  @override
  bool operator ==(Object other) =>
      other is MonthRepeat &&
      other.interval == interval &&
      other.target == target &&
      _listEquals(other.times, times);

  @override
  int get hashCode => Object.hash(interval, target, Object.hashAll(times));
}

/// Schedule on a single date, given as an ISO date or a month and day.
class SingleDate extends ScheduleExpr {
  final DateSpec date;
  final List<TimeOfDay> times;
  SingleDate(this.date, this.times);

  @override
  bool operator ==(Object other) =>
      other is SingleDate &&
      other.date == date &&
      _listEquals(other.times, times);

  @override
  int get hashCode => Object.hash(date, Object.hashAll(times));
}

/// Schedule repeating on a date target every N years.
class YearRepeat extends ScheduleExpr {
  final int interval;
  final YearTarget target;
  final List<TimeOfDay> times;
  YearRepeat(this.interval, this.target, this.times);

  @override
  bool operator ==(Object other) =>
      other is YearRepeat &&
      other.interval == interval &&
      other.target == target &&
      _listEquals(other.times, times);

  @override
  int get hashCode => Object.hash(interval, target, Object.hashAll(times));
}

class ScheduleData {
  final ScheduleExpr expression;
  final List<ExceptionSpec> except;
  final UntilSpec? until;
  final String? starting;
  final List<MonthName> during;
  final String? timezone;

  const ScheduleData(
    this.expression, {
    this.except = const [],
    this.until,
    this.starting,
    this.during = const [],
    this.timezone,
  });

  @override
  bool operator ==(Object other) =>
      other is ScheduleData &&
      other.expression == expression &&
      _listEquals(other.except, except) &&
      other.until == until &&
      other.starting == starting &&
      _listEquals(other.during, during) &&
      other.timezone == timezone;

  @override
  int get hashCode => Object.hash(
    expression,
    Object.hashAll(except),
    until,
    starting,
    Object.hashAll(during),
    timezone,
  );
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

List<int> expandDaySpec(DayOfMonthSpec spec) {
  if (spec is SingleDay) return [spec.day];
  final range = spec as DayRange;
  return [for (var d = range.start; d <= range.end; d++) d];
}

List<int> expandMonthTarget(MonthTarget target) {
  if (target is DaysTarget) {
    return target.specs.expand(expandDaySpec).toList();
  }
  return [];
}

String ordinalSuffix(int n) {
  final mod100 = n % 100;
  if (mod100 >= 11 && mod100 <= 13) return 'th';
  switch (n % 10) {
    case 1:
      return 'st';
    case 2:
      return 'nd';
    case 3:
      return 'rd';
    default:
      return 'th';
  }
}
