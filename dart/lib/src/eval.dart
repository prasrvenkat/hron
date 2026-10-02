import 'dart:math';

import 'package:timezone/timezone.dart';

import 'ast.dart';
import 'eval/calendar.dart';
import 'eval/wall_clock.dart';

/// Default anchor for week intervals (spec/README.md, "WeekRepeat epoch
/// alignment").
final _epochMonday = DateTime.utc(1970, 1, 5);

final _epochDate = DateTime.utc(1970);

/// spec/README.md, "Supported range".
final _rangeStart = DateTime.utc(1, 1, 2);
final _rangeEnd = DateTime.utc(9999, 12, 30);

/// The calendar of four-digit years, from [_calendarStart] to [_calendarEnd]
/// inclusive. No occurrence beyond it is in the supported range, so a search
/// walks at most one period past it: that period can hold a nearest weekday
/// landing back inside.
final _calendarStart = DateTime.utc(1);
final _calendarEnd = DateTime.utc(9999, 12, 31);

/// Slack beyond the horizon for the period one behind the first date's, where
/// a search starts, and for a horizon that starts mid-period.
const _horizonMarginPeriods = 2;

/// How many dates past its scheduled date a fixed time can land: one shifted
/// out of a gap before midnight lands on the next date.
const _maxShiftDays = 1;

/// How many dates behind a date that has begun now's wall date can read: from
/// the second pass of a fall-back overlap that crosses midnight, one.
const _maxOverlapDays = 1;

/// Feb 29 can be eight years away, as from 2096-03-01 to 2104-02-29.
const _namedUntilMaxYears = 8;

TZDateTime? nextFrom(ScheduleData schedule, TZDateTime now) =>
    _search(schedule, now, _Direction.forward);

TZDateTime? previousFrom(ScheduleData schedule, TZDateTime now) =>
    _search(schedule, now, _Direction.backward);

TZDateTime? _search(
  ScheduleData schedule,
  TZDateTime now,
  _Direction direction,
) => _inSupportedRange(now) ? _Search(schedule).nearest(now, direction) : null;

/// Defined through the forward search, so the two can never disagree about
/// what an occurrence is (spec/README.md, "matches is true exactly when the
/// minute containing t is an occurrence").
bool matches(ScheduleData schedule, TZDateTime datetime) {
  if (!_inSupportedRange(datetime)) return false;
  final search = _Search(schedule);
  final minute = startOfMinute(TZDateTime.from(datetime, search.zone));
  // An occurrence never lands before the date it is scheduled on, so one at
  // this minute is scheduled on or before the minute's wall date.
  final next = search
      .endingOn(dateOf(minute))
      .nearest(
        minute.subtract(const Duration(milliseconds: 1)),
        _Direction.forward,
      );
  return next != null && next.isAtSameMomentAs(minute);
}

List<TZDateTime> nextNFrom(ScheduleData schedule, TZDateTime now, int n) =>
    occurrences(schedule, now).take(max(n, 0)).toList();

Iterable<TZDateTime> occurrences(ScheduleData schedule, TZDateTime from) sync* {
  if (!_inSupportedRange(from)) return;
  final search = _Search(schedule);
  for (
    var next = search.nearest(from, _Direction.forward);
    next != null;
    next = search.nearest(next, _Direction.forward)
  ) {
    yield next;
  }
}

Iterable<TZDateTime> between(
  ScheduleData schedule,
  TZDateTime from,
  TZDateTime to,
) => _inSupportedRange(to)
    ? occurrences(schedule, from).takeWhile((t) => !t.isAfter(to))
    : const [];

bool _inSupportedRange(DateTime t) =>
    !t.isBefore(_rangeStart) && t.isBefore(_rangeEnd);

enum _Direction {
  forward(1),
  backward(-1);

  const _Direction(this.sign);

  final int sign;

  bool precedes<T extends Comparable<Object>>(T a, T b) =>
      sign * a.compareTo(b) < 0;

  Iterable<T> inOrder<T>(List<T> items) => switch (this) {
    _Direction.forward => items,
    _Direction.backward => items.reversed,
  };
}

