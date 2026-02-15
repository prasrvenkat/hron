import 'package:timezone/timezone.dart';

import 'ast.dart';

// --- Date parsing helper ---

/// Parse an ISO date string (YYYY-MM-DD) into a UTC DateTime.
DateTime _parseIsoDateUtc(String s) {
  // YYYY-MM-DD format
  final parts = s.split('-');
  return DateTime.utc(
    int.parse(parts[0]),
    int.parse(parts[1]),
    int.parse(parts[2]),
  );
}

// --- Timezone resolution ---

String _resolveTz(String? tz) => tz ?? 'UTC';

Location _getLocation(String tz) => tz == 'UTC' ? UTC : getLocation(tz);

// --- Helpers ---

TZDateTime _atTimeOnDate(DateTime date, int hour, int minute, Location loc) {
  return TZDateTime(loc, date.year, date.month, date.day, hour, minute);
}

int _dayOfWeek(DateTime date) {
  // DateTime.weekday: 1=Monday ... 7=Sunday (ISO)
  return date.weekday;
}

bool _matchesDayFilter(DateTime date, DayFilter filter) {
  final dow = _dayOfWeek(date);
  return switch (filter) {
    EveryDay() => true,
    WeekdayFilter() => dow >= 1 && dow <= 5,
    WeekendFilter() => dow == 6 || dow == 7,
    SpecificDays(days: final days) => days.any((d) => d.number == dow),
  };
}

