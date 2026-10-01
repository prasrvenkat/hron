import 'ast.dart';
import 'error.dart';

String toCron(ScheduleData schedule) {
  if (schedule.except.isNotEmpty) {
    throw HronError.cron(
      'not expressible as cron (except clauses not supported)',
    );
  }
  if (schedule.until != null) {
    throw HronError.cron(
      'not expressible as cron (until clauses not supported)',
    );
  }
  if (schedule.during.isNotEmpty) {
    throw HronError.cron(
      'not expressible as cron (during clauses not supported)',
    );
  }

  final expr = schedule.expr;

  switch (expr) {
    case DayRepeat(
      interval: final interval,
      days: final days,
      times: final times,
    ):
      if (interval > 1) {
        throw HronError.cron(
          'not expressible as cron (multi-day intervals not supported)',
        );
      }
      if (times.length != 1) {
        throw HronError.cron(
          'not expressible as cron (multiple times not supported)',
        );
      }
      final time = times[0];
      final dow = _dayFilterToCronDow(days);
      return '${time.minute} ${time.hour} * * $dow';

    case IntervalRepeat(
      interval: final interval,
      unit: final unit,
      from: final from,
      to: final to,
      dayFilter: final dayFilter,
    ):
      final fullDay =
          from.hour == 0 &&
          from.minute == 0 &&
          to.hour == 23 &&
          to.minute == 59;
      if (!fullDay) {
        throw HronError.cron(
          'not expressible as cron (partial-day interval windows not supported)',
        );
      }
      if (dayFilter != null) {
        throw HronError.cron(
          'not expressible as cron (interval with day filter not supported)',
        );
      }
      if (unit == IntervalUnit.min) {
        if (60 % interval != 0) {
          throw HronError.cron(
            'not expressible as cron (*/$interval breaks at hour boundaries)',
          );
        }
        return '*/$interval * * * *';
      }
      return '0 */$interval * * *';

    case WeekRepeat():
      throw HronError.cron(
        'not expressible as cron (multi-week intervals not supported)',
      );

    case MonthRepeat(
      interval: final interval,
      target: final target,
      times: final times,
    ):
      if (interval > 1) {
        throw HronError.cron(
          'not expressible as cron (multi-month intervals not supported)',
        );
      }
      if (times.length != 1) {
        throw HronError.cron(
          'not expressible as cron (multiple times not supported)',
        );
      }
      final time = times[0];
      if (target is DaysTarget) {
        final expanded = target.specs.expand((s) {
          if (s is SingleDay) return [s.day];
          final r = s as DayRange;
          return [for (var d = r.start; d <= r.end; d++) d];
        }).toList();
        final dom = expanded.join(',');
        return '${time.minute} ${time.hour} $dom * *';
      }
      if (target is LastDayTarget) {
        throw HronError.cron(
          'not expressible as cron (last day of month not supported)',
        );
      }
      if (target is NearestWeekdayTarget) {
        if (target.direction != null) {
          throw HronError.cron(
            'not expressible as cron (directional nearest weekday not supported)',
          );
        }
        return '${time.minute} ${time.hour} ${target.day}W * *';
      }
      if (target is OrdinalWeekdayMonthTarget) {
        throw HronError.cron(
          'not expressible as cron (ordinal weekday of month not supported)',
        );
      }
      throw HronError.cron(
        'not expressible as cron (last weekday of month not supported)',
      );

    case SingleDate():
      throw HronError.cron(
        'not expressible as cron (single dates are not repeating)',
      );

    case YearRepeat():
      throw HronError.cron(
        'not expressible as cron (yearly schedules not supported in 5-field cron)',
      );
  }
}

String _dayFilterToCronDow(DayFilter filter) {
  return switch (filter) {
    EveryDay() => '*',
    WeekdayFilter() => '1-5',
    WeekendFilter() => '0,6',
    SpecificDays(days: final days) => () {
      final nums = days.map((d) => d.cronDow).toList()..sort();
      return nums.join(',');
    }(),
  };
}

