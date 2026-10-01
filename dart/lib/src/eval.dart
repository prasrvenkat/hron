import 'dart:math';

import 'package:timezone/timezone.dart';

import 'ast.dart';

DateTime _parseIsoDateUtc(String s) {
  final parts = s.split('-');
  return DateTime.utc(
    int.parse(parts[0]),
    int.parse(parts[1]),
    int.parse(parts[2]),
  );
}

String _resolveTz(String? tz) => tz ?? 'UTC';

// The timezone package names its UTC location 'Etc/UTC' since 0.11.1, and
// 'UTC' is not in its database; spec/tests.json expects results in '[UTC]'.
final Location _utc = Location('UTC', [minTime], [0], [TimeZone.UTC]);

Location _getLocation(String tz) => tz == 'UTC' ? _utc : getLocation(tz);

// Resolves a wall-clock time on [date] to an instant. A time repeated by a
// fall-back transition resolves to its first occurrence. A time skipped by a
// spring-forward gap resolves to that time shifted forward by the gap length
// (02:30 -> 03:30) and reports `inGap`, so interval slots can be skipped.
({TZDateTime instant, bool inGap}) _resolve(
  DateTime date,
  int minuteOfDay,
  Location loc,
) {
  final wall =
      date.millisecondsSinceEpoch +
      minuteOfDay * Duration.millisecondsPerMinute;
  int offsetAt(int ms) => loc.timeZone(ms).offset.inMilliseconds;
  TZDateTime at(int ms) => TZDateTime.fromMillisecondsSinceEpoch(loc, ms);

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

DateTime _dateOf(TZDateTime t) => DateTime.utc(t.year, t.month, t.day);

int _minuteOfDay(TimeOfDay t) => t.hour * 60 + t.minute;

int _epochDay(DateTime date) =>
    date.millisecondsSinceEpoch ~/ Duration.millisecondsPerDay;

DateTime _dateOfEpochDay(int day) => DateTime.fromMillisecondsSinceEpoch(
  day * Duration.millisecondsPerDay,
  isUtc: true,
);

int _floorDiv(int a, int b) => (a - a % b) ~/ b;

bool _matchesDayFilter(DateTime date, DayFilter filter) {
  final dow = date.weekday;
  return switch (filter) {
    EveryDay() => true,
    WeekdayFilter() => dow >= 1 && dow <= 5,
    WeekendFilter() => dow == 6 || dow == 7,
    SpecificDays(days: final days) => days.any((d) => d.number == dow),
  };
}

/// Returns null if [day] doesn't exist in the month (e.g. Feb 30).
DateTime? _validDate(int year, int month, int day) {
  final date = DateTime.utc(year, month, day);
  return date.month == month ? date : null;
}

DateTime _lastDayOfMonth(int year, int month) {
  // Day 0 of next month = last day of this month
  return DateTime.utc(year, month + 1, 0);
}

DateTime _lastWeekdayOfMonth(int year, int month) {
  var d = _lastDayOfMonth(year, month);
  while (d.weekday == 6 || d.weekday == 7) {
    d = d.subtract(const Duration(days: 1));
  }
  return d;
}

DateTime? _nthWeekdayOfMonth(int year, int month, Weekday weekday, int n) {
  final targetDow = weekday.number;
  var d = DateTime.utc(year, month, 1);
  while (d.weekday != targetDow) {
    d = d.add(const Duration(days: 1));
  }
  for (var i = 1; i < n; i++) {
    d = d.add(const Duration(days: 7));
  }
  if (d.month != month) return null;
  return d;
}

DateTime _lastWeekdayInMonth(int year, int month, Weekday weekday) {
  final targetDow = weekday.number;
  var d = _lastDayOfMonth(year, month);
  while (d.weekday != targetDow) {
    d = d.subtract(const Duration(days: 1));
  }
  return d;
}

DateTime? _ordinalWeekdayOfMonth(
  int year,
  int month,
  OrdinalPosition ordinal,
  Weekday weekday,
) => ordinal == OrdinalPosition.last
    ? _lastWeekdayInMonth(year, month, weekday)
    : _nthWeekdayOfMonth(year, month, weekday, ordinal.toN);

/// Returns null if [targetDay] doesn't exist in the month (e.g. day 31 in
/// February). A null [direction] is cron `W`: the result stays in the month.
DateTime? _nearestWeekday(
  int year,
  int month,
  int targetDay,
  NearestDirection? direction,
) {
  final last = _lastDayOfMonth(year, month);
  final lastDay = last.day;

  if (targetDay > lastDay) {
    return null;
  }

  final date = DateTime.utc(year, month, targetDay);
  final dow = date.weekday; // 1=Monday ... 7=Sunday

  if (dow >= 1 && dow <= 5) {
    return date;
  }

  if (dow == 6) {
    return switch (direction) {
      NearestDirection.next =>
        // Always next Monday (can cross to next month)
        date.add(const Duration(days: 2)),
      NearestDirection.previous =>
        // Always previous Friday (can cross to prev month)
        date.subtract(const Duration(days: 1)),
      null =>
        // Standard cron W behavior: never cross month boundary
        targetDay == 1
            ? date.add(const Duration(days: 2)) // Monday
            : date.subtract(const Duration(days: 1)), // Friday
    };
  }

  return switch (direction) {
    NearestDirection.next =>
      // Always next Monday (can cross to next month)
      date.add(const Duration(days: 1)),
    NearestDirection.previous =>
      // Always previous Friday (can cross to prev month)
      date.subtract(const Duration(days: 2)),
    null =>
      // Standard cron W behavior: never cross month boundary
      targetDay == lastDay
          ? date.subtract(const Duration(days: 2)) // Friday
          : date.add(const Duration(days: 1)), // Monday
  };
}

List<DateTime> _monthTargetDates(MonthTarget target, int year, int month) {
  final lastDay = _lastDayOfMonth(year, month);
  return switch (target) {
    DaysTarget() => [
      for (final day in expandMonthTarget(target).toSet().toList()..sort())
        if (day <= lastDay.day) DateTime.utc(year, month, day),
    ],
    LastDayTarget() => [lastDay],
    LastWeekdayTarget() => [_lastWeekdayOfMonth(year, month)],
    NearestWeekdayTarget(:final day, :final direction) => [
      ?_nearestWeekday(year, month, day, direction),
    ],
    OrdinalWeekdayMonthTarget(:final ordinal, :final weekday) => [
      ?_ordinalWeekdayOfMonth(year, month, ordinal, weekday),
    ],
  };
}

DateTime? _yearTargetDate(YearTarget target, int year) => switch (target) {
  DateTarget(:final month, :final day) => _validDate(year, month.number, day),
  DayOfMonthTarget(:final month, :final day) => _validDate(
    year,
    month.number,
    day,
  ),
  OrdinalWeekdayTarget(:final ordinal, :final weekday, :final month) =>
    _ordinalWeekdayOfMonth(year, month.number, ordinal, weekday),
  LastWeekdayYearTarget(:final month) => _lastWeekdayOfMonth(
    year,
    month.number,
  ),
};

final DateTime _epochMonday = DateTime.utc(1970, 1, 5);

final DateTime _epochDate = DateTime.utc(1970, 1, 1);

/// The calendar unit a schedule repeats in. Days count from 1970-01-01, weeks
/// from Monday 1970-01-05, months from January of year 0, and years are
/// calendar years.
enum _Unit {
  day(146097),
  week(20871),
  month(4800),
  year(400);

  const _Unit(this.per400Years);

  /// The (proleptic) Gregorian calendar repeats every 400 years.
  final int per400Years;

  int of(DateTime date) => switch (this) {
    _Unit.day => _epochDay(date),
    _Unit.week => _floorDiv(_epochDay(date) - _epochDay(_epochMonday), 7),
    _Unit.month => date.year * 12 + date.month - 1,
    _Unit.year => date.year,
  };
}

(_Unit, int) _repetition(ScheduleExpr expr) => switch (expr) {
  DayRepeat(:final interval) => (_Unit.day, interval),
  IntervalRepeat() => (_Unit.day, 1),
  WeekRepeat(:final interval) => (_Unit.week, interval),
  MonthRepeat(:final interval) => (_Unit.month, interval),
  YearRepeat(:final interval) => (_Unit.year, interval),
  SingleDate() => (_Unit.year, 1),
};

/// The dates [expr] fires on in unit number [n], earliest first, each paired
/// with the month it targets. Only a directional nearest weekday can land
/// outside its target month.
List<(DateTime, int)> _datesIn(ScheduleExpr expr, int n) {
  (DateTime, int) own(DateTime date) => (date, date.month);
  switch (expr) {
    case DayRepeat(:final days):
      final date = _dateOfEpochDay(n);
      return [if (_matchesDayFilter(date, days)) own(date)];
    case IntervalRepeat(:final dayFilter):
      final date = _dateOfEpochDay(n);
      return [
        if (dayFilter == null || _matchesDayFilter(date, dayFilter)) own(date),
      ];
    case WeekRepeat(:final days):
      final monday = _epochDay(_epochMonday) + 7 * n;
      final numbers = days.map((d) => d.number).toSet().toList()..sort();
      return [for (final d in numbers) own(_dateOfEpochDay(monday + d - 1))];
    case MonthRepeat(:final target):
      final year = _floorDiv(n, 12);
      final month = n % 12 + 1;
      return [
        for (final date in _monthTargetDates(target, year, month))
          (date, month),
      ];
    case YearRepeat(:final target):
      final date = _yearTargetDate(target, n);
      return [if (date != null) own(date)];
    case SingleDate(date: IsoDate(:final date)):
      final iso = _parseIsoDateUtc(date);
      return [if (iso.year == n) own(iso)];
    case SingleDate(date: NamedDate(:final month, :final day)):
      final date = _validDate(n, month.number, day);
      return [if (date != null) own(date)];
  }
}

/// The earliest of [times] on [date] after [now] when [dir] is 1, or the
/// latest before it when [dir] is -1.
TZDateTime? _timeOn(
  List<TimeOfDay> times,
  DateTime date,
  TZDateTime now,
  int dir,
  Location loc,
) {
  TZDateTime? best;
  for (final time in times) {
    final t = _resolve(date, _minuteOfDay(time), loc).instant;
    if (t.compareTo(now) * dir > 0 &&
        (best == null || t.compareTo(best) * dir < 0)) {
      best = t;
    }
  }
  return best;
}

/// Like [_timeOn] for the slots of [expr]. Slot instants rise with their
/// wall times, so the scan starts at [now]'s wall time and stops at the first
/// slot on the right side of [now].
TZDateTime? _slotOn(
  IntervalRepeat expr,
  DateTime date,
  TZDateTime now,
  int dir,
  Location loc,
) {
  // A step of a day or more leaves only the `from` slot; the cap stops the
  // multiplication from overflowing.
  final step = expr.unit == IntervalUnit.min
      ? expr.interval
      : min(expr.interval, 24) * 60;
  final from = _minuteOfDay(expr.from);
  final to = _minuteOfDay(expr.to);
  if (to < from) return null;
  final last = (to - from) ~/ step;

  final local = TZDateTime.from(now, loc);
  final nowDate = _dateOf(local);
  final nowMinute = local.hour * 60 + local.minute;
  var minute = (_epochDay(nowDate) - _epochDay(date)) * 1440 + nowMinute;

  if (dir > 0) {
    for (
      var k = minute < from ? 0 : (minute - from) ~/ step + 1;
      k <= last;
      k++
    ) {
      final slot = _resolve(date, from + k * step, loc);
      if (!slot.inGap && slot.instant.isAfter(now)) return slot.instant;
    }
    return null;
  }

  // In the second pass of a fall-back overlap, later wall times resolved to
  // the first pass are still before now.
  final firstPass = _resolve(nowDate, nowMinute, loc).instant;
  final nowFloor = local.subtract(
    Duration(
      seconds: local.second,
      milliseconds: local.millisecond,
      microseconds: local.microsecond,
    ),
  );
  minute += nowFloor.difference(firstPass).inMinutes;
  final top = minute < from ? -1 : min((minute - from) ~/ step, last);
  for (var k = top; k >= 0; k--) {
    final slot = _resolve(date, from + k * step, loc);
    if (!slot.inGap && slot.instant.isBefore(now)) return slot.instant;
  }
  return null;
}

class _ParsedExceptions {
  final List<(int, int)> named; // (month_number, day)
  final List<DateTime> isoDates;

  _ParsedExceptions(this.named, this.isoDates);

  factory _ParsedExceptions.from(List<ExceptionSpec> exceptions) {
    final named = <(int, int)>[];
    final isoDates = <DateTime>[];
    for (final exc in exceptions) {
      if (exc is NamedException) {
        named.add((exc.month.number, exc.day));
      } else {
        isoDates.add(_parseIsoDateUtc((exc as IsoException).date));
      }
    }
    return _ParsedExceptions(named, isoDates);
  }

  bool isExcepted(DateTime date) {
    for (final (m, d) in named) {
      if (date.month == m && date.day == d) return true;
    }
    for (final excDate in isoDates) {
      if (date.year == excDate.year &&
          date.month == excDate.month &&
          date.day == excDate.day) {
        return true;
      }
    }
    return false;
  }
}

bool _matchesDuring(int month, List<MonthName> during) =>
    during.isEmpty || during.any((mn) => mn.number == month);

/// The first date on or after [starting] that [until] names (spec/README.md
/// "Named until"); the parser guarantees a named until has a starting date.
DateTime _resolveUntil(UntilSpec until, DateTime? starting) {
  switch (until) {
    case IsoUntil(:final date):
      return _parseIsoDateUtc(date);
    case NamedUntil(:final month, :final day):
      for (var year = starting!.year; ; year++) {
        final date = _validDate(year, month.number, day);
        if (date != null && !date.isBefore(starting)) return date;
      }
  }
}

// spec/README.md "Supported range".
final DateTime _firstInstant = DateTime.utc(1, 1, 2);
final DateTime _endInstant = DateTime.utc(9999, 12, 30);

bool _inRange(DateTime t) =>
    !t.isBefore(_firstInstant) && t.isBefore(_endInstant);

TZDateTime? nextFrom(ScheduleData schedule, TZDateTime now) =>
    _inRange(now) ? _search(schedule, now, 1) : null;

TZDateTime? previousFrom(ScheduleData schedule, TZDateTime now) =>
    _inRange(now) ? _search(schedule, now, -1) : null;

/// The first occurrence after [now] when [dir] is 1, or the last before it
/// when [dir] is -1, walking the aligned units of the schedule for one full
/// cycle of the calendar beyond the start and every ISO except date
/// (spec/README.md "Search horizon").
TZDateTime? _search(ScheduleData schedule, TZDateTime now, int dir) {
  final loc = _getLocation(_resolveTz(schedule.timezone));
  final expr = schedule.expr;
  final (unit, repeat) = _repetition(expr);
  // Any interval of 2^32 units or more leaves only the anchor's unit inside the
  // supported range, so capping there changes nothing and keeps unit arithmetic
  // far from integer overflow (and below 2^53 on the web).
  final interval = min(repeat, 1 << 32);
  final starting = schedule.anchor == null
      ? null
      : _parseIsoDateUtc(schedule.anchor!);
  final anchor = starting == null ? null : unit.of(starting);
  final origin =
      anchor ?? unit.of(unit == _Unit.week ? _epochMonday : _epochDate);
  final until = schedule.until == null
      ? null
      : _resolveUntil(schedule.until!, starting);
  final exceptions = _ParsedExceptions.from(schedule.except);

  var start = _dateOf(TZDateTime.from(now, loc));
  if (dir < 0 && until != null && until.isBefore(start)) start = until;
  // Start one unit against the direction of travel: a directional nearest
  // weekday targeted in the adjacent month can land in this one.
  var n = unit.of(start) - dir;
  n += dir > 0 ? (origin - n) % interval : -((n - origin) % interval);
  // Units before the anchor's hold no date on or after [starting], except a
  // nearest weekday landing forward from the unit just before.
  if (anchor != null && dir > 0 && n < anchor - interval) n = anchor - interval;
  // An ISO date occurs once, so the search jumps straight to its year.
  if (expr case SingleDate(date: IsoDate(:final date))) {
    final year = _parseIsoDateUtc(date).year;
    if ((year - n) * dir > 0) n = year;
  }

  var beyond = 0;
  for (final date in exceptions.isoDates) {
    beyond = max(beyond, (unit.of(date) - n) * dir);
  }
  final count =
      unit.per400Years ~/ unit.per400Years.gcd(interval) +
      2 +
      (beyond + interval - 1) ~/ interval;
  // One unit of slack past the range: a nearest weekday can land back inside.
  final lastUnit = unit.of(
    dir > 0 ? DateTime.utc(9999, 12, 31) : DateTime.utc(1),
  );
  TZDateTime? best;
  DateTime? bestDate;
  for (
    var i = 0;
    i < count && (n - lastUnit) * dir <= 1;
    i++, n += dir * interval
  ) {
    if (anchor != null && n < anchor - interval) return best;
    final dates = _datesIn(expr, n);
    for (final (date, month) in dir > 0 ? dates : dates.reversed) {
      // A time shifted past midnight by a gap lands on the next date, where
      // it competes with that date's own times; no date beyond can compete.
      if (bestDate != null &&
          (_epochDay(date) - _epochDay(bestDate)) * dir > 1) {
        return best;
      }
      final outside = date.year > 9999 ? 1 : (date.year < 1 ? -1 : 0);
      if (outside != 0) {
        if (outside == dir) return best;
        continue;
      }
      if (until != null && date.isAfter(until)) {
        if (dir > 0) return best;
        continue;
      }
      if (!_matchesDuring(month, schedule.during) ||
          exceptions.isExcepted(date) ||
          (starting != null && date.isBefore(starting))) {
        continue;
      }
      final t = switch (expr) {
        IntervalRepeat() => _slotOn(expr, date, now, dir, loc),
        DayRepeat(:final times) ||
        WeekRepeat(:final times) ||
        MonthRepeat(:final times) ||
        SingleDate(:final times) ||
        YearRepeat(:final times) => _timeOn(times, date, now, dir, loc),
      };
      if (t != null &&
          _inRange(t) &&
          (best == null || t.compareTo(best) * dir < 0)) {
        best = t;
        bestDate ??= date;
      }
    }
  }
  return best;
}

/// True when the minute containing [datetime] is an occurrence.
bool matches(ScheduleData schedule, TZDateTime datetime) {
  if (!_inRange(datetime)) return false;
  final local = TZDateTime.from(
    datetime,
    _getLocation(_resolveTz(schedule.timezone)),
  );
  final minute = local.subtract(
    Duration(
      seconds: local.second,
      milliseconds: local.millisecond,
      microseconds: local.microsecond,
    ),
  );
  final next = _search(
    schedule,
    minute.subtract(const Duration(milliseconds: 1)),
    1,
  );
  return next != null && next.isAtSameMomentAs(minute);
}

List<TZDateTime> nextNFrom(ScheduleData schedule, TZDateTime now, int n) =>
    occurrences(schedule, now).take(n < 0 ? 0 : n).toList();

Iterable<TZDateTime> occurrences(ScheduleData schedule, TZDateTime from) sync* {
  for (
    var next = nextFrom(schedule, from);
    next != null;
    next = nextFrom(schedule, next)
  ) {
    yield next;
  }
}

Iterable<TZDateTime> between(
  ScheduleData schedule,
  TZDateTime from,
  TZDateTime to,
) => _inRange(to)
    ? occurrences(schedule, from).takeWhile((t) => !t.isAfter(to))
    : const [];