DateTime _lastDayOfMonth(int year, int month) {
  // Day 0 of next month = last day of this month
  if (month == 12) {
    return DateTime.utc(year + 1, 1, 0);
  }
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

/// Get the nearest weekday to a given day in a month.
/// - direction=null: standard cron W behavior (never crosses month boundary)
/// - direction=next: always prefer following weekday (can cross to next month)
/// - direction=previous: always prefer preceding weekday (can cross to prev month)
/// Returns null if the target_day doesn't exist in the month (e.g., day 31 in February).
DateTime? _nearestWeekday(
  int year,
  int month,
  int targetDay,
  NearestDirection? direction,
) {
  final last = _lastDayOfMonth(year, month);
  final lastDay = last.day;

  // If target day doesn't exist in this month, return null (skip this month)
  if (targetDay > lastDay) {
    return null;
  }

  final date = DateTime.utc(year, month, targetDay);
  final dow = date.weekday; // 1=Monday ... 7=Sunday

  // Already a weekday
  if (dow >= 1 && dow <= 5) {
    return date;
  }

  // Saturday (dow == 6)
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

  // Sunday (dow == 7)
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

int _euclideanMod(int a, int b) => ((a % b) + b) % b;

final DateTime _epochMonday = DateTime.utc(1970, 1, 5);

final DateTime _epochDate = DateTime.utc(1970, 1, 1);

int _daysBetween(DateTime a, DateTime b) => b.difference(a).inDays;

int _monthsBetweenYM(DateTime a, DateTime b) =>
    (b.year * 12 + b.month) - (a.year * 12 + a.month);

int _weeksBetween(DateTime a, DateTime b) {
  final days = b.difference(a).inDays;
  return days ~/ 7;
}

bool _isExcepted(DateTime date, List<ExceptionSpec> exceptions) {
  for (final exc in exceptions) {
    if (exc is NamedException) {
      if (date.month == exc.month.number && date.day == exc.day) return true;
    } else {
      final iso = (exc as IsoException).date;
      final excDate = _parseIsoDateUtc(iso);
      if (date.year == excDate.year &&
          date.month == excDate.month &&
          date.day == excDate.day) {
        return true;
      }
    }
  }
  return false;
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

bool _matchesDuring(DateTime date, List<MonthName> during) {
  if (during.isEmpty) return true;
  return during.any((mn) => mn.number == date.month);
}

/// Find the 1st of the next valid `during` month after `date`.
DateTime _nextDuringMonth(DateTime date, List<MonthName> during) {
  final currentMonth = date.month;
  final months = during.map((mn) => mn.number).toList()..sort();

  for (final m in months) {
    if (m > currentMonth) {
      return DateTime.utc(date.year, m, 1);
    }
  }
  // Wrap to first month of next year
  return DateTime.utc(date.year + 1, months[0], 1);
}

DateTime _resolveUntil(UntilSpec until, TZDateTime now) {
  if (until is IsoUntil) {
    return _parseIsoDateUtc(until.date);
  }
  final named = until as NamedUntil;
  final year = now.year;
  for (final y in [year, year + 1]) {
    try {
      final d = DateTime.utc(y, named.month.number, named.day);
      // Verify the date is valid (not overflow)
      if (d.month == named.month.number && d.day == named.day) {
        if (!d.isBefore(DateTime.utc(now.year, now.month, now.day))) {
          return d;
        }
      }
    } on Exception catch (_) {
      // Invalid date construction, try next year
    }
  }
  return DateTime.utc(year + 1, named.month.number, named.day);
}

TZDateTime? _earliestFutureAtTimes(
  DateTime date,
  List<TimeOfDay> times,
  Location loc,
  TZDateTime now,
) {
  TZDateTime? best;
  for (final tod in times) {
    final candidate = _atTimeOnDate(date, tod.hour, tod.minute, loc);
    if (candidate.isAfter(now)) {
      if (best == null || candidate.isBefore(best)) {
        best = candidate;
      }
    }
  }
  return best;
}

TZDateTime? _latestPastAtTimes(
  DateTime date,
  List<TimeOfDay> times,
  Location loc,
  TZDateTime now,
) {
  TZDateTime? best;
  for (final tod in times) {
    final candidate = _atTimeOnDate(date, tod.hour, tod.minute, loc);
    if (candidate.isBefore(now)) {
      if (best == null || candidate.isAfter(best)) {
        best = candidate;
      }
    }
  }
  return best;
}

/// Find the last day of the previous valid `during` month before `date`.
DateTime? _prevDuringMonth(DateTime date, List<MonthName> during) {
  final currentMonth = date.month;
  final months = during.map((mn) => mn.number).toList()..sort((a, b) => b - a);

  for (final m in months) {
    if (m < currentMonth) {
      return _lastDayOfMonth(date.year, m);
    }
  }
  // Wrap to last month of previous year
  if (months.isNotEmpty) {
    return _lastDayOfMonth(date.year - 1, months[0]);
  }
  return null;
}

// --- Public API ---

TZDateTime? nextFrom(ScheduleData schedule, TZDateTime now) {
  final tzName = _resolveTz(schedule.timezone);
  final loc = _getLocation(tzName);

  final untilDate = schedule.until != null
      ? _resolveUntil(schedule.until!, now)
      : null;

  final parsedExceptions = _ParsedExceptions.from(schedule.except);
  final hasExceptions = schedule.except.isNotEmpty;
  final hasDuring = schedule.during.isNotEmpty;
  final needsTzConversion = untilDate != null || hasDuring || hasExceptions;

  // Check if expression is NearestWeekday with direction (can cross month boundaries)
  final handlesDuringInternally =
      schedule.expr is MonthRepeat &&
      (schedule.expr as MonthRepeat).target is NearestWeekdayTarget &&
      ((schedule.expr as MonthRepeat).target as NearestWeekdayTarget)
              .direction !=
          null;

  var current = now;
  for (var i = 0; i < 1000; i++) {
    final candidate = _nextExpr(
      schedule.expr,
      loc,
      schedule.anchor,
      current,
      during: handlesDuringInternally ? schedule.during : const [],
    );

    if (candidate == null) return null;

    // Convert to target tz once for all filter checks
    DateTime? cDate;
    if (needsTzConversion) {
      final cInTz = TZDateTime.from(candidate, loc);
      cDate = DateTime.utc(cInTz.year, cInTz.month, cInTz.day);
    }

    // Apply until filter
    if (untilDate != null) {
      if (cDate!.isAfter(untilDate)) return null;
    }

    // Apply during filter
    // Skip this check for expressions that handle during internally (NearestWeekday with direction)
    if (hasDuring &&
        !handlesDuringInternally &&
        !_matchesDuring(cDate!, schedule.during)) {
      // Skip ahead to 1st of next valid during month
      final skipTo = _nextDuringMonth(cDate, schedule.during);
      current = TZDateTime(
        loc,
        skipTo.year,
        skipTo.month,
        skipTo.day,
      ).subtract(const Duration(seconds: 1));
      continue;
    }

    // Apply except filter
    if (hasExceptions && parsedExceptions.isExcepted(cDate!)) {
      final nextDay = cDate.add(const Duration(days: 1));
      current = TZDateTime(
        loc,
        nextDay.year,
        nextDay.month,
        nextDay.day,
      ).subtract(const Duration(seconds: 1));
      continue;
    }

    return candidate;
  }

  return null;
}

TZDateTime? _nextExpr(
  ScheduleExpr expr,
  Location loc,
  String? anchor,
  TZDateTime now, {
  List<MonthName> during = const [],
}) {
  return switch (expr) {
    DayRepeat() => _nextDayRepeat(
      expr.interval,
      expr.days,
      expr.times,
      loc,
      anchor,
      now,
    ),
    IntervalRepeat() => _nextIntervalRepeat(
      expr.interval,
      expr.unit,
      expr.from,
      expr.to,
      expr.dayFilter,
      loc,
      now,
    ),
    WeekRepeat() => _nextWeekRepeat(
      expr.interval,
      expr.days,
      expr.times,
      loc,
      anchor,
      now,
    ),
    MonthRepeat() => _nextMonthRepeat(
      expr.interval,
      expr.target,
      expr.times,
      loc,
      anchor,
      now,
      during: during,
    ),
    OrdinalRepeat() => _nextOrdinalRepeat(
      expr.interval,
      expr.ordinal,
      expr.day,
      expr.times,
      loc,
      anchor,
      now,
    ),
    SingleDate() => _nextSingleDate(expr.date, expr.times, loc, now),
    YearRepeat() => _nextYearRepeat(
      expr.interval,
      expr.target,
      expr.times,
      loc,
      anchor,
      now,
    ),
  };
}

List<TZDateTime> nextNFrom(ScheduleData schedule, TZDateTime now, int n) {
  final results = <TZDateTime>[];
  var current = now;
  for (var i = 0; i < n; i++) {
    final next = nextFrom(schedule, current);
    if (next == null) break;
    current = next.add(const Duration(minutes: 1));
    results.add(next);
  }
  return results;
}

TZDateTime? previousFrom(ScheduleData schedule, TZDateTime now) {
  final tzName = _resolveTz(schedule.timezone);
  final loc = _getLocation(tzName);

  final anchorDate = schedule.anchor != null
      ? _parseIsoDateUtc(schedule.anchor!)
      : null;

  final parsedExceptions = _ParsedExceptions.from(schedule.except);
  final hasExceptions = schedule.except.isNotEmpty;
  final hasDuring = schedule.during.isNotEmpty;

  // Handle until clause - if now is after until, search from end of until date
  var searchFrom = now;
  if (schedule.until != null) {
    final untilDate = _resolveUntil(schedule.until!, now);
    final nowDate = DateTime.utc(now.year, now.month, now.day);
    if (nowDate.isAfter(untilDate)) {
      final nextDay = untilDate.add(const Duration(days: 1));
      searchFrom = TZDateTime(loc, nextDay.year, nextDay.month, nextDay.day);
    }
  }

  for (var i = 0; i < 1000; i++) {
    final candidate = _prevExpr(
      schedule.expr,
      loc,
      schedule.anchor,
      searchFrom,
    );

    if (candidate == null) return null;

    // Convert to target tz for filter checks
    final cInTz = TZDateTime.from(candidate, loc);
    final cDate = DateTime.utc(cInTz.year, cInTz.month, cInTz.day);

    // Check if before anchor
    if (anchorDate != null && cDate.isBefore(anchorDate)) {
      return null;
    }

    // Check until date - should not return occurrences after until
    if (schedule.until != null) {
      final untilDate = _resolveUntil(schedule.until!, now);
      if (cDate.isAfter(untilDate)) {
        searchFrom = candidate;
        continue;
      }
    }

    // Apply except filter
    if (hasExceptions && parsedExceptions.isExcepted(cDate)) {
      searchFrom = candidate;
      continue;
    }

    // Apply during filter
    if (hasDuring && !_matchesDuring(cDate, schedule.during)) {
      final prevMonth = _prevDuringMonth(cDate, schedule.during);
      if (prevMonth == null) return null;
      final nextDay = prevMonth.add(const Duration(days: 1));
      searchFrom = TZDateTime(loc, nextDay.year, nextDay.month, nextDay.day);
      continue;
    }

    return candidate;
  }

  return null;
}

TZDateTime? _prevExpr(
  ScheduleExpr expr,
  Location loc,
  String? anchor,
  TZDateTime now,
) {
  return switch (expr) {
    DayRepeat() => _prevDayRepeat(
      expr.interval,
      expr.days,
      expr.times,
      loc,
      anchor,
      now,
    ),
    IntervalRepeat() => _prevIntervalRepeat(
      expr.interval,
      expr.unit,
      expr.from,
      expr.to,
      expr.dayFilter,
      loc,
      now,
    ),
    WeekRepeat() => _prevWeekRepeat(
      expr.interval,
      expr.days,
      expr.times,
      loc,
      anchor,
      now,
    ),
    MonthRepeat() => _prevMonthRepeat(
      expr.interval,
      expr.target,
      expr.times,
      loc,
      anchor,
      now,
    ),
    OrdinalRepeat() => _prevOrdinalRepeat(
      expr.interval,
      expr.ordinal,
      expr.day,
      expr.times,
      loc,
      anchor,
      now,
    ),
    SingleDate() => _prevSingleDate(expr.date, expr.times, loc, now),
    YearRepeat() => _prevYearRepeat(
      expr.interval,
      expr.target,
      expr.times,
      loc,
      anchor,
      now,
    ),
  };
}

TZDateTime? _prevDayRepeat(
  int interval,
  DayFilter days,
  List<TimeOfDay> times,
  Location loc,
  String? anchor,
  TZDateTime now,
) {
  final nowInTz = TZDateTime.from(now, loc);
  var date = DateTime.utc(nowInTz.year, nowInTz.month, nowInTz.day);
  final anchorDate = anchor != null ? _parseIsoDateUtc(anchor) : _epochDate;

  for (var i = 0; i < 1000; i++) {
    if (interval > 1) {
      final offset = _daysBetween(anchorDate, date);
      final mod = _euclideanMod(offset, interval);
      if (mod != 0) {
        date = date.subtract(Duration(days: mod));
        continue;
      }
    }

    if (_matchesDayFilter(date, days)) {
      final candidate = _latestPastAtTimes(date, times, loc, now);
      if (candidate != null) return candidate;
    }

    date = date.subtract(Duration(days: interval > 1 ? interval : 1));
  }

  return null;
}

TZDateTime? _prevIntervalRepeat(
  int interval,
  IntervalUnit unit,
  TimeOfDay from,
  TimeOfDay to,
  DayFilter? dayFilter,
  Location loc,
  TZDateTime now,
) {
  final nowInTz = TZDateTime.from(now, loc);
  var date = DateTime.utc(nowInTz.year, nowInTz.month, nowInTz.day);
  final stepMinutes = unit == IntervalUnit.min ? interval : interval * 60;
  final fromMinutes = from.hour * 60 + from.minute;
  final toMinutes = to.hour * 60 + to.minute;

  for (var d = 0; d < 1000; d++) {
    if (dayFilter != null && !_matchesDayFilter(date, dayFilter)) {
      date = date.subtract(const Duration(days: 1));
      continue;
    }

    // Build list of times in window
    final windowTimes = <int>[];
    for (var m = fromMinutes; m <= toMinutes; m += stepMinutes) {
      windowTimes.add(m);
    }

    // Search backwards through window
    for (var j = windowTimes.length - 1; j >= 0; j--) {
      final m = windowTimes[j];
      final h = m ~/ 60;
      final min = m % 60;
      final candidate = _atTimeOnDate(date, h, min, loc);

      if (candidate.isBefore(now)) {
        return candidate;
      }
    }

    date = date.subtract(const Duration(days: 1));
  }

  return null;
}

TZDateTime? _prevWeekRepeat(
  int interval,
  List<Weekday> days,
  List<TimeOfDay> times,
  Location loc,
  String? anchor,
  TZDateTime now,
) {
  final nowInTz = TZDateTime.from(now, loc);
  final anchorDate = anchor != null ? _parseIsoDateUtc(anchor) : _epochMonday;

  final date = DateTime.utc(nowInTz.year, nowInTz.month, nowInTz.day);

  // Sort target DOWs in descending order for backwards search
  final sortedDays = [...days]..sort((a, b) => b.number.compareTo(a.number));

  // Find Monday of current week and Monday of anchor week
  final dowOffset = date.weekday - 1;
  var currentMonday = date.subtract(Duration(days: dowOffset));

  final anchorDowOffset = anchorDate.weekday - 1;
  final anchorMonday = anchorDate.subtract(Duration(days: anchorDowOffset));

  for (var i = 0; i < 54; i++) {
    final weeks = _weeksBetween(anchorMonday, currentMonday);

    if (weeks < 0) {
      return null;
    }

    if (weeks % interval == 0) {
      for (final wd in sortedDays) {
        final dayOffset = wd.number - 1;
        final targetDate = currentMonday.add(Duration(days: dayOffset));
        final candidate = _latestPastAtTimes(targetDate, times, loc, now);
        if (candidate != null) return candidate;
      }
    }

    final remainder = weeks % interval;
    final skipWeeks = remainder == 0 ? interval : remainder;
    currentMonday = currentMonday.subtract(Duration(days: skipWeeks * 7));
  }

  return null;
}

TZDateTime? _prevMonthRepeat(
  int interval,
  MonthTarget target,
  List<TimeOfDay> times,
  Location loc,
  String? anchor,
  TZDateTime now,
) {
  final nowInTz = TZDateTime.from(now, loc);
  var year = nowInTz.year;
  var month = nowInTz.month;

  final anchorDate = anchor != null ? _parseIsoDateUtc(anchor) : _epochDate;
  final maxIter = interval > 1 ? 24 * interval : 24;

  for (var i = 0; i < maxIter; i++) {
    if (interval > 1) {
      final cur = DateTime.utc(year, month, 1);
      final monthOffset = _monthsBetweenYM(anchorDate, cur);
      if (monthOffset < 0 || _euclideanMod(monthOffset, interval) != 0) {
        month--;
        if (month < 1) {
          month = 12;
          year--;
        }
        continue;
      }
    }

    final dateCandidates = <DateTime>[];

    if (target is DaysTarget) {
      final expanded = expandMonthTarget(target);
      for (final dayNum in expanded.toList()..sort((a, b) => b - a)) {
        final last = _lastDayOfMonth(year, month);
        if (dayNum <= last.day) {
          final d = DateTime.utc(year, month, dayNum);
          if (d.month == month && d.day == dayNum) {
            dateCandidates.add(d);
          }
        }
      }
    } else if (target is LastDayTarget) {
      dateCandidates.add(_lastDayOfMonth(year, month));
    } else if (target is NearestWeekdayTarget) {
      final d = _nearestWeekday(year, month, target.day, target.direction);
      if (d != null) {
        dateCandidates.add(d);
      }
    } else {
      dateCandidates.add(_lastWeekdayOfMonth(year, month));
    }

    // Sort in descending order for backwards search
    dateCandidates.sort((a, b) => b.compareTo(a));

    for (final date in dateCandidates) {
      final candidate = _latestPastAtTimes(date, times, loc, now);
      if (candidate != null) return candidate;
    }

    month--;
    if (month < 1) {
      month = 12;
      year--;
    }
  }

  return null;
}

TZDateTime? _prevOrdinalRepeat(
  int interval,
  OrdinalPosition ordinal,
  Weekday day,
  List<TimeOfDay> times,
  Location loc,
  String? anchor,
  TZDateTime now,
) {
  final nowInTz = TZDateTime.from(now, loc);
  var year = nowInTz.year;
  var month = nowInTz.month;

  final anchorDate = anchor != null ? _parseIsoDateUtc(anchor) : _epochDate;
  final maxIter = interval > 1 ? 24 * interval : 24;

  for (var i = 0; i < maxIter; i++) {
    if (interval > 1) {
      final cur = DateTime.utc(year, month, 1);
      final monthOffset = _monthsBetweenYM(anchorDate, cur);
      if (monthOffset < 0 || _euclideanMod(monthOffset, interval) != 0) {
        month--;
        if (month < 1) {
          month = 12;
          year--;
        }
        continue;
      }
    }

    DateTime? targetDate;
    if (ordinal == OrdinalPosition.last) {
      targetDate = _lastWeekdayInMonth(year, month, day);
    } else {
      targetDate = _nthWeekdayOfMonth(year, month, day, ordinal.toN);
    }

    if (targetDate != null) {
      final candidate = _latestPastAtTimes(targetDate, times, loc, now);
      if (candidate != null) return candidate;
    }

    month--;
    if (month < 1) {
      month = 12;
      year--;
    }
  }

  return null;
}

TZDateTime? _prevSingleDate(
  DateSpec dateSpec,
  List<TimeOfDay> times,
  Location loc,
  TZDateTime now,
) {
  final nowInTz = TZDateTime.from(now, loc);

  if (dateSpec is IsoDate) {
    final date = _parseIsoDateUtc(dateSpec.date);
    return _latestPastAtTimes(date, times, loc, now);
  }

  if (dateSpec is NamedDate) {
    final startYear = nowInTz.year;
    for (var y = 0; y < 8; y++) {
      final year = startYear - y;
      try {
        final date = DateTime.utc(year, dateSpec.month.number, dateSpec.day);
        if (date.month == dateSpec.month.number && date.day == dateSpec.day) {
          final candidate = _latestPastAtTimes(date, times, loc, now);
          if (candidate != null) return candidate;
        }
      } on Exception catch (_) {
        // Invalid date construction, skip
      }
    }
    return null;
  }

  return null;
}

TZDateTime? _prevYearRepeat(
  int interval,
  YearTarget target,
  List<TimeOfDay> times,
  Location loc,
  String? anchor,
  TZDateTime now,
) {
  final nowInTz = TZDateTime.from(now, loc);
  final startYear = nowInTz.year;
  final anchorYear = anchor != null
      ? _parseIsoDateUtc(anchor).year
      : _epochDate.year;

  final maxIter = interval > 1 ? 8 * interval : 8;

  for (var y = 0; y < maxIter; y++) {
    final year = startYear - y;

    if (interval > 1) {
      final yearOffset = year - anchorYear;
      if (yearOffset < 0 || _euclideanMod(yearOffset, interval) != 0) {
        continue;
      }
    }

    DateTime? targetDate;

    switch (target) {
      case DateTarget(month: final month, day: final day):
        try {
          final d = DateTime.utc(year, month.number, day);
          if (d.month == month.number && d.day == day) {
            targetDate = d;
          } else {
            continue;
          }
        } on Exception catch (_) {
          continue;
        }
      case OrdinalWeekdayTarget(
        ordinal: final ordinal,
        weekday: final weekday,
        month: final month,
      ):
        if (ordinal == OrdinalPosition.last) {
          targetDate = _lastWeekdayInMonth(year, month.number, weekday);
        } else {
          targetDate = _nthWeekdayOfMonth(
            year,
            month.number,
            weekday,
            ordinal.toN,
          );
        }
      case DayOfMonthTarget(day: final day, month: final month):
        try {
          final d = DateTime.utc(year, month.number, day);
          if (d.month == month.number && d.day == day) {
            targetDate = d;
          } else {
            continue;
          }
        } on Exception catch (_) {
          continue;
        }
      case LastWeekdayYearTarget(month: final month):
        targetDate = _lastWeekdayOfMonth(year, month.number);
    }

    if (targetDate != null) {
      final candidate = _latestPastAtTimes(targetDate, times, loc, now);
      if (candidate != null) return candidate;
    }
  }

  return null;
}

bool matches(ScheduleData schedule, TZDateTime datetime) {
  final tzName = _resolveTz(schedule.timezone);
  final loc = _getLocation(tzName);
  final zdt = TZDateTime.from(datetime, loc);
  final date = DateTime.utc(zdt.year, zdt.month, zdt.day);

  if (!_matchesDuring(date, schedule.during)) return false;
  if (_isExcepted(date, schedule.except)) return false;

  if (schedule.until != null) {
    final untilDate = _resolveUntil(schedule.until!, datetime);
    if (date.isAfter(untilDate)) return false;
  }

  // DST-aware time matching: a time matches if either the wall-clock matches
  // directly, or the scheduled time falls in a DST gap and resolves to the
  // candidate's instant (e.g., scheduled 2:00 AM during spring-forward → 3:00 AM).
  bool timeMatchesWithDst(List<TimeOfDay> times) => times.any((tod) {
    if (zdt.hour == tod.hour && zdt.minute == tod.minute) return true;
    final resolved = _atTimeOnDate(date, tod.hour, tod.minute, loc);
    return resolved.millisecondsSinceEpoch == datetime.millisecondsSinceEpoch;
  });

  switch (schedule.expr) {
    case DayRepeat(
      interval: final interval,
      days: final days,
      times: final times,
    ):
      if (!_matchesDayFilter(date, days)) return false;
      if (!timeMatchesWithDst(times)) return false;
      if (interval > 1) {
        final anchorDate = schedule.anchor != null
            ? _parseIsoDateUtc(schedule.anchor!)
            : _epochDate;
        final dayOffset = _daysBetween(anchorDate, date);
        return dayOffset >= 0 && dayOffset % interval == 0;
      }
      return true;

    case IntervalRepeat(
      interval: final interval,
      unit: final unit,
      from: final from,
      to: final to,
      dayFilter: final dayFilter,
    ):
      if (dayFilter != null && !_matchesDayFilter(date, dayFilter)) {
        return false;
      }
      final fromMinutes = from.hour * 60 + from.minute;
      final toMinutes = to.hour * 60 + to.minute;
      final currentMinutes = zdt.hour * 60 + zdt.minute;
      if (currentMinutes < fromMinutes || currentMinutes > toMinutes) {
        return false;
      }
      final diff = currentMinutes - fromMinutes;
      final step = unit == IntervalUnit.min ? interval : interval * 60;
      return diff >= 0 && diff % step == 0;

    case WeekRepeat(
      interval: final interval,
      days: final days,
      times: final times,
    ):
      final dow = _dayOfWeek(date);
      if (!days.any((d) => d.number == dow)) return false;
      if (!timeMatchesWithDst(times)) return false;
      final anchorDate = schedule.anchor != null
          ? _parseIsoDateUtc(schedule.anchor!)
          : _epochMonday;
      final weeks = _weeksBetween(anchorDate, date);
      return weeks >= 0 && weeks % interval == 0;

    case MonthRepeat(
      interval: final interval,
      target: final target,
      times: final times,
    ):
      if (!timeMatchesWithDst(times)) return false;
      if (interval > 1) {
        final anchorDate = schedule.anchor != null
            ? _parseIsoDateUtc(schedule.anchor!)
            : _epochDate;
        final monthOffset = _monthsBetweenYM(anchorDate, date);
        if (monthOffset < 0 || monthOffset % interval != 0) return false;
      }
      if (target is DaysTarget) {
        final expanded = expandMonthTarget(target);
        return expanded.contains(date.day);
      }
      if (target is LastDayTarget) {
        final last = _lastDayOfMonth(date.year, date.month);
        return date.day == last.day;
      }
      if (target is NearestWeekdayTarget) {
        final targetDate = _nearestWeekday(
          date.year,
          date.month,
          target.day,
          target.direction,
        );
        if (targetDate == null) return false;
        return date.year == targetDate.year &&
            date.month == targetDate.month &&
            date.day == targetDate.day;
      }
      final lastWd = _lastWeekdayOfMonth(date.year, date.month);
      return date.day == lastWd.day;

    case OrdinalRepeat(
      interval: final interval,
      ordinal: final ordinal,
      day: final day,
      times: final times,
    ):
      if (!timeMatchesWithDst(times)) return false;
      if (interval > 1) {
        final anchorDate = schedule.anchor != null
            ? _parseIsoDateUtc(schedule.anchor!)
            : _epochDate;
        final monthOffset = _monthsBetweenYM(anchorDate, date);
        if (monthOffset < 0 || monthOffset % interval != 0) return false;
      }
      DateTime? targetDate;
      if (ordinal == OrdinalPosition.last) {
        targetDate = _lastWeekdayInMonth(date.year, date.month, day);
      } else {
        targetDate = _nthWeekdayOfMonth(
          date.year,
          date.month,
          day,
          ordinal.toN,
        );
      }
      if (targetDate == null) return false;
      return date.day == targetDate.day;

    case SingleDate(date: final dateSpec, times: final times):
      if (!timeMatchesWithDst(times)) return false;
      if (dateSpec is IsoDate) {
        final target = _parseIsoDateUtc(dateSpec.date);
        return date.year == target.year &&
            date.month == target.month &&
            date.day == target.day;
      }
      if (dateSpec is NamedDate) {
        return date.month == dateSpec.month.number && date.day == dateSpec.day;
      }
      return false;

    case YearRepeat(
      interval: final interval,
      target: final target,
      times: final times,
    ):
      if (!timeMatchesWithDst(times)) return false;
      if (interval > 1) {
        final anchorYear = schedule.anchor != null
            ? _parseIsoDateUtc(schedule.anchor!).year
            : _epochDate.year;
        final yearOffset = date.year - anchorYear;
        if (yearOffset < 0 || yearOffset % interval != 0) return false;
      }
      return _matchesYearTarget(target, date);
  }
}

bool _matchesYearTarget(YearTarget target, DateTime date) {
  switch (target) {
    case DateTarget(month: final month, day: final day):
      return date.month == month.number && date.day == day;
    case OrdinalWeekdayTarget(
      ordinal: final ordinal,
      weekday: final weekday,
      month: final month,
    ):
      if (date.month != month.number) return false;
      DateTime? targetDate;
      if (ordinal == OrdinalPosition.last) {
        targetDate = _lastWeekdayInMonth(date.year, date.month, weekday);
      } else {
        targetDate = _nthWeekdayOfMonth(
          date.year,
          date.month,
          weekday,
          ordinal.toN,
        );
      }
      if (targetDate == null) return false;
      return date.day == targetDate.day;
    case DayOfMonthTarget(day: final day, month: final month):
      return date.month == month.number && date.day == day;
    case LastWeekdayYearTarget(month: final month):
      if (date.month != month.number) return false;
      final lwd = _lastWeekdayOfMonth(date.year, date.month);
      return date.day == lwd.day;
  }
}

// --- Per-variant next functions ---

TZDateTime? _nextDayRepeat(
  int interval,
  DayFilter days,
  List<TimeOfDay> times,
  Location loc,
  String? anchor,
  TZDateTime now,
) {
  final nowInTz = TZDateTime.from(now, loc);
  var date = DateTime.utc(nowInTz.year, nowInTz.month, nowInTz.day);

  if (interval <= 1) {
    // Original behavior for interval=1
    if (_matchesDayFilter(date, days)) {
      final candidate = _earliestFutureAtTimes(date, times, loc, now);
      if (candidate != null) return candidate;
    }

    for (var i = 0; i < 8; i++) {
      date = date.add(const Duration(days: 1));
      if (_matchesDayFilter(date, days)) {
        final candidate = _earliestFutureAtTimes(date, times, loc, now);
        if (candidate != null) return candidate;
      }
    }

    return null;
  }

  // Interval > 1: day intervals only apply to DayFilter::Every
  final anchorDate = anchor != null ? _parseIsoDateUtc(anchor) : _epochDate;

  // Find the next aligned day >= today
  final offset = _daysBetween(anchorDate, date);
  final alignedRemainder = _euclideanMod(offset, interval);
  var cur = alignedRemainder == 0
      ? date
      : date.add(Duration(days: interval - alignedRemainder));

  for (var i = 0; i < 400; i++) {
    final candidate = _earliestFutureAtTimes(cur, times, loc, now);
    if (candidate != null) return candidate;
    cur = cur.add(Duration(days: interval));
  }

  return null;
}

TZDateTime? _nextIntervalRepeat(
  int interval,
  IntervalUnit unit,
  TimeOfDay from,
  TimeOfDay to,
  DayFilter? dayFilter,
  Location loc,
  TZDateTime now,
) {
  final nowInTz = TZDateTime.from(now, loc);
  final stepMinutes = unit == IntervalUnit.min ? interval : interval * 60;
  final fromMinutes = from.hour * 60 + from.minute;
  final toMinutes = to.hour * 60 + to.minute;

  var date = DateTime.utc(nowInTz.year, nowInTz.month, nowInTz.day);

  for (var d = 0; d < 400; d++) {
    if (dayFilter != null && !_matchesDayFilter(date, dayFilter)) {
      date = date.add(const Duration(days: 1));
      continue;
    }

    final sameDay =
        date.year == nowInTz.year &&
        date.month == nowInTz.month &&
        date.day == nowInTz.day;
    final nowMinutes = sameDay ? nowInTz.hour * 60 + nowInTz.minute : -1;

    int nextSlot;
    if (nowMinutes < fromMinutes) {
      nextSlot = fromMinutes;
    } else {
      final elapsed = nowMinutes - fromMinutes;
      nextSlot = fromMinutes + (elapsed ~/ stepMinutes + 1) * stepMinutes;
    }

    if (nextSlot <= toMinutes) {
      final h = nextSlot ~/ 60;
      final m = nextSlot % 60;
      final candidate = _atTimeOnDate(date, h, m, loc);
      if (candidate.isAfter(now)) {
        return candidate;
      }
    }

    date = date.add(const Duration(days: 1));
  }

  return null;
}

TZDateTime? _nextWeekRepeat(
  int interval,
  List<Weekday> days,
  List<TimeOfDay> times,
  Location loc,
  String? anchor,
  TZDateTime now,
) {
  final nowInTz = TZDateTime.from(now, loc);
  final anchorDate = anchor != null ? _parseIsoDateUtc(anchor) : _epochMonday;

  final date = DateTime.utc(nowInTz.year, nowInTz.month, nowInTz.day);

  // Sort target DOWs by number for earliest-first matching
  final sortedDays = [...days]..sort((a, b) => a.number.compareTo(b.number));

  // Find Monday of current week and Monday of anchor week
  final dowOffset = date.weekday - 1;
  var currentMonday = date.subtract(Duration(days: dowOffset));

  final anchorDowOffset = anchorDate.weekday - 1;
  final anchorMonday = anchorDate.subtract(Duration(days: anchorDowOffset));

  // Loop up to 54 iterations (covers >1 year for any interval)
  for (var i = 0; i < 54; i++) {
    final weeks = _weeksBetween(anchorMonday, currentMonday);

    // Skip weeks before anchor - anchor Monday is always the first aligned week
    if (weeks < 0) {
      currentMonday = anchorMonday;
      continue;
    }

    if (weeks % interval == 0) {
      // Aligned week — try each target DOW
      for (final wd in sortedDays) {
        final dayOffset = wd.number - 1;
        final targetDate = currentMonday.add(Duration(days: dayOffset));
        final candidate = _earliestFutureAtTimes(targetDate, times, loc, now);
        if (candidate != null) return candidate;
      }
    }

    // Skip to next aligned week
    final remainder = weeks % interval;
    final skipWeeks = remainder == 0 ? interval : interval - remainder;
    currentMonday = currentMonday.add(Duration(days: skipWeeks * 7));
  }

  return null;
}

TZDateTime? _nextMonthRepeat(
  int interval,
  MonthTarget target,
  List<TimeOfDay> times,
  Location loc,
  String? anchor,
  TZDateTime now, {
  List<MonthName> during = const [],
}) {
  final nowInTz = TZDateTime.from(now, loc);
  var year = nowInTz.year;
  var month = nowInTz.month;

  final anchorDate = anchor != null ? _parseIsoDateUtc(anchor) : _epochDate;
  final maxIter = interval > 1 ? 24 * interval : 24;

  // For NearestWeekday with direction, we need to apply the during filter here
  // because the result can cross month boundaries
  final applyDuringFilter =
      during.isNotEmpty &&
      target is NearestWeekdayTarget &&
      target.direction != null;

  for (var i = 0; i < maxIter; i++) {
    // Check during filter for NearestWeekday with direction
    if (applyDuringFilter && !during.any((mn) => mn.number == month)) {
      month++;
      if (month > 12) {
        month = 1;
        year++;
      }
      continue;
    }

    // Check interval alignment
    if (interval > 1) {
      final cur = DateTime.utc(year, month, 1);
      final monthOffset = _monthsBetweenYM(anchorDate, cur);
      if (monthOffset < 0 || _euclideanMod(monthOffset, interval) != 0) {
        month++;
        if (month > 12) {
          month = 1;
          year++;
        }
        continue;
      }
    }

    final dateCandidates = <DateTime>[];

    if (target is DaysTarget) {
      final expanded = expandMonthTarget(target);
      for (final dayNum in expanded) {
        final last = _lastDayOfMonth(year, month);
        if (dayNum <= last.day) {
          final d = DateTime.utc(year, month, dayNum);
          if (d.month == month && d.day == dayNum) {
            dateCandidates.add(d);
          }
        }
      }
    } else if (target is LastDayTarget) {
      dateCandidates.add(_lastDayOfMonth(year, month));
    } else if (target is NearestWeekdayTarget) {
      final d = _nearestWeekday(year, month, target.day, target.direction);
      if (d != null) {
        dateCandidates.add(d);
      }
    } else {
      dateCandidates.add(_lastWeekdayOfMonth(year, month));
    }

    TZDateTime? best;
    for (final date in dateCandidates) {
      final candidate = _earliestFutureAtTimes(date, times, loc, now);
      if (candidate != null) {
        if (best == null || candidate.isBefore(best)) {
          best = candidate;
        }
      }
    }
    if (best != null) return best;

    month++;
    if (month > 12) {
      month = 1;
      year++;
    }
  }

  return null;
}

TZDateTime? _nextOrdinalRepeat(
  int interval,
  OrdinalPosition ordinal,
  Weekday day,
  List<TimeOfDay> times,
  Location loc,
  String? anchor,
  TZDateTime now,
) {
  final nowInTz = TZDateTime.from(now, loc);
  var year = nowInTz.year;
  var month = nowInTz.month;

  final anchorDate = anchor != null ? _parseIsoDateUtc(anchor) : _epochDate;
  final maxIter = interval > 1 ? 24 * interval : 24;

  for (var i = 0; i < maxIter; i++) {
    // Check interval alignment
    if (interval > 1) {
      final cur = DateTime.utc(year, month, 1);
      final monthOffset = _monthsBetweenYM(anchorDate, cur);
      if (monthOffset < 0 || _euclideanMod(monthOffset, interval) != 0) {
        month++;
        if (month > 12) {
          month = 1;
          year++;
        }
        continue;
      }
    }

    DateTime? targetDate;
    if (ordinal == OrdinalPosition.last) {
      targetDate = _lastWeekdayInMonth(year, month, day);
    } else {
      targetDate = _nthWeekdayOfMonth(year, month, day, ordinal.toN);
    }

    if (targetDate != null) {
      final candidate = _earliestFutureAtTimes(targetDate, times, loc, now);
      if (candidate != null) return candidate;
    }

    month++;
    if (month > 12) {
      month = 1;
      year++;
    }
  }

  return null;
}

TZDateTime? _nextSingleDate(
  DateSpec dateSpec,
  List<TimeOfDay> times,
  Location loc,
  TZDateTime now,
) {
  final nowInTz = TZDateTime.from(now, loc);

  if (dateSpec is IsoDate) {
    final date = _parseIsoDateUtc(dateSpec.date);
    return _earliestFutureAtTimes(date, times, loc, now);
  }

  if (dateSpec is NamedDate) {
    final startYear = nowInTz.year;
    for (var y = 0; y < 8; y++) {
      final year = startYear + y;
      try {
        final date = DateTime.utc(year, dateSpec.month.number, dateSpec.day);
        // Verify date is valid (no overflow)
        if (date.month == dateSpec.month.number && date.day == dateSpec.day) {
          final candidate = _earliestFutureAtTimes(date, times, loc, now);
          if (candidate != null) return candidate;
        }
      } on Exception catch (_) {
        // Invalid date construction, skip to next year
      }
    }
    return null;
  }

  return null;
}

TZDateTime? _nextYearRepeat(
  int interval,
  YearTarget target,
  List<TimeOfDay> times,
  Location loc,
  String? anchor,
  TZDateTime now,
) {
  final nowInTz = TZDateTime.from(now, loc);
  final startYear = nowInTz.year;
  final anchorYear = anchor != null
      ? _parseIsoDateUtc(anchor).year
      : _epochDate.year;

  final maxIter = interval > 1 ? 8 * interval : 8;

  for (var y = 0; y < maxIter; y++) {
    final year = startYear + y;

    // Check interval alignment
    if (interval > 1) {
      final yearOffset = year - anchorYear;
      if (yearOffset < 0 || _euclideanMod(yearOffset, interval) != 0) {
        continue;
      }
    }

    DateTime? targetDate;

    switch (target) {
      case DateTarget(month: final month, day: final day):
        try {
          final d = DateTime.utc(year, month.number, day);
          if (d.month == month.number && d.day == day) {
            targetDate = d;
          } else {
            continue;
          }
        } on Exception catch (_) {
          continue;
        }
      case OrdinalWeekdayTarget(
        ordinal: final ordinal,
        weekday: final weekday,
        month: final month,
      ):
        if (ordinal == OrdinalPosition.last) {
          targetDate = _lastWeekdayInMonth(year, month.number, weekday);
        } else {
          targetDate = _nthWeekdayOfMonth(
            year,
            month.number,
            weekday,
            ordinal.toN,
          );
        }
      case DayOfMonthTarget(day: final day, month: final month):
        try {
          final d = DateTime.utc(year, month.number, day);
          if (d.month == month.number && d.day == day) {
            targetDate = d;
          } else {
            continue;
          }
        } on Exception catch (_) {
          continue;
        }
      case LastWeekdayYearTarget(month: final month):
        targetDate = _lastWeekdayOfMonth(year, month.number);
    }

    if (targetDate != null) {
      final candidate = _earliestFutureAtTimes(targetDate, times, loc, now);
      if (candidate != null) return candidate;
    }
  }

  return null;
}

// --- Iterator functions ---

/// Returns a lazy iterable of occurrences starting after [from].
/// The iterator is unbounded for repeating schedules (will iterate forever unless limited),
/// but respects the `until` clause if specified in the schedule.
Iterable<TZDateTime> occurrences(ScheduleData schedule, TZDateTime from) sync* {
  var current = from;
  while (true) {
    final next = nextFrom(schedule, current);
    if (next == null) return;
    // Advance cursor by 1 minute to avoid returning same occurrence
    current = next.add(const Duration(minutes: 1));
    yield next;
  }
}

/// Returns a bounded iterable of occurrences where `from < occurrence <= to`.
/// The iterator yields occurrences strictly after [from] and up to and including [to].
Iterable<TZDateTime> between(
  ScheduleData schedule,
  TZDateTime from,
  TZDateTime to,
) sync* {
  for (final dt in occurrences(schedule, from)) {
    if (dt.isAfter(to)) return;
    yield dt;
  }
}
