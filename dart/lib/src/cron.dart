import 'ast.dart';
import 'error.dart';
import 'eval.dart' show intervalSlots;

const _maxListedTimes = 24;
const _bothDaysRestricted =
    'not expressible in hron: cron fires on either the day of month or the day of week';
const _intervalDays =
    'not expressible in hron: an interval runs only on every day, weekdays, the weekend or listed days';
const _minutesPerDay = 24 * 60;
const _midnight = TimeOfDay(0, 0);
const _endOfDay = TimeOfDay(23, 59);

// Digit strings may be of any length. Every number at or above this cap is out
// of every field's range and steps past every range's end, so saturating at it
// keeps each comparison exact without overflow.
const _numberCap = 1000;

const _monthNames = [
  'jan',
  'feb',
  'mar',
  'apr',
  'may',
  'jun',
  'jul',
  'aug',
  'sep',
  'oct',
  'nov',
  'dec',
];
const _dayNames = ['sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat'];
const _ordinals = [
  OrdinalPosition.first,
  OrdinalPosition.second,
  OrdinalPosition.third,
  OrdinalPosition.fourth,
  OrdinalPosition.fifth,
];

enum _Field {
  minute('minute', 0, 59),
  hour('hour', 0, 23),
  dayOfMonth('day of month', 1, 31),
  month('month', 1, 12),
  dayOfWeek('day of week', 0, 7);

  const _Field(this.label, this.min, this.max);

  final String label;
  final int min;
  final int max;

  // In the day of week, 7 is Sunday only where written: `*` and `a/n` end at 6.
  int get starEnd => this == dayOfWeek ? 6 : max;

  List<String> get names => switch (this) {
    _Field.month => _monthNames,
    _Field.dayOfWeek => _dayNames,
    _ => const [],
  };
}

sealed class _Bounds {}

class _Star extends _Bounds {}

class _Value extends _Bounds {
  _Value(this.a);
  final String a;
}

class _Range extends _Bounds {
  _Range(this.a, this.b);
  final String a;
  final String b;
}

typedef _Item = ({_Bounds bounds, String? step});

sealed class _MonthDays {}

class _AnyMonthDay extends _MonthDays {}

class _MonthDayList extends _MonthDays {
  _MonthDayList(this.days);
  final List<int> days;
}

class _LastMonthDay extends _MonthDays {}

class _LastWeekdayOfMonth extends _MonthDays {}

class _NearestMonthDay extends _MonthDays {
  _NearestMonthDay(this.day);
  final int day;
}

sealed class _WeekDays {}

class _AnyWeekDay extends _WeekDays {}

class _WeekDayList extends _WeekDays {
  _WeekDayList(this.days);
  final List<int> days;
}

class _NthWeekDay extends _WeekDays {
  _NthWeekDay(this.weekday, this.n);
  final Weekday weekday;
  final int n;
}

class _LastWeekDay extends _WeekDays {
  _LastWeekDay(this.weekday);
  final Weekday weekday;
}

sealed class _Days {}

class _DaysOfWeek extends _Days {
  _DaysOfWeek(this.filter);
  final DayFilter filter;
}

class _DaysOfMonth extends _Days {
  _DaysOfMonth(this.target);
  final MonthTarget target;
}

ScheduleData fromCron(String cron) {
  final input = _trim(cron);
  final text = input.startsWith('@') ? _shortcut(input) : input;
  final fields = text
      .split(_fieldSeparator)
      .where((f) => f.isNotEmpty)
      .toList();
  if (fields.length != 5) {
    throw HronError.cron('expected 5 cron fields, got ${fields.length}');
  }
  final [minute, hour, dayOfMonth, month, dayOfWeek] = fields;

  final minutes = _sorted(_values(minute, _Field.minute));
  final hours = _sorted(_values(hour, _Field.hour));
  final monthDays = _parseDayOfMonth(dayOfMonth);
  final months = _sorted(_values(month, _Field.month));
  final weekDays = _parseDayOfWeek(dayOfWeek);
  final days = _dayExpression(monthDays, weekDays);
  final times = [
    for (final hour in hours)
      for (final minute in minutes) TimeOfDay(hour, minute),
  ];

  final gap = _equalGap(times);
  final yearTarget = _yearTarget(days, months);
  final ScheduleExpr expr;
  if (days is _DaysOfWeek && gap != null) {
    expr = _interval(times, gap, days.filter);
  } else if (times.length > _maxListedTimes) {
    throw _tooManyTimes(times.length, gap);
  } else if (yearTarget != null) {
    expr = YearRepeat(1, yearTarget, times);
  } else {
    expr = switch (days) {
      _DaysOfWeek(:final filter) => DayRepeat(1, filter, times),
      _DaysOfMonth(:final target) => MonthRepeat(1, target, times),
    };
  }
  final during = expr is! YearRepeat && months.length < MonthName.values.length
      ? [for (final m in months) MonthName.fromNumber(m)]
      : const <MonthName>[];
  return ScheduleData(expr, during: during);
}