typedef _Occurrence = ({TZDateTime instant, DateTime landing});

final class _Search {
  factory _Search(ScheduleData schedule) {
    final iso = schedule.starting;
    final starting = iso == null ? null : parseIsoDate(iso);
    return _Search._(
      schedule.expression,
      _zoneNamed(schedule.timezone),
      _Cadence.of(schedule.expression, starting),
      _DailyTimes.of(schedule.expression),
      _Clauses.of(schedule, starting),
    );
  }

  _Search._(this._expr, this.zone, this._cadence, this._times, this._clauses);

  final ScheduleExpr _expr;
  final Location zone;
  final _Cadence _cadence;
  final _DailyTimes _times;
  final _Clauses _clauses;

  _Search endingOn(DateTime date) =>
      _Search._(_expr, zone, _cadence, _times, _clauses.endOn(date));

  TZDateTime? nearest(TZDateTime now, _Direction direction) {
    final local = TZDateTime.from(now, zone);
    final nearestOnDate = _times.nearestOnDate(local, direction);
    final nowDate = dateOf(local);
    final shift = _times.maxShiftDays;
    final firstDate = _clauses.clamp(nowDate, direction);
    // A nearest weekday or a DST shift can move an occurrence out of the
    // period it is scheduled in, so the search starts one period back.
    final firstPeriod = _cadence.periodOf(firstDate) - direction.sign;
    final reach = switch (_clauses.farthestExceptDate(direction)) {
      final date? => _cadence.periodOf(date),
      null => firstPeriod,
    };
    _Occurrence? best;
    search:
    for (final start in _cadence.periodStarts(firstPeriod, reach, direction)) {
      if (_rejectsPeriod(start)) continue;
      final candidates = _candidatesInPeriod(_expr, start);
      for (final candidate in direction.inOrder(candidates)) {
        final beaten =
            best != null &&
            !_couldBeat(candidate.date, best.landing, direction, shift);
        if (beaten || _clauses.endsSearch(candidate.date, direction)) {
          break search;
        }
        if (_isBehind(candidate.date, nowDate, direction, shift) ||
            !_clauses.allows(candidate)) {
          continue;
        }
        final instant = nearestOnDate(candidate.date);
        if (instant == null) continue;
        if (best == null || direction.precedes(instant, best.instant)) {
          best = (instant: instant, landing: dateOf(instant));
        }
      }
    }
    final nearest = best?.instant;
    return nearest != null && _inSupportedRange(nearest) ? nearest : null;
  }

  /// A day or month period's candidates all target its own month, so one
  /// whose month `during` rejects holds nothing.
  bool _rejectsPeriod(DateTime start) =>
      (_cadence._unit == _Unit.day || _cadence._unit == _Unit.month) &&
      !_clauses.allowsMonth(start.month);
}

/// An occurrence lands from its scheduled date to [shift] dates after it,
/// on a first pass, and first passes keep wall-clock order.
bool _couldBeat(
  DateTime date,
  DateTime landing,
  _Direction direction,
  int shift,
) => switch (direction) {
  _Direction.forward => !date.isAfter(landing),
  _Direction.backward => daysBetween(date, landing) <= shift,
};

bool _isBehind(
  DateTime date,
  DateTime nowDate,
  _Direction direction,
  int shift,
) => switch (direction) {
  _Direction.forward => daysBetween(date, nowDate) > shift,
  _Direction.backward => daysBetween(nowDate, date) > _maxOverlapDays,
};

// The timezone package names its UTC location 'Etc/UTC' since 0.11.1, and
// 'UTC' is not in its database; spec/tests.json expects results in '[UTC]'.
final _utc = Location('UTC', [minTime], [0], [TimeZone.UTC]);

Location _zoneNamed(String? name) =>
    name == null || name == 'UTC' ? _utc : getLocation(name);

typedef _NearestOnDate = TZDateTime? Function(DateTime date);