ScheduleData fromCron(String cron) {
  final trimmed = cron.trim();

  if (trimmed.startsWith('@')) {
    return _parseCronShortcut(trimmed);
  }

  final fields = trimmed.split(RegExp(r'\s+'));
  if (fields.length != 5) {
    throw HronError.cron('expected 5 cron fields, got ${fields.length}');
  }

  final minuteField = fields[0];
  final hourField = fields[1];
  var domField = fields[2];
  final monthField = fields[3];
  var dowField = fields[4];

  if (domField == '?') domField = '*';
  if (dowField == '?') dowField = '*';

  final during = _parseMonthField(monthField);

  final nthResult = _tryParseNthWeekday(
    minuteField,
    hourField,
    domField,
    dowField,
    during,
  );
  if (nthResult != null) return nthResult;

  final lastDayResult = _tryParseLastDay(
    minuteField,
    hourField,
    domField,
    dowField,
    during,
  );
  if (lastDayResult != null) return lastDayResult;

  if (domField.endsWith('W') && domField != 'LW') {
    final nearestWeekdayResult = _tryParseNearestWeekday(
      minuteField,
      hourField,
      domField,
      dowField,
      during,
    );
    if (nearestWeekdayResult != null) return nearestWeekdayResult;
  }

  final intervalResult = _tryParseInterval(
    minuteField,
    hourField,
    domField,
    dowField,
    during,
  );
  if (intervalResult != null) return intervalResult;

  final minute = _parseSingleValue(minuteField, 'minute', 0, 59);
  final hour = _parseSingleValue(hourField, 'hour', 0, 23);
  final time = TimeOfDay(hour, minute);

  if (domField != '*' && dowField == '*') {
    final target = _parseDomField(domField);
    final schedule = ScheduleData(MonthRepeat(1, target, [time]));
    schedule.during = during;
    return schedule;
  }

  final days = _parseCronDow(dowField);
  final schedule = ScheduleData(DayRepeat(1, days, [time]));
  schedule.during = during;
  return schedule;
}

ScheduleData _parseCronShortcut(String cron) {
  switch (cron.toLowerCase()) {
    case '@yearly':
    case '@annually':
      return ScheduleData(
        YearRepeat(1, DateTarget(MonthName.jan, 1), [const TimeOfDay(0, 0)]),
      );
    case '@monthly':
      return ScheduleData(
        MonthRepeat(1, DaysTarget([SingleDay(1)]), [const TimeOfDay(0, 0)]),
      );
    case '@weekly':
      return ScheduleData(
        DayRepeat(1, SpecificDays([Weekday.sunday]), [const TimeOfDay(0, 0)]),
      );
    case '@daily':
    case '@midnight':
      return ScheduleData(DayRepeat(1, EveryDay(), [const TimeOfDay(0, 0)]));
    case '@hourly':
      return ScheduleData(
        IntervalRepeat(
          1,
          IntervalUnit.hours,
          const TimeOfDay(0, 0),
          const TimeOfDay(23, 59),
          null,
        ),
      );
    default:
      throw HronError.cron('unknown @ shortcut: $cron');
  }
}

List<MonthName> _parseMonthField(String field) {
  if (field == '*') return [];

  final months = <MonthName>[];
  for (final part in field.split(',')) {
    // Before the range check: a step part like 1-12/3 also contains '-'.
    if (part.contains('/')) {
      final splitIdx = part.indexOf('/');
      final rangePart = part.substring(0, splitIdx);
      final stepStr = part.substring(splitIdx + 1);

      int start, end;
      if (rangePart == '*') {
        start = 1;
        end = 12;
      } else if (rangePart.contains('-')) {
        final dashIdx = rangePart.indexOf('-');
        final startMonth = _parseMonthValue(rangePart.substring(0, dashIdx));
        final endMonth = _parseMonthValue(rangePart.substring(dashIdx + 1));
        start = startMonth.number;
        end = endMonth.number;
      } else {
        throw HronError.cron('invalid month step expression: $part');
      }

      final step = int.tryParse(stepStr);
      if (step == null) {
        throw HronError.cron('invalid month step value: $stepStr');
      }
      if (step == 0) {
        throw HronError.cron('step cannot be 0');
      }

      for (var n = start; n <= end; n += step) {
        months.add(MonthName.fromNumber(n));
      }
    } else if (part.contains('-')) {
      final dashIdx = part.indexOf('-');
      final startMonth = _parseMonthValue(part.substring(0, dashIdx));
      final endMonth = _parseMonthValue(part.substring(dashIdx + 1));
      final startNum = startMonth.number;
      final endNum = endMonth.number;
      if (startNum > endNum) {
        throw HronError.cron('invalid month range: $part');
      }
      for (var n = startNum; n <= endNum; n++) {
        months.add(MonthName.fromNumber(n));
      }
    } else {
      months.add(_parseMonthValue(part));
    }
  }

  return months;
}