final _fieldSeparator = RegExp('[ \t]');

// Not String.trim, which also strips Unicode spaces the spec does not trim.
String _trim(String text) {
  bool isTrimmed(int unit) =>
      unit == 0x20 || unit == 0x09 || unit == 0x0D || unit == 0x0A;
  var start = 0;
  var end = text.length;
  while (start < end && isTrimmed(text.codeUnitAt(start))) {
    start++;
  }
  while (end > start && isTrimmed(text.codeUnitAt(end - 1))) {
    end--;
  }
  return text.substring(start, end);
}

// Not String.toLowerCase or toUpperCase, which fold U+212A (Kelvin sign) and
// U+017F (ſ) onto ASCII letters.
String _asciiLowercase(String text) => String.fromCharCodes(
  text.codeUnits.map((u) => u >= 0x41 && u <= 0x5A ? u + 0x20 : u),
);

String _shortcut(String input) => switch (_asciiLowercase(input)) {
  '@yearly' || '@annually' => '0 0 1 1 *',
  '@monthly' => '0 0 1 * *',
  '@weekly' => '0 0 * * 0',
  '@daily' || '@midnight' => '0 0 * * *',
  '@hourly' => '0 * * * *',
  _ => throw HronError.cron('unknown cron shortcut: $input'),
};

_MonthDays _parseDayOfMonth(String text) {
  if (text == '*' || text == '?') return _AnyMonthDay();
  final lower = _asciiLowercase(text);
  if (lower == 'l') return _LastMonthDay();
  if (lower == 'lw') return _LastWeekdayOfMonth();
  if (lower.endsWith('w')) {
    final day = text.substring(0, text.length - 1);
    if (_isNumber(day)) {
      return _NearestMonthDay(_fieldValue(day, _Field.dayOfMonth));
    }
  }
  return _MonthDayList(_values(text, _Field.dayOfMonth));
}

_WeekDays _parseDayOfWeek(String text) {
  const field = _Field.dayOfWeek;
  if (text == '*' || text == '?') return _AnyWeekDay();
  final hash = text.indexOf('#');
  if (hash >= 0) {
    final day = text.substring(0, hash);
    final nth = text.substring(hash + 1);
    if (_isValue(day, field) && _isNumber(nth)) {
      final weekday = Weekday.fromCronDow(_fieldValue(day, field) % 7);
      final n = _number(nth);
      if (n < 1 || n > 5) {
        throw HronError.cron('day of week ordinal must be 1-5, got $nth');
      }
      return _NthWeekDay(weekday, n);
    }
  }
  if (_asciiLowercase(text).endsWith('l')) {
    final day = text.substring(0, text.length - 1);
    if (_isValue(day, field)) {
      return _LastWeekDay(Weekday.fromCronDow(_fieldValue(day, field) % 7));
    }
  }
  return _WeekDayList(_values(text, field));
}

// Keeps the order of first appearance, in which fromCron lists days of the week.
List<int> _values(String text, _Field field) {
  final items = _items(text, field);
  if (items == null) throw HronError.cron('invalid ${field.label}: $text');
  final values = <int>{};
  for (final item in items) {
    final int first;
    final int last;
    switch (item.bounds) {
      case _Star():
        first = field.min;
        last = field.starEnd;
      case _Value(:final a):
        first = _fieldValue(a, field);
        // `7/n` starts past the end of `*`, so it is Sunday alone.
        last = item.step == null
            ? first
            : (first > field.starEnd ? first : field.starEnd);
      case _Range(:final a, :final b):
        first = _fieldValue(a, field);
        last = _fieldValue(b, field);
        if (first > last) {
          throw HronError.cron(
            '${field.label} range must not run backwards: $a-$b',
          );
        }
    }
    final step = item.step == null ? 1 : _number(item.step!);
    if (step == 0) {
      throw HronError.cron('${field.label} step must be at least 1');
    }
    for (var value = first; value <= last; value += step) {
      values.add(field == _Field.dayOfWeek ? value % 7 : value);
    }
  }
  return values.toList();
}