sealed class _DailyTimes {
  factory _DailyTimes.of(ScheduleExpr expr) => switch (expr) {
    IntervalRepeat() => _Slots.of(expr),
    DayRepeat(:final times) ||
    WeekRepeat(:final times) ||
    MonthRepeat(:final times) ||
    SingleDate(:final times) ||
    YearRepeat(:final times) => _FixedTimes.of(times),
  };

  /// How many dates past its scheduled date an occurrence can land: a gap
  /// pushes a fixed time forward, and skips a slot.
  int get maxShiftDays;

  _NearestOnDate nearestOnDate(TZDateTime now, _Direction direction);
}

final class _FixedTimes implements _DailyTimes {
  _FixedTimes.of(List<TimeOfDay> times)
    : _minutes = [for (final time in times) minuteOfDay(time)];

  final List<int> _minutes;

  @override
  int get maxShiftDays => _maxShiftDays;

  @override
  _NearestOnDate nearestOnDate(TZDateTime now, _Direction direction) =>
      (date) => _nearestOn(date, now, direction);

  /// Every time is resolved: one shifted out of a gap can land after a later
  /// wall time.
  TZDateTime? _nearestOn(DateTime date, TZDateTime now, _Direction direction) {
    TZDateTime? nearest;
    for (final minute in _minutes) {
      final instant = fixedTimeOn(date, minute, now.location);
      if (direction.precedes(now, instant) &&
          (nearest == null || direction.precedes(instant, nearest))) {
        nearest = instant;
      }
    }
    return nearest;
  }
}

// toCron writes these, so a converted interval fires at the slots evaluation
// steps through.
List<int> intervalSlots(IntervalRepeat expr) {
  final slots = _Slots.of(expr);
  return [for (var k = 0; k <= slots._last; k++) slots._minuteOf(k)];
}

/// Unlike the reference's binary search on slot keys, index arithmetic finds
/// the slot at now's wall time directly: each wall time resolved here costs
/// three zone lookups, and the binary search measured slower.
final class _Slots implements _DailyTimes {
  factory _Slots.of(IntervalRepeat expr) {
    final from = minuteOfDay(expr.from);
    final step = switch (expr.unit) {
      IntervalUnit.min => expr.interval,
      IntervalUnit.hours => expr.interval * minutesPerHour,
    };
    return _Slots._(from, step, floorDiv(minuteOfDay(expr.to) - from, step));
  }

  _Slots._(this._from, this._step, this._last);

  final int _from;
  final int _step;

  final int _last;

  @override
  int get maxShiftDays => 0;

  @override
  _NearestOnDate nearestOnDate(TZDateTime now, _Direction direction) {
    switch (direction) {
      case _Direction.forward:
        return (date) => _firstAfter(date, now);
      case _Direction.backward:
        final pastFirstPass = minutesPastFirstPass(now);
        return (date) => _lastBefore(date, now, pastFirstPass);
    }
  }

  /// Slots resolve in wall-clock order, and one whose wall time is not after
  /// now's has passed, so the scan starts after now's wall time.
  TZDateTime? _firstAfter(DateTime date, TZDateTime now) {
    final first = _indexAtOrBefore(minutesAfterMidnight(date, now)) + 1;
    for (var k = max(first, 0); k <= _last; k++) {
      final instant = slotOn(date, _minuteOf(k), now.location);
      if (instant != null && instant.isAfter(now)) return instant;
    }
    return null;
  }

  /// Unlike the forward scan, this one can start at a wall time after now's:
  /// from the second pass of a fall-back overlap, [pastFirstPass] minutes
  /// after the first, the first pass of a later wall time, even on the next
  /// date, is still before now.
  TZDateTime? _lastBefore(DateTime date, TZDateTime now, int pastFirstPass) {
    final last = _indexAtOrBefore(
      minutesAfterMidnight(date, now) + pastFirstPass,
    );
    for (var k = min(last, _last); k >= 0; k--) {
      final instant = slotOn(date, _minuteOf(k), now.location);
      if (instant != null && instant.isBefore(now)) return instant;
    }
    return null;
  }