MonthName _parseMonthValue(String s) {
  final n = int.tryParse(s);
  if (n != null) {
    if (n < 1 || n > 12) {
      throw HronError.cron('invalid month number: $n');
    }
    return MonthName.fromNumber(n);
  }
  final month = _parseMonthName(s);
  if (month == null) {
    throw HronError.cron('invalid month: $s');
  }
  return month;
}

MonthName? _parseMonthName(String s) {
  return switch (s.toUpperCase()) {
    'JAN' => MonthName.jan,
    'FEB' => MonthName.feb,
    'MAR' => MonthName.mar,
    'APR' => MonthName.apr,
    'MAY' => MonthName.may,
    'JUN' => MonthName.jun,
    'JUL' => MonthName.jul,
    'AUG' => MonthName.aug,
    'SEP' => MonthName.sep,
    'OCT' => MonthName.oct,
    'NOV' => MonthName.nov,
    'DEC' => MonthName.dec,
    _ => null,
  };
}

ScheduleData? _tryParseNthWeekday(
  String minuteField,
  String hourField,
  String domField,
  String dowField,
  List<MonthName> during,
) {
  if (dowField.contains('#')) {
    final parts = dowField.split('#');
    if (parts.length != 2) {
      throw HronError.cron('invalid # pattern: $dowField');
    }
    final dowNum = _parseDowValue(parts[0]);
    final weekday = Weekday.fromCronDow(dowNum);
    final nth = int.tryParse(parts[1]);
    if (nth == null) {
      throw HronError.cron('invalid nth value: ${parts[1]}');
    }
    if (nth < 1 || nth > 5) {
      throw HronError.cron('nth must be 1-5, got $nth');
    }
    final ordinal = switch (nth) {
      1 => OrdinalPosition.first,
      2 => OrdinalPosition.second,
      3 => OrdinalPosition.third,
      4 => OrdinalPosition.fourth,
      5 => OrdinalPosition.fifth,
      _ => throw HronError.cron('invalid nth value'),
    };

    if (domField != '*' && domField != '?') {
      throw HronError.cron('DOM must be * when using # for nth weekday');
    }

    final minute = _parseSingleValue(minuteField, 'minute', 0, 59);
    final hour = _parseSingleValue(hourField, 'hour', 0, 23);

    final schedule = ScheduleData(
      MonthRepeat(1, OrdinalWeekdayMonthTarget(ordinal, weekday), [
        TimeOfDay(hour, minute),
      ]),
    );
    schedule.during = during;
    return schedule;
  }

  if (dowField.endsWith('L') && dowField.length > 1) {
    final dowStr = dowField.substring(0, dowField.length - 1);
    final dowNum = _parseDowValue(dowStr);
    final weekday = Weekday.fromCronDow(dowNum);

    if (domField != '*' && domField != '?') {
      throw HronError.cron('DOM must be * when using nL for last weekday');
    }

    final minute = _parseSingleValue(minuteField, 'minute', 0, 59);
    final hour = _parseSingleValue(hourField, 'hour', 0, 23);

    final schedule = ScheduleData(
      MonthRepeat(1, OrdinalWeekdayMonthTarget(OrdinalPosition.last, weekday), [
        TimeOfDay(hour, minute),
      ]),
    );
    schedule.during = during;
    return schedule;
  }

  return null;
}

