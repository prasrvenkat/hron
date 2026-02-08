import 'ast.dart';

String display(ScheduleData schedule) {
  final buf = StringBuffer();
  buf.write(_displayExpr(schedule.expr));

  if (schedule.except.isNotEmpty) {
    buf.write(' except ');
    buf.write(schedule.except.map((exc) {
      if (exc is NamedException) return '${exc.month.name} ${exc.day}';
      return (exc as IsoException).date;
    }).join(', '));
  }

  if (schedule.until != null) {
    final u = schedule.until!;
    if (u is IsoUntil) {
      buf.write(' until ${u.date}');
    } else {
      final nu = u as NamedUntil;
      buf.write(' until ${nu.month.name} ${nu.day}');
    }
  }

  if (schedule.anchor != null) {
    buf.write(' starting ${schedule.anchor}');
  }

  if (schedule.during.isNotEmpty) {
    buf.write(' during ');
    buf.write(schedule.during.map((m) => m.name).join(', '));
  }

  if (schedule.timezone != null) {
    buf.write(' in ${schedule.timezone}');
  }

  return buf.toString();
}

String _displayExpr(ScheduleExpr expr) => switch (expr) {
      IntervalRepeat() => _displayInterval(expr),
      DayRepeat() =>
        'every ${_displayDayFilter(expr.days)} at ${_formatTimeList(expr.times)}',
      WeekRepeat() =>
        'every ${expr.interval} weeks on ${_formatDayList(expr.days)} at ${_formatTimeList(expr.times)}',
      MonthRepeat() => _displayMonthRepeat(expr),
      OrdinalRepeat() =>
        '${expr.ordinal.name} ${expr.day.name} of every month at ${_formatTimeList(expr.times)}',
      SingleDate() => _displaySingleDate(expr),
      YearRepeat() => _displayYearRepeat(expr),
    };

String _displayInterval(IntervalRepeat expr) {
  final unit = _unitDisplay(expr.interval, expr.unit);
  var out = 'every ${expr.interval} $unit from ${expr.from} to ${expr.to}';
  if (expr.dayFilter != null) {
    out += ' on ${_displayDayFilter(expr.dayFilter!)}';
  }
  return out;
}

String _displayMonthRepeat(MonthRepeat expr) {
  String targetStr;
  final target = expr.target;
  if (target is DaysTarget) {
    targetStr = _formatOrdinalDaySpecs(target.specs);
  } else if (target is LastDayTarget) {
    targetStr = 'last day';
  } else {
    targetStr = 'last weekday';
  }
  return 'every month on the $targetStr at ${_formatTimeList(expr.times)}';
}

String _displaySingleDate(SingleDate expr) {
  String dateStr;
  final date = expr.date;
  if (date is NamedDate) {
    dateStr = '${date.month.name} ${date.day}';
  } else {
    dateStr = (date as IsoDate).date;
  }
  return 'on $dateStr at ${_formatTimeList(expr.times)}';
}

String _displayYearRepeat(YearRepeat expr) {
  String targetStr;
  final target = expr.target;
  if (target is DateTarget) {
    targetStr = '${target.month.name} ${target.day}';
  } else if (target is OrdinalWeekdayTarget) {
    targetStr =
        'the ${target.ordinal.name} ${target.weekday.name} of ${target.month.name}';
  } else if (target is DayOfMonthTarget) {
    targetStr =
        'the ${target.day}${ordinalSuffix(target.day)} of ${target.month.name}';
  } else {
    targetStr =
        'the last weekday of ${(target as LastWeekdayYearTarget).month.name}';
  }
  return 'every year on $targetStr at ${_formatTimeList(expr.times)}';
}

String _displayDayFilter(DayFilter filter) => switch (filter) {
      EveryDay() => 'day',
      WeekdayFilter() => 'weekday',
      WeekendFilter() => 'weekend',
      SpecificDays() => _formatDayList(filter.days),
    };

String _formatTimeList(List<TimeOfDay> times) =>
    times.map((t) => t.toString()).join(', ');

String _formatDayList(List<Weekday> days) =>
    days.map((d) => d.name).join(', ');

String _formatOrdinalDaySpecs(List<DayOfMonthSpec> specs) =>
    specs.map((spec) {
      if (spec is SingleDay) {
        return '${spec.day}${ordinalSuffix(spec.day)}';
      }
      final range = spec as DayRange;
      return '${range.start}${ordinalSuffix(range.start)} to ${range.end}${ordinalSuffix(range.end)}';
    }).join(', ');

String _unitDisplay(int interval, IntervalUnit unit) {
  if (unit == IntervalUnit.min) {
    return interval == 1 ? 'minute' : 'min';
  }
  return interval == 1 ? 'hour' : 'hours';
}