List<_Item>? _items(String text, _Field field) {
  final items = <_Item>[];
  for (final item in text.split(',')) {
    final slash = item.indexOf('/');
    final range = slash < 0 ? item : item.substring(0, slash);
    final step = slash < 0 ? null : item.substring(slash + 1);
    final dash = range.indexOf('-');
    final _Bounds bounds = range == '*'
        ? _Star()
        : dash < 0
        ? _Value(range)
        : _Range(range.substring(0, dash), range.substring(dash + 1));
    final valid =
        (step == null || _isNumber(step)) &&
        switch (bounds) {
          _Star() => true,
          _Value(:final a) => _isValue(a, field),
          _Range(:final a, :final b) =>
            _isValue(a, field) && _isValue(b, field),
        };
    if (!valid) return null;
    items.add((bounds: bounds, step: step));
  }
  return items;
}

bool _isNumber(String text) =>
    text.isNotEmpty && text.codeUnits.every((u) => u >= 0x30 && u <= 0x39);

bool _isValue(String text, _Field field) =>
    _isNumber(text) || _nameValue(text, field) != null;

int? _nameValue(String text, _Field field) {
  final index = field.names.indexOf(_asciiLowercase(text));
  return index < 0 ? null : index + field.min;
}

int _number(String digits) {
  var n = 0;
  for (final unit in digits.codeUnits) {
    n = n * 10 + (unit - 0x30);
    if (n > _numberCap) n = _numberCap;
  }
  return n;
}

int _fieldValue(String text, _Field field) {
  final value = _nameValue(text, field) ?? _number(text);
  if (value < field.min || value > field.max) {
    throw HronError.cron(
      '${field.label} must be ${field.min}-${field.max}, got $text',
    );
  }
  return value;
}

_Days _dayExpression(_MonthDays monthDays, _WeekDays weekDays) => switch ((
  monthDays,
  weekDays,
)) {
  (_AnyMonthDay(), _AnyWeekDay()) => _DaysOfWeek(EveryDay()),
  (_AnyMonthDay(), _WeekDayList(:final days)) => _DaysOfWeek(
    _weekdayFilter(days),
  ),
  (_AnyMonthDay(), _NthWeekDay(:final weekday, :final n)) => _DaysOfMonth(
    OrdinalWeekdayMonthTarget(_ordinals[n - 1], weekday),
  ),
  (_AnyMonthDay(), _LastWeekDay(:final weekday)) => _DaysOfMonth(
    OrdinalWeekdayMonthTarget(OrdinalPosition.last, weekday),
  ),
  (_MonthDayList(:final days), _AnyWeekDay()) when days.length == 31 =>
    _DaysOfWeek(EveryDay()),
  (_MonthDayList(:final days), _AnyWeekDay()) => _DaysOfMonth(
    DaysTarget([
      for (final (first, last) in _runs(_sorted(days)))
        first == last ? SingleDay(first) : DayRange(first, last),
    ]),
  ),
  (_LastMonthDay(), _AnyWeekDay()) => _DaysOfMonth(LastDayTarget()),
  (_LastWeekdayOfMonth(), _AnyWeekDay()) => _DaysOfMonth(LastWeekdayTarget()),
  (_NearestMonthDay(:final day), _AnyWeekDay()) => _DaysOfMonth(
    NearestWeekdayTarget(day),
  ),
  _ => throw HronError.cron(_bothDaysRestricted),
};

DayFilter _weekdayFilter(List<int> days) => switch (_sorted(days)) {
  [0, 1, 2, 3, 4, 5, 6] => EveryDay(),
  [1, 2, 3, 4, 5] => WeekdayFilter(),
  [0, 6] => WeekendFilter(),
  _ => SpecificDays([for (final d in days) Weekday.fromCronDow(d)]),
};