ScheduleData? _tryParseLastDay(
  String minuteField,
  String hourField,
  String domField,
  String dowField,
  List<MonthName> during,
) {
  if (domField != 'L' && domField != 'LW') {
    return null;
  }

  if (dowField != '*' && dowField != '?') {
    throw HronError.cron('DOW must be * when using L or LW in DOM');
  }

  final minute = _parseSingleValue(minuteField, 'minute', 0, 59);
  final hour = _parseSingleValue(hourField, 'hour', 0, 23);

  final target = domField == 'LW' ? LastWeekdayTarget() : LastDayTarget();

  final schedule = ScheduleData(
    MonthRepeat(1, target, [TimeOfDay(hour, minute)]),
  );
  schedule.during = during;
  return schedule;
}

ScheduleData? _tryParseNearestWeekday(
  String minuteField,
  String hourField,
  String domField,
  String dowField,
  List<MonthName> during,
) {
  if (!domField.endsWith('W') || domField == 'LW') {
    return null;
  }

  if (dowField != '*' && dowField != '?') {
    throw HronError.cron('DOW must be * when using W in DOM');
  }

  final dayStr = domField.substring(0, domField.length - 1);
  final day = int.tryParse(dayStr);
  if (day == null) {
    throw HronError.cron('invalid W day value: $dayStr');
  }
  if (day < 1 || day > 31) {
    throw HronError.cron('W day must be 1-31, got $day');
  }

  final minute = _parseSingleValue(minuteField, 'minute', 0, 59);
  final hour = _parseSingleValue(hourField, 'hour', 0, 23);

  final target = NearestWeekdayTarget(day);

  final schedule = ScheduleData(
    MonthRepeat(1, target, [TimeOfDay(hour, minute)]),
  );
  schedule.during = during;
  return schedule;
}

ScheduleData? _tryParseInterval(
  String minuteField,
  String hourField,
  String domField,
  String dowField,
  List<MonthName> during,
) {
  if (minuteField.contains('/')) {
    final splitIdx = minuteField.indexOf('/');
    final rangePart = minuteField.substring(0, splitIdx);
    final stepStr = minuteField.substring(splitIdx + 1);

    final interval = int.tryParse(stepStr);
    if (interval == null) {
      throw HronError.cron('invalid minute interval value');
    }
    if (interval == 0) {
      throw HronError.cron('step cannot be 0');
    }

    int fromMinute, toMinute;
    if (rangePart == '*') {
      fromMinute = 0;
      toMinute = 59;
    } else if (rangePart.contains('-')) {
      final dashIdx = rangePart.indexOf('-');
      final s = int.tryParse(rangePart.substring(0, dashIdx));
      final e = int.tryParse(rangePart.substring(dashIdx + 1));
      if (s == null || e == null) {
        throw HronError.cron('invalid minute range');
      }
      if (s > e) {
        throw HronError.cron('range start must be <= end: $s-$e');
      }
      fromMinute = s;
      toMinute = e;
    } else {
      final s = int.tryParse(rangePart);
      if (s == null) {
        throw HronError.cron('invalid minute value');
      }
      fromMinute = s;
      toMinute = 59;
    }

    int fromHour, toHour;
    if (hourField == '*') {
      fromHour = 0;
      toHour = 23;
    } else if (hourField.contains('-') && !hourField.contains('/')) {
      final dashIdx = hourField.indexOf('-');
      final s = int.tryParse(hourField.substring(0, dashIdx));
      final e = int.tryParse(hourField.substring(dashIdx + 1));
      if (s == null || e == null) {
        throw HronError.cron('invalid hour range');
      }
      fromHour = s;
      toHour = e;
    } else if (hourField.contains('/')) {
      return null;
    } else {
      final h = int.tryParse(hourField);
      if (h == null) {
        throw HronError.cron('invalid hour');
      }
      fromHour = h;
      toHour = h;
    }

    DayFilter? dayFilter;
    if (dowField != '*') {
      dayFilter = _parseCronDow(dowField);
    }

    if (domField == '*' || domField == '?') {
      int endMinute;
      if (fromMinute == 0 && toMinute == 59 && toHour == 23) {
        endMinute = 59;
      } else if (fromMinute == 0 && toMinute == 59) {
        // `9-17` ends at 17:00, not 17:59 (spec/tests.json `interval_with_hour_range`).
        endMinute = 0;
      } else {
        endMinute = toMinute;
      }

      final schedule = ScheduleData(
        IntervalRepeat(
          interval,
          IntervalUnit.min,
          TimeOfDay(fromHour, fromMinute),
          TimeOfDay(toHour, endMinute),
          dayFilter,
        ),
      );
      schedule.during = during;
      return schedule;
    }
  }

  if (hourField.contains('/') && (minuteField == '0' || minuteField == '00')) {
    final splitIdx = hourField.indexOf('/');
    final rangePart = hourField.substring(0, splitIdx);
    final stepStr = hourField.substring(splitIdx + 1);

    final interval = int.tryParse(stepStr);
    if (interval == null) {
      throw HronError.cron('invalid hour interval value');
    }
    if (interval == 0) {
      throw HronError.cron('step cannot be 0');
    }

    int fromHour, toHour;
    if (rangePart == '*') {
      fromHour = 0;
      toHour = 23;
    } else if (rangePart.contains('-')) {
      final dashIdx = rangePart.indexOf('-');
      final s = int.tryParse(rangePart.substring(0, dashIdx));
      final e = int.tryParse(rangePart.substring(dashIdx + 1));
      if (s == null || e == null) {
        throw HronError.cron('invalid hour range');
      }
      if (s > e) {
        throw HronError.cron('range start must be <= end: $s-$e');
      }
      fromHour = s;
      toHour = e;
    } else {
      final h = int.tryParse(rangePart);
      if (h == null) {
        throw HronError.cron('invalid hour value');
      }
      fromHour = h;
      toHour = 23;
    }

    if ((domField == '*' || domField == '?') &&
        (dowField == '*' || dowField == '?')) {
      final endMinute = (fromHour == 0 && toHour == 23) ? 59 : 0;

      final schedule = ScheduleData(
        IntervalRepeat(
          interval,
          IntervalUnit.hours,
          TimeOfDay(fromHour, 0),
          TimeOfDay(toHour, endMinute),
          null,
        ),
      );
      schedule.during = during;
      return schedule;
    }
  }

  return null;
}

