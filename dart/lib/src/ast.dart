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

  static Weekday? tryParse(String s) => _weekdayMap[s.toLowerCase()];

  static Weekday fromNumber(int n) => Weekday.values[n - 1];

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

const _weekdayMap = {
  'monday': Weekday.monday,
  'mon': Weekday.monday,
  'tuesday': Weekday.tuesday,
  'tue': Weekday.tuesday,
  'wednesday': Weekday.wednesday,
  'wed': Weekday.wednesday,
  'thursday': Weekday.thursday,
  'thu': Weekday.thursday,
  'friday': Weekday.friday,
  'fri': Weekday.friday,
  'saturday': Weekday.saturday,
  'sat': Weekday.saturday,
  'sunday': Weekday.sunday,
  'sun': Weekday.sunday,
};

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

  int get number => index + 1;

  static MonthName? tryParse(String s) => _monthMap[s.toLowerCase()];

  static MonthName fromNumber(int n) => MonthName.values[n - 1];
}

const _monthMap = {
  'january': MonthName.jan,
  'jan': MonthName.jan,
  'february': MonthName.feb,
  'feb': MonthName.feb,
  'march': MonthName.mar,
  'mar': MonthName.mar,
  'april': MonthName.apr,
  'apr': MonthName.apr,
  'may': MonthName.may,
  'june': MonthName.jun,
  'jun': MonthName.jun,
  'july': MonthName.jul,
  'jul': MonthName.jul,
  'august': MonthName.aug,
  'aug': MonthName.aug,
  'september': MonthName.sep,
  'sep': MonthName.sep,
  'october': MonthName.oct,
  'oct': MonthName.oct,
  'november': MonthName.nov,
  'nov': MonthName.nov,
  'december': MonthName.dec,
  'dec': MonthName.dec,
};

enum IntervalUnit { min, hours }

enum OrdinalPosition {
  first,
  second,
  third,
  fourth,
  fifth,
  last;

  /// 1-5 for [first] to [fifth]; throws for [last].
  int get toN {
    const map = {
      OrdinalPosition.first: 1,
      OrdinalPosition.second: 2,
      OrdinalPosition.third: 3,
      OrdinalPosition.fourth: 4,
      OrdinalPosition.fifth: 5,
    };
    return map[this]!;
  }
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

class EveryDay extends DayFilter {}

/// Matches Monday through Friday.
class WeekdayFilter extends DayFilter {}

/// Matches Saturday and Sunday.
class WeekendFilter extends DayFilter {}

class SpecificDays extends DayFilter {
  final List<Weekday> days;
  SpecificDays(this.days);
}

sealed class DayOfMonthSpec {}

class SingleDay extends DayOfMonthSpec {
  final int day;
  SingleDay(this.day);
}

class DayRange extends DayOfMonthSpec {
  final int start;
  final int end;
  DayRange(this.start, this.end);
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
}

class LastDayTarget extends MonthTarget {}

class LastWeekdayTarget extends MonthTarget {}

/// Nearest weekday to [day]. With a null [direction] it never leaves the
/// month, as cron `W` does; with one it can cross into the adjacent month.
class NearestWeekdayTarget extends MonthTarget {
  final int day;
  final NearestDirection? direction;
  NearestWeekdayTarget(this.day, [this.direction]);
}

class OrdinalWeekdayMonthTarget extends MonthTarget {
  final OrdinalPosition ordinal;
  final Weekday weekday;
  OrdinalWeekdayMonthTarget(this.ordinal, this.weekday);
}

sealed class YearTarget {}

class DateTarget extends YearTarget {
  final MonthName month;
  final int day;
  DateTarget(this.month, this.day);
}

class OrdinalWeekdayTarget extends YearTarget {
  final OrdinalPosition ordinal;
  final Weekday weekday;
  final MonthName month;
  OrdinalWeekdayTarget(this.ordinal, this.weekday, this.month);
}

class DayOfMonthTarget extends YearTarget {
  final int day;
  final MonthName month;
  DayOfMonthTarget(this.day, this.month);
}

class LastWeekdayYearTarget extends YearTarget {
  final MonthName month;
  LastWeekdayYearTarget(this.month);
}

sealed class DateSpec {}

class NamedDate extends DateSpec {
  final MonthName month;
  final int day;
  NamedDate(this.month, this.day);
}

class IsoDate extends DateSpec {
  final String date;
  IsoDate(this.date);
}

/// A date to exclude from a schedule (used in `except` clauses).
sealed class ExceptionSpec {}

class NamedException extends ExceptionSpec {
  final MonthName month;
  final int day;
  NamedException(this.month, this.day);
}

class IsoException extends ExceptionSpec {
  final String date;
  IsoException(this.date);
}

/// End date for a schedule (used in `until` clauses).
sealed class UntilSpec {}

class IsoUntil extends UntilSpec {
  final String date;
  IsoUntil(this.date);
}

class NamedUntil extends UntilSpec {
  final MonthName month;
  final int day;
  NamedUntil(this.month, this.day);
}

/// The main pattern of a parsed schedule, without its trailing clauses.
sealed class ScheduleExpr {}

/// Schedule repeating at a minute or hour interval within a daily window.
class IntervalRepeat extends ScheduleExpr {
  final int interval;
  final IntervalUnit unit;
  final TimeOfDay from;
  final TimeOfDay to;
  final DayFilter? dayFilter;
  IntervalRepeat(this.interval, this.unit, this.from, this.to, this.dayFilter);
}

/// Schedule repeating on matching days, optionally every N days.
class DayRepeat extends ScheduleExpr {
  final int interval;
  final DayFilter days;
  final List<TimeOfDay> times;
  DayRepeat(this.interval, this.days, this.times);
}

/// Schedule repeating on given weekdays every N weeks.
class WeekRepeat extends ScheduleExpr {
  final int interval;
  final List<Weekday> days;
  final List<TimeOfDay> times;
  WeekRepeat(this.interval, this.days, this.times);
}

/// Schedule repeating on a day-of-month target every N months.
class MonthRepeat extends ScheduleExpr {
  final int interval;
  final MonthTarget target;
  final List<TimeOfDay> times;
  MonthRepeat(this.interval, this.target, this.times);
}

/// Schedule on a single date, given as an ISO date or a month and day.
class SingleDate extends ScheduleExpr {
  final DateSpec date;
  final List<TimeOfDay> times;
  SingleDate(this.date, this.times);
}

/// Schedule repeating on a date target every N years.
class YearRepeat extends ScheduleExpr {
  final int interval;
  final YearTarget target;
  final List<TimeOfDay> times;
  YearRepeat(this.interval, this.target, this.times);
}

/// A parsed schedule: the main [expr] plus its trailing clauses.
class ScheduleData {
  final ScheduleExpr expr;
  String? timezone;
  List<ExceptionSpec> except;
  UntilSpec? until;
  String? anchor;
  List<MonthName> during;

  ScheduleData(this.expr) : except = [], during = [];
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