int? _equalGap(List<TimeOfDay> times) {
  final minutes = [for (final t in times) _minuteOfDay(t)];
  if (minutes.length < 3) return null;
  final gap = minutes[1] - minutes[0];
  for (var i = 1; i < minutes.length; i++) {
    if (minutes[i] - minutes[i - 1] != gap) return null;
  }
  return gap;
}

IntervalRepeat _interval(List<TimeOfDay> times, int gap, DayFilter days) {
  final from = times.first;
  final last = times.last;
  final to = from == _midnight && _minuteOfDay(last) + gap >= _minutesPerDay
      ? _endOfDay
      : last;
  final (interval, unit) = gap % 60 == 0
      ? (gap ~/ 60, IntervalUnit.hours)
      : (gap, IntervalUnit.min);
  return IntervalRepeat(
    interval,
    unit,
    from,
    to,
    days is EveryDay ? null : days,
  );
}

HronError _tooManyTimes(int count, int? gap) => gap != null
    ? HronError.cron(_intervalDays)
    : HronError.cron(
        'not expressible in hron: $count times a day are too many to list',
      );

YearTarget? _yearTarget(_Days days, List<int> months) {
  if (days is! _DaysOfMonth || months.length != 1) return null;
  final month = MonthName.fromNumber(months.single);
  return switch (days.target) {
    DaysTarget(specs: [SingleDay(:final day)]) when day <= _maxDay(month) =>
      DateTarget(month, day),
    LastWeekdayTarget() => LastWeekdayYearTarget(month),
    OrdinalWeekdayMonthTarget(:final ordinal, :final weekday) =>
      OrdinalWeekdayTarget(ordinal, weekday, month),
    _ => null,
  };
}

int _maxDay(MonthName month) => switch (month) {
  MonthName.feb => 29,
  MonthName.apr || MonthName.jun || MonthName.sep || MonthName.nov => 30,
  _ => 31,
};

String toCron(ScheduleData schedule) {
  if (schedule.except.isNotEmpty) {
    throw _notExpressible('except clauses not supported');
  }
  if (schedule.until != null) {
    throw _notExpressible('until clauses not supported');
  }
  if (schedule.anchor != null) {
    throw _notExpressible('starting clauses not supported');
  }
  final (dayOfMonth, dayOfWeek) = _dayFields(schedule.expr);
  final month = _monthField(schedule);
  final (minute, hour) = _timeFields(schedule.expr);
  return '$minute $hour $dayOfMonth $month $dayOfWeek';
}

HronError _notExpressible(String reason) =>
    HronError.cron('not expressible as cron: $reason');

void _repeatsOnce(int interval, String unit) {
  if (interval > 1) {
    throw _notExpressible('multi-$unit repeats not supported');
  }
}

(String, String) _dayFields(ScheduleExpr expr) {
  switch (expr) {
    case IntervalRepeat(:final dayFilter):
      return ('*', dayFilter == null ? '*' : _filterField(dayFilter));
    case DayRepeat(:final interval, :final days):
      _repeatsOnce(interval, 'day');
      return ('*', _filterField(days));
    case WeekRepeat(:final interval, :final days):
      _repeatsOnce(interval, 'week');
      return ('*', _weekdaysField(days));
    case MonthRepeat(:final interval, :final target):
      _repeatsOnce(interval, 'month');
      switch (target) {
        case DaysTarget():
          final days = _sortedUnique(expandMonthTarget(target));
          return (_listField(days, 31), '*');
        case LastDayTarget():
          return ('L', '*');
        case LastWeekdayTarget():
          return ('LW', '*');
        case NearestWeekdayTarget(direction: _?):
          throw _notExpressible('directional nearest weekday not supported');
        case NearestWeekdayTarget(:final day):
          return ('${day}W', '*');
        case OrdinalWeekdayMonthTarget(:final ordinal, :final weekday):
          return ('*', _ordinalField(ordinal, weekday));
      }
    case YearRepeat(:final interval, :final target):
      _repeatsOnce(interval, 'year');
      return switch (target) {
        DateTarget(:final day) || DayOfMonthTarget(:final day) => ('$day', '*'),
        OrdinalWeekdayTarget(:final ordinal, :final weekday) => (
          '*',
          _ordinalField(ordinal, weekday),
        ),
        LastWeekdayYearTarget() => ('LW', '*'),
      };
    case SingleDate(date: IsoDate()):
      throw _notExpressible('ISO dates do not repeat');
    case SingleDate(date: NamedDate(:final day)):
      return ('$day', '*');
  }
}