MonthTarget _parseDomField(String field) {
  final specs = <DayOfMonthSpec>[];

  for (final part in field.split(',')) {
    if (part.contains('/')) {
      final splitIdx = part.indexOf('/');
      final rangePart = part.substring(0, splitIdx);
      final stepStr = part.substring(splitIdx + 1);

      int start, end;
      if (rangePart == '*') {
        start = 1;
        end = 31;
      } else if (rangePart.contains('-')) {
        final dashIdx = rangePart.indexOf('-');
        final s = int.tryParse(rangePart.substring(0, dashIdx));
        final e = int.tryParse(rangePart.substring(dashIdx + 1));
        if (s == null) {
          throw HronError.cron(
            'invalid DOM range start: ${rangePart.substring(0, dashIdx)}',
          );
        }
        if (e == null) {
          throw HronError.cron(
            'invalid DOM range end: ${rangePart.substring(dashIdx + 1)}',
          );
        }
        if (s > e) {
          throw HronError.cron('range start must be <= end: $s-$e');
        }
        start = s;
        end = e;
      } else {
        final s = int.tryParse(rangePart);
        if (s == null) {
          throw HronError.cron('invalid DOM value: $rangePart');
        }
        start = s;
        end = 31;
      }

      final step = int.tryParse(stepStr);
      if (step == null) {
        throw HronError.cron('invalid DOM step: $stepStr');
      }
      if (step == 0) {
        throw HronError.cron('step cannot be 0');
      }

      _validateDom(start);
      _validateDom(end);

      for (var d = start; d <= end; d += step) {
        specs.add(SingleDay(d));
      }
    } else if (part.contains('-')) {
      final dashIdx = part.indexOf('-');
      final startStr = part.substring(0, dashIdx);
      final endStr = part.substring(dashIdx + 1);
      final start = int.tryParse(startStr);
      final end = int.tryParse(endStr);
      if (start == null) {
        throw HronError.cron('invalid DOM range start: $startStr');
      }
      if (end == null) {
        throw HronError.cron('invalid DOM range end: $endStr');
      }
      if (start > end) {
        throw HronError.cron('range start must be <= end: $start-$end');
      }
      _validateDom(start);
      _validateDom(end);
      specs.add(DayRange(start, end));
    } else {
      final day = int.tryParse(part);
      if (day == null) {
        throw HronError.cron('invalid DOM value: $part');
      }
      _validateDom(day);
      specs.add(SingleDay(day));
    }
  }

  return DaysTarget(specs);
}