  int _minuteOf(int k) => _from + k * _step;

  int _indexAtOrBefore(int minute) => floorDiv(minute - _from, _step);
}

/// The trailing clauses, resolved once. `during` applies to a candidate's
/// target month; `except`, `until` and `starting` to its date (spec/README.md,
/// "Nearest weekday and `during`", "The `starting` clause").
final class _Clauses {
  factory _Clauses.of(ScheduleData schedule, DateTime? starting) {
    final exceptMonthDays = <(int, int)>[];
    final exceptDates = <DateTime>[];
    for (final exception in schedule.except) {
      switch (exception) {
        case NamedException(:final month, :final day):
          exceptMonthDays.add((month.number, day));
        case IsoException(:final date):
          exceptDates.add(parseIsoDate(date));
      }
    }
    final until = schedule.until;
    return _Clauses._(
      [for (final month in schedule.during) month.number],
      exceptMonthDays,
      exceptDates,
      until == null ? null : _resolveUntil(until, starting),
      starting,
    );
  }

  _Clauses._(
    this._during,
    this._exceptMonthDays,
    this._exceptDates,
    this._until,
    this._starting,
  );

  final List<int> _during;
  final List<(int, int)> _exceptMonthDays;
  final List<DateTime> _exceptDates;
  final DateTime? _until;
  final DateTime? _starting;

  bool allows(_Candidate candidate) {
    final date = candidate.date;
    return allowsMonth(candidate.targetMonth) &&
        !_exceptMonthDays.contains((date.month, date.day)) &&
        !_exceptDates.contains(date) &&
        (_until == null || !date.isAfter(_until)) &&
        (_starting == null || !date.isBefore(_starting));
  }

  bool allowsMonth(int month) => _during.isEmpty || _during.contains(month);

  _Clauses endOn(DateTime date) => _Clauses._(
    _during,
    _exceptMonthDays,
    _exceptDates,
    _until == null || date.isBefore(_until) ? date : _until,
    _starting,
  );

  /// The one-off except date farthest along [direction]: the calendar repeats
  /// only beyond it (spec/README.md, "Search horizon").
  DateTime? farthestExceptDate(_Direction direction) => _exceptDates.isEmpty
      ? null
      : _exceptDates.reduce((a, b) => direction.precedes(a, b) ? b : a);

  DateTime clamp(DateTime date, _Direction direction) => switch (direction) {
    _Direction.forward when _starting != null && date.isBefore(_starting) =>
      _starting,
    _Direction.backward when _until != null && date.isAfter(_until) => _until,
    _ => date,
  };

  bool endsSearch(DateTime date, _Direction direction) => switch (direction) {
    _Direction.forward => _until != null && date.isAfter(_until),
    _Direction.backward => _starting != null && date.isBefore(_starting),
  };
}

/// A named until date is the first such date on or after the starting date
/// (spec/README.md, "Named `until`").
DateTime _resolveUntil(UntilSpec until, DateTime? starting) {
  switch (until) {
    case IsoUntil(:final date):
      return parseIsoDate(date);
    case NamedUntil(:final month, :final day):
      final from = starting!;
      return [
        for (var k = 0; k <= _namedUntilMaxYears; k++)
          ?validDate(from.year + k, month.number, day),
      ].firstWhere((date) => !date.isBefore(from));
  }
}

enum _Unit {
  day(146097),
  week(20871),
  month(4800),
  year(400);

  const _Unit(this.per400Years);

  /// Units in 400 years, after which the proleptic Gregorian calendar repeats.
  final int per400Years;
}

