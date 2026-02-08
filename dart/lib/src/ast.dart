// AST types for hron — Dart sealed classes mirroring Rust enums.

enum Weekday {
  monday,
  tuesday,
  wednesday,
  thursday,
  friday,
  saturday,
  sunday;

  int get number => index + 1; // 1=Monday ... 7=Sunday

  int get cronDow {
    const map = [1, 2, 3, 4, 5, 6, 0]; // mon=1..sat=6, sun=0
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

// --- Day filter ---

sealed class DayFilter {}

class EveryDay extends DayFilter {}

class WeekdayFilter extends DayFilter {}

class WeekendFilter extends DayFilter {}

class SpecificDays extends DayFilter {
  final List<Weekday> days;
  SpecificDays(this.days);
}

// --- Day of month spec ---

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

// --- Month target ---

sealed class MonthTarget {}

class DaysTarget extends MonthTarget {
  final List<DayOfMonthSpec> specs;
  DaysTarget(this.specs);
}

class LastDayTarget extends MonthTarget {}

class LastWeekdayTarget extends MonthTarget {}

// --- Year target ---

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

// --- Date spec ---

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

class RelativeDate extends DateSpec {
  final Weekday weekday;
  RelativeDate(this.weekday);
}

// --- Exception spec ---

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

// --- Until spec ---

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

// --- Schedule expression ---

sealed class ScheduleExpr {}

class IntervalRepeat extends ScheduleExpr {
  final int interval;
  final IntervalUnit unit;
  final TimeOfDay from;
  final TimeOfDay to;
  final DayFilter? dayFilter;
  IntervalRepeat(this.interval, this.unit, this.from, this.to, this.dayFilter);
}

class DayRepeat extends ScheduleExpr {
  final DayFilter days;
  final List<TimeOfDay> times;
  DayRepeat(this.days, this.times);
}

class WeekRepeat extends ScheduleExpr {
  final int interval;
  final List<Weekday> days;
  final List<TimeOfDay> times;
  WeekRepeat(this.interval, this.days, this.times);
}

class MonthRepeat extends ScheduleExpr {
  final MonthTarget target;
  final List<TimeOfDay> times;
  MonthRepeat(this.target, this.times);
}

class OrdinalRepeat extends ScheduleExpr {
  final OrdinalPosition ordinal;
  final Weekday day;
  final List<TimeOfDay> times;
  OrdinalRepeat(this.ordinal, this.day, this.times);
}

class SingleDate extends ScheduleExpr {
  final DateSpec date;
  final List<TimeOfDay> times;
  SingleDate(this.date, this.times);
}

class YearRepeat extends ScheduleExpr {
  final YearTarget target;
  final List<TimeOfDay> times;
  YearRepeat(this.target, this.times);
}

// --- Schedule (top-level) ---

class ScheduleData {
  final ScheduleExpr expr;
  String? timezone;
  List<ExceptionSpec> except;
  UntilSpec? until;
  String? anchor;
  List<MonthName> during;

  ScheduleData(this.expr)
      : except = [],
        during = [];
}

// --- Helper functions ---

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