void _validateDom(int day) {
  if (day < 1 || day > 31) {
    throw HronError.cron('DOM must be 1-31, got $day');
  }
}

DayFilter _parseCronDow(String field) {
  if (field == '*') return EveryDay();

  final days = <Weekday>[];

  for (final part in field.split(',')) {
    if (part.contains('/')) {
      final splitIdx = part.indexOf('/');
      final rangePart = part.substring(0, splitIdx);
      final stepStr = part.substring(splitIdx + 1);

      int start, end;
      if (rangePart == '*') {
        start = 0;
        end = 6;
      } else if (rangePart.contains('-')) {
        final dashIdx = rangePart.indexOf('-');
        start = _parseDowValueRaw(rangePart.substring(0, dashIdx));
        end = _parseDowValueRaw(rangePart.substring(dashIdx + 1));
        if (start > end) {
          throw HronError.cron(
            'range start must be <= end: ${rangePart.substring(0, dashIdx)}-${rangePart.substring(dashIdx + 1)}',
          );
        }
      } else {
        start = _parseDowValueRaw(rangePart);
        end = 6;
      }

      final step = int.tryParse(stepStr);
      if (step == null) {
        throw HronError.cron('invalid DOW step: $stepStr');
      }
      if (step == 0) {
        throw HronError.cron('step cannot be 0');
      }

      for (var d = start; d <= end; d += step) {
        days.add(Weekday.fromCronDow(d));
      }
    } else if (part.contains('-')) {
      final dashIdx = part.indexOf('-');
      final startStr = part.substring(0, dashIdx);
      final endStr = part.substring(dashIdx + 1);
      final start = _parseDowValueRaw(startStr);
      final end = _parseDowValueRaw(endStr);
      if (start > end) {
        throw HronError.cron('range start must be <= end: $startStr-$endStr');
      }
      for (var d = start; d <= end; d++) {
        final normalized = d == 7 ? 0 : d;
        days.add(Weekday.fromCronDow(normalized));
      }
    } else {
      final dow = _parseDowValue(part);
      days.add(Weekday.fromCronDow(dow));
    }
  }

  if (days.length == 5) {
    final sorted = List<Weekday>.from(days)
      ..sort((a, b) => a.number.compareTo(b.number));
    if (_listEquals(sorted, [
      Weekday.monday,
      Weekday.tuesday,
      Weekday.wednesday,
      Weekday.thursday,
      Weekday.friday,
    ])) {
      return WeekdayFilter();
    }
  }
  if (days.length == 2) {
    final sorted = List<Weekday>.from(days)
      ..sort((a, b) => a.number.compareTo(b.number));
    if (_listEquals(sorted, [Weekday.saturday, Weekday.sunday])) {
      return WeekendFilter();
    }
  }

  return SpecificDays(days);
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

int _parseDowValue(String s) {
  final raw = _parseDowValueRaw(s);
  // Normalize 7 to 0 (both mean Sunday)
  return raw == 7 ? 0 : raw;
}

// Raw, so a range ending at 7 (Sunday), like `5-7`, stays ascending.
int _parseDowValueRaw(String s) {
  final n = int.tryParse(s);
  if (n != null) {
    if (n < 0 || n > 7) {
      throw HronError.cron('DOW must be 0-7, got $n');
    }
    return n;
  }
  return switch (s.toUpperCase()) {
    'SUN' => 0,
    'MON' => 1,
    'TUE' => 2,
    'WED' => 3,
    'THU' => 4,
    'FRI' => 5,
    'SAT' => 6,
    _ => throw HronError.cron('invalid DOW: $s'),
  };
}

int _parseSingleValue(String field, String name, int min, int max) {
  final value = int.tryParse(field);
  if (value == null) {
    throw HronError.cron('invalid $name field: $field');
  }
  if (value < min || value > max) {
    throw HronError.cron('$name must be $min-$max, got $value');
  }
  return value;
}