final class _Cadence {
  factory _Cadence.of(ScheduleExpr expr, DateTime? starting) {
    if (expr case SingleDate(date: IsoDate(:final date))) {
      return _Cadence._(_Unit.day, parseIsoDate(date), 1, single: true);
    }
    final (unit, interval) = switch (expr) {
      IntervalRepeat() => (_Unit.day, 1),
      DayRepeat(:final interval) => (_Unit.day, interval),
      WeekRepeat(:final interval) => (_Unit.week, interval),
      MonthRepeat(:final interval) => (_Unit.month, interval),
      YearRepeat(:final interval) => (_Unit.year, interval),
      SingleDate() => (_Unit.year, 1),
    };
    final anchor = starting ?? (unit == _Unit.week ? _epochMonday : _epochDate);
    final origin = switch (unit) {
      _Unit.day => anchor,
      _Unit.week => mondayOfWeek(anchor),
      _Unit.month => DateTime.utc(anchor.year, anchor.month),
      _Unit.year => DateTime.utc(anchor.year),
    };
    return _Cadence._(unit, origin, interval);
  }

  _Cadence._(this._unit, this._origin, this._interval, {bool single = false})
    : _single = single;

  final _Unit _unit;
  final DateTime _origin;
  final int _interval;

  final bool _single;

  int periodOf(DateTime date) => switch (_unit) {
    _Unit.day => daysBetween(_origin, date),
    _Unit.week => floorDiv(daysBetween(_origin, date), 7),
    _Unit.month => monthsBetween(_origin, date),
    _Unit.year => date.year - _origin.year,
  };

  DateTime startOf(int k) => switch (_unit) {
    _Unit.day => addDays(_origin, k),
    _Unit.week => addDays(_origin, 7 * k),
    _Unit.month => firstOfMonthIndex(monthIndex(_origin) + k),
    _Unit.year => DateTime.utc(_origin.year + k),
  };

  /// Through one search horizon beyond the farther of [firstPeriod] and
  /// [reach] (spec/README.md, "Search horizon").
  Iterable<DateTime> periodStarts(
    int firstPeriod,
    int reach,
    _Direction direction,
  ) sync* {
    if (_single) {
      yield _origin;
      return;
    }
    final first = align(firstPeriod, direction);
    final beyond = direction.sign * (align(reach, direction) - first);
    final count =
        horizonPeriods + _horizonMarginPeriods + max(beyond, 0) ~/ _interval;
    final step = direction.sign * _interval;
    final edgeDay = switch (direction) {
      _Direction.forward => _calendarEnd,
      _Direction.backward => _calendarStart,
    };
    final edge = periodOf(edgeDay) + direction.sign;
    for (var i = 0; i < count; i++) {
      final k = first + i * step;
      if (direction.precedes(edge, k)) return;
      yield startOf(k);
    }
  }

  int align(int k, _Direction direction) => switch (direction) {
    _Direction.forward => k + (-k) % _interval,
    _Direction.backward => k - k % _interval,
  };

  /// Aligned periods in lcm(400 years, interval units), after which both the
  /// calendar and the alignment repeat.
  int get horizonPeriods =>
      _unit.per400Years ~/ _unit.per400Years.gcd(_interval);
}

/// A date the expression fires on, with the month whose day it names. They
/// differ only when a directional nearest weekday crosses into the adjacent
/// month.
typedef _Candidate = ({DateTime date, int targetMonth});

List<_Candidate> _candidatesInPeriod(ScheduleExpr expr, DateTime start) => [
  for (final date in _datesInPeriod(expr, start))
    (date: date, targetMonth: expr is MonthRepeat ? start.month : date.month),
];

List<DateTime> _datesInPeriod(ScheduleExpr expr, DateTime start) =>
    switch (expr) {
      IntervalRepeat(:final dayFilter) => [
        if (dayFilter == null || matchesDayFilter(start, dayFilter)) start,
      ],
      DayRepeat(:final days) => [if (matchesDayFilter(start, days)) start],
      WeekRepeat(:final days) => [
        for (final day in days.toSet())
          addDays(start, day.number - DateTime.monday),
      ]..sort(),
      MonthRepeat(:final target) => monthTargetDates(
        start.year,
        start.month,
        target,
      ),
      YearRepeat(:final target) => [?yearTargetDate(start.year, target)],
      SingleDate(date: NamedDate(:final month, :final day)) => [
        ?validDate(start.year, month.number, day),
      ],
      SingleDate(date: IsoDate()) => [start],
    };
