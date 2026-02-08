import 'ast.dart';
import 'error.dart';

String toCron(ScheduleData schedule) {
  if (schedule.except.isNotEmpty) {
    throw HronError.cron(
        'not expressible as cron (except clauses not supported)');
  }
  if (schedule.until != null) {
    throw HronError.cron(
        'not expressible as cron (until clauses not supported)');
  }
  if (schedule.during.isNotEmpty) {
    throw HronError.cron(
        'not expressible as cron (during clauses not supported)');
  }

  final expr = schedule.expr;

  switch (expr) {
    case DayRepeat(
        interval: final interval,
        days: final days,
        times: final times
      ):
      if (interval > 1) {
        throw HronError.cron(
            'not expressible as cron (multi-day intervals not supported)');
      }
      if (times.length != 1) {
        throw HronError.cron(
            'not expressible as cron (multiple times not supported)');
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
      final fullDay = from.hour == 0 &&
          from.minute == 0 &&
          to.hour == 23 &&
          to.minute == 59;
      if (!fullDay) {
        throw HronError.cron(
            'not expressible as cron (partial-day interval windows not supported)');
      }
      if (dayFilter != null) {
        throw HronError.cron(
            'not expressible as cron (interval with day filter not supported)');
      }
      if (unit == IntervalUnit.min) {
        if (60 % interval != 0) {
          throw HronError.cron(
              'not expressible as cron (*/$interval breaks at hour boundaries)');
        }
        return '*/$interval * * * *';
      }
      return '0 */$interval * * *';

    case WeekRepeat():
      throw HronError.cron(
          'not expressible as cron (multi-week intervals not supported)');

    case MonthRepeat(
        interval: final interval,
        target: final target,
        times: final times
      ):
      if (interval > 1) {
        throw HronError.cron(
            'not expressible as cron (multi-month intervals not supported)');
      }
      if (times.length != 1) {
        throw HronError.cron(
            'not expressible as cron (multiple times not supported)');
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
            'not expressible as cron (last day of month not supported)');
      }
      throw HronError.cron(
          'not expressible as cron (last weekday of month not supported)');

    case OrdinalRepeat():
      throw HronError.cron(
          'not expressible as cron (ordinal weekday of month not supported)');

    case SingleDate():
      throw HronError.cron(
          'not expressible as cron (single dates are not repeating)');

    case YearRepeat():
      throw HronError.cron(
          'not expressible as cron (yearly schedules not supported in 5-field cron)');
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
  final fields = cron.trim().split(RegExp(r'\s+'));
  if (fields.length != 5) {
    throw HronError.cron('expected 5 cron fields, got ${fields.length}');
  }

  final minuteField = fields[0];
  final hourField = fields[1];
  final domField = fields[2];
  final dowField = fields[4];

  // Minute interval: */N
  if (minuteField.startsWith('*/')) {
    final interval = int.tryParse(minuteField.substring(2));
    if (interval == null) throw HronError.cron('invalid minute interval');

    var fromHour = 0;
    var toHour = 23;

    if (hourField == '*') {
      // full day
    } else if (hourField.contains('-')) {
      final parts = hourField.split('-');
      fromHour = int.tryParse(parts[0]) ??
          (throw HronError.cron('invalid hour range'));
      toHour = int.tryParse(parts[1]) ??
          (throw HronError.cron('invalid hour range'));
    } else {
      final h = int.tryParse(hourField);
      if (h == null) throw HronError.cron('invalid hour');
      fromHour = h;
      toHour = h;
    }

    final dayFilter = dowField == '*' ? null : _parseCronDow(dowField);

    if (domField == '*') {
      return ScheduleData(IntervalRepeat(
        interval,
        IntervalUnit.min,
        TimeOfDay(fromHour, 0),
        TimeOfDay(toHour, toHour == 23 ? 59 : 0),
        dayFilter,
      ));
    }
  }

  // Hour interval: 0 */N
  if (hourField.startsWith('*/') && minuteField == '0') {
    final interval = int.tryParse(hourField.substring(2));
    if (interval == null) throw HronError.cron('invalid hour interval');
    if (domField == '*' && dowField == '*') {
      return ScheduleData(IntervalRepeat(
        interval,
        IntervalUnit.hours,
        const TimeOfDay(0, 0),
        const TimeOfDay(23, 59),
        null,
      ));
    }
  }

  // Standard time-based cron
  final minute = int.tryParse(minuteField);
  if (minute == null) {
    throw HronError.cron('invalid minute field: $minuteField');
  }
  final hour = int.tryParse(hourField);
  if (hour == null) {
    throw HronError.cron('invalid hour field: $hourField');
  }
  final time = TimeOfDay(hour, minute);

  // DOM-based (monthly)
  if (domField != '*' && dowField == '*') {
    if (domField.contains('-')) {
      throw HronError.cron('DOM ranges not supported: $domField');
    }
    final dayNums = domField.split(',').map((s) {
      final n = int.tryParse(s);
      if (n == null) throw HronError.cron('invalid DOM field: $domField');
      return n;
    }).toList();
    final specs = dayNums.map((d) => SingleDay(d) as DayOfMonthSpec).toList();
    return ScheduleData(MonthRepeat(1, DaysTarget(specs), [time]));
  }

  // DOW-based (day repeat)
  final days = _parseCronDow(dowField);
  return ScheduleData(DayRepeat(1, days, [time]));
}

DayFilter _parseCronDow(String field) {
  if (field == '*') return EveryDay();
  if (field == '1-5') return WeekdayFilter();
  if (field == '0,6' || field == '6,0') return WeekendFilter();

  if (field.contains('-')) {
    throw HronError.cron('DOW ranges not supported: $field');
  }

  final nums = field.split(',').map((s) {
    final n = int.tryParse(s);
    if (n == null) throw HronError.cron('invalid DOW field: $field');
    return n;
  }).toList();

  final days = nums.map((n) => _cronDowToWeekday(n)).toList();
  return SpecificDays(days);
}

Weekday _cronDowToWeekday(int n) {
  if (n < 0 || n > 7) throw HronError.cron('invalid DOW number: $n');
  return Weekday.fromCronDow(n);
}