String _monthField(ScheduleData schedule) {
  final during = schedule.during;
  final month = _ownMonth(schedule.expr);
  if (month != null) {
    if (during.isNotEmpty && !during.contains(month)) {
      throw _notExpressible("during excludes the schedule's month");
    }
    return '${month.number}';
  }
  if (during.isEmpty) return '*';
  return _listField(_sortedUnique([for (final m in during) m.number]), 12);
}

MonthName? _ownMonth(ScheduleExpr expr) => switch (expr) {
  YearRepeat(:final target) => switch (target) {
    DateTarget(:final month) ||
    DayOfMonthTarget(:final month) ||
    OrdinalWeekdayTarget(:final month) ||
    LastWeekdayYearTarget(:final month) => month,
  },
  SingleDate(date: NamedDate(:final month)) => month,
  _ => null,
};

(String, String) _timeFields(ScheduleExpr expr) {
  final times = _dailyTimes(expr);
  final minutes = _sortedUnique([for (final t in times) t % 60]);
  final hours = _sortedUnique([for (final t in times) t ~/ 60]);
  if (minutes.length * hours.length != times.length) {
    throw _notExpressible(
      'times are not every combination of their minutes and hours',
    );
  }
  return (_stepField(minutes, 60), _stepField(hours, 24));
}

List<int> _dailyTimes(ScheduleExpr expr) => _sortedUnique(switch (expr) {
  IntervalRepeat() => intervalSlots(expr),
  DayRepeat(:final times) ||
  WeekRepeat(:final times) ||
  MonthRepeat(:final times) ||
  YearRepeat(:final times) ||
  SingleDate(:final times) => [for (final t in times) _minuteOfDay(t)],
});

String _filterField(DayFilter filter) => switch (filter) {
  EveryDay() => '*',
  WeekdayFilter() => _weekdaysField([
    Weekday.monday,
    Weekday.tuesday,
    Weekday.wednesday,
    Weekday.thursday,
    Weekday.friday,
  ]),
  WeekendFilter() => _weekdaysField([Weekday.saturday, Weekday.sunday]),
  SpecificDays(:final days) => _weekdaysField(days),
};

String _weekdaysField(List<Weekday> days) =>
    _listField(_sortedUnique([for (final d in days) d.cronDow]), 7);

String _ordinalField(OrdinalPosition ordinal, Weekday weekday) =>
    ordinal == OrdinalPosition.last
    ? '${weekday.cronDow}L'
    : '${weekday.cronDow}#${ordinal.toN}';

String _stepField(List<int> values, int size) {
  final first = values.first;
  final last = values.last;
  final gap = values.length > 1 ? values[1] - first : null;
  var equalGaps = gap != null;
  for (var i = 1; equalGaps && i < values.length; i++) {
    equalGaps = values[i] - values[i - 1] == gap;
  }
  if (values.length == size) return '*';
  if (gap == null) return '$first';
  if (equalGaps && first == 0 && last + gap == size) return '*/$gap';
  if (equalGaps && gap == 1) return '$first-$last';
  if (equalGaps && values.length >= 3) return '$first-$last/$gap';
  return _listField(values, size);
}

String _listField(List<int> values, int size) {
  if (values.length == size) return '*';
  return [
    for (final (first, last) in _runs(values))
      first == last ? '$first' : '$first-$last',
  ].join(',');
}

List<(int, int)> _runs(List<int> sortedValues) {
  final runs = <(int, int)>[];
  for (final value in sortedValues) {
    if (runs.isNotEmpty && runs.last.$2 + 1 == value) {
      runs.last = (runs.last.$1, value);
    } else {
      runs.add((value, value));
    }
  }
  return runs;
}

int _minuteOfDay(TimeOfDay time) => time.hour * 60 + time.minute;

List<int> _sorted(List<int> values) => [...values]..sort();

List<int> _sortedUnique(Iterable<int> values) =>
    values.toSet().toList()..sort();
