from __future__ import annotations

from bisect import bisect_right
from collections.abc import Callable, Iterable, Iterator
from dataclasses import dataclass
from datetime import MAXYEAR, MINYEAR, UTC, date, datetime, time, timedelta
from enum import Enum
from itertools import islice, takewhile
from math import gcd
from typing import Any, ClassVar, NamedTuple, TypeVar
from zoneinfo import ZoneInfo

from ._ast import (
    DayFilter,
    DayFilterEvery,
    DayRepeat,
    IntervalRepeat,
    IntervalUnit,
    IsoDate,
    IsoException,
    IsoUntil,
    MonthRepeat,
    NamedDate,
    NamedException,
    NamedUntil,
    ScheduleData,
    ScheduleExpr,
    SingleDateExpr,
    TimeOfDay,
    UntilSpec,
    WeekRepeat,
    YearRepeat,
)
from ._calendar import (
    DAYS_PER_400_YEARS,
    YearMonth,
    add_days,
    date_if_valid,
    days_between,
    days_in_month,
    matches_day_filter,
    monday_of_week,
    month_index,
    month_target_dates,
    year_month,
    year_target_date,
)
from ._wall_clock import (
    MINUTES_PER_HOUR,
    civil_time,
    first_pass_wall_time,
    fixed_time_on,
    minute_of_day,
    resolve_zone,
    slot_on,
)

# Default anchor for week intervals (spec/README.md, "WeekRepeat epoch alignment").
_EPOCH_MONDAY = date(1970, 1, 5)

# Default anchor for day, month and year intervals.
_EPOCH_DATE = date(1970, 1, 1)

# spec/README.md, "Supported range": from _RANGE_START inclusive to _RANGE_END exclusive.
_RANGE_START = datetime(1, 1, 2, tzinfo=UTC)
_RANGE_END = datetime(9999, 12, 30, tzinfo=UTC)

# Slack beyond the horizon for the period one behind the first date's, where a search
# starts, and for a horizon that starts mid-period.
_HORIZON_MARGIN_PERIODS = 2

# How many dates past its scheduled date an occurrence can land: a fixed time shifted out
# of a gap before midnight lands on the next date.
_MAX_SHIFT_DAYS = 1

# Feb 29 can be eight years away, as from 2096-03-01 to 2104-02-29.
_NAMED_UNTIL_MAX_YEARS = 8

_T = TypeVar("_T")


class PreparedSchedule:
    """A schedule's data with its search prepared once. ScheduleData is mutable, so the
    search is prepared again whenever the data's fields change."""

    __slots__ = ("data", "_key", "_search")

    def __init__(self, data: ScheduleData) -> None:
        self.data = data
        self._key: tuple[object, ...] | None = None
        self._search: Search | None = None

    def search(self) -> Search:
        data = self.data
        key = (data.expr, data.timezone, data.except_, data.until, data.anchor, data.during)
        if self._search is None or key != self._key:
            self._search, self._key = Search.of(data), key
        return self._search


def next_from(schedule: PreparedSchedule, now: datetime) -> datetime | None:
    if not _in_supported_range(now):
        return None
    return schedule.search().nearest(now, _Direction.FORWARD)


def previous_from(schedule: PreparedSchedule, now: datetime) -> datetime | None:
    if not _in_supported_range(now):
        return None
    return schedule.search().nearest(now, _Direction.BACKWARD)


def matches(schedule: PreparedSchedule, dt: datetime) -> bool:
    """True when the minute containing `dt`, on the schedule's wall clock, is an occurrence
    (spec/README.md, "matches is true exactly when the minute containing t is an
    occurrence"). Defined through the forward search, so the two can never disagree."""
    if not _in_supported_range(dt):
        return False
    search = schedule.search()
    minute = dt.astimezone(search.zone).replace(second=0, microsecond=0).astimezone(UTC)
    found = search.nearest(minute - timedelta(microseconds=1), _Direction.FORWARD)
    return found is not None and found.astimezone(UTC) == minute


def next_n_from(schedule: PreparedSchedule, now: datetime, n: int) -> list[datetime]:
    return list(islice(occurrences(schedule, now), max(n, 0)))


def occurrences(schedule: PreparedSchedule, from_: datetime) -> Iterator[datetime]:
    if not _in_supported_range(from_):
        return
    search = schedule.search()
    current = search.nearest(from_, _Direction.FORWARD)
    while current is not None:
        yield current
        current = search.nearest(current, _Direction.FORWARD)


def between(schedule: PreparedSchedule, from_: datetime, to: datetime) -> Iterator[datetime]:
    if not _in_supported_range(to):
        return iter(())
    end = to.astimezone(UTC)
    return takewhile(lambda t: t <= end, occurrences(schedule, from_))


def _in_supported_range(t: datetime) -> bool:
    try:
        return _RANGE_START <= t.astimezone(UTC) < _RANGE_END
    except OverflowError:
        return False


class _Direction(Enum):
    FORWARD = 1
    BACKWARD = -1

    def __init__(self, sign: int) -> None:
        self.sign = sign

    def precedes(self, a: datetime, b: datetime) -> bool:
        """Whether `a` comes before `b` in this direction."""
        return a < b if self is _Direction.FORWARD else a > b


def _in_order(items: list[_T], direction: _Direction) -> Iterable[_T]:
    return items if direction is _Direction.FORWARD else reversed(items)


@dataclass(frozen=True, slots=True)
class Search:
    """A schedule prepared for searching: its zone, cadence, times and clauses resolved
    once. Instants, `now` among them, are UTC datetimes until one is returned (see
    _wall_clock); comparing one with a zoned datetime would also cost a zone lookup."""

    zone: ZoneInfo
    cadence: _Cadence
    candidates_in_period: _CandidatesInPeriod
    times: _DailyTimes
    clauses: _Clauses

    @classmethod
    def of(cls, schedule: ScheduleData) -> Search:
        expr = schedule.expr
        starting = date.fromisoformat(schedule.anchor) if schedule.anchor else None
        during = frozenset(month.number for month in schedule.during)
        return cls(
            zone=resolve_zone(schedule.timezone),
            cadence=_Cadence.of(expr, starting, during),
            candidates_in_period=_candidates_in_period_of(expr),
            times=_daily_times(expr),
            clauses=_Clauses.of(schedule, starting, during),
        )

    def nearest(self, now: datetime, direction: _Direction) -> datetime | None:
        """The occurrence nearest `now` strictly beyond it in `direction`."""
        best = self._best(now.astimezone(UTC), direction)
        if best is None or not _in_supported_range(best.instant):
            return None
        return best.instant.astimezone(self.zone)

    def _best(self, now: datetime, direction: _Direction) -> _Occurrence | None:
        now_date = now.astimezone(self.zone).date()
        first_date = self.clauses.clamp(now_date, direction)
        # A nearest weekday or a DST shift can move an occurrence out of the period it is
        # scheduled in, so the search starts one period back.
        first_period = self.cadence.period_of(first_date) - direction.sign
        farthest = self.clauses.farthest_except_date(direction)
        reach = first_period if farthest is None else self.cadence.period_of(farthest)
        max_shift_days = self.times.max_shift_days
        best: _Occurrence | None = None
        for start in self.cadence.period_starts(first_period, reach, direction):
            for candidate in _in_order(self.candidates_in_period(start), direction):
                d = candidate.date
                if best is not None and not _could_beat(d, best.landing, direction, max_shift_days):
                    return best
                if self.clauses.ends_search(d, direction):
                    return best
                if _behind(d, now_date, direction) or not self.clauses.allows(candidate):
                    continue
                instant = self.nearest_on_date(d, now, direction)
                if instant is not None and (
                    best is None or direction.precedes(instant, best.instant)
                ):
                    best = _Occurrence(instant, instant.astimezone(self.zone).date())
        return best

    def nearest_on_date(self, d: date, now: datetime, direction: _Direction) -> datetime | None:
        """The occurrence on `d` nearest `now` strictly beyond it in `direction`."""
        match self.times:
            case _FixedTimes(times=times):
                resolved = [fixed_time_on(d, t, self.zone) for t in times]
                # A time shifted out of a gap can land after a later wall time.
                instants = sorted([t for t in resolved if t is not None])
                if direction is _Direction.FORWARD:
                    return next((t for t in instants if t > now), None)
                return next((t for t in reversed(instants) if t < now), None)
            case _Slots(minutes=minutes) if direction is _Direction.FORWARD:
                return self._first_slot_after(minutes, d, now)
            case _Slots(minutes=minutes):
                return self._last_slot_before(minutes, d, now)

    def _first_slot_after(
        self, minutes: tuple[int, ...], d: date, now: datetime
    ) -> datetime | None:
        """Slots resolve in wall-clock order, and one whose wall time is not after now's has
        passed, so the scan can start after now's wall time."""
        local = now.astimezone(self.zone)
        if d < local.date():
            return None
        if d == local.date():
            minutes = minutes[bisect_right(minutes, minute_of_day(local.time())) :]
        for minute in minutes:
            instant = slot_on(d, minute, self.zone)
            if instant is not None and instant > now:
                return instant
        return None

    def _last_slot_before(
        self, minutes: tuple[int, ...], d: date, now: datetime
    ) -> datetime | None:
        """Unlike the forward scan, this one cannot start at now's wall time: from the
        second pass of a fall-back overlap, a slot with a later wall time, even on the next
        date, can be earlier than now. It starts at now's first-pass wall time instead."""
        latest = first_pass_wall_time(now.astimezone(self.zone))
        if d > latest.date():
            return None
        if d == latest.date():
            minutes = minutes[: bisect_right(minutes, minute_of_day(latest.time()))]
        for minute in reversed(minutes):
            instant = slot_on(d, minute, self.zone)
            if instant is not None and instant < now:
                return instant
        return None


@dataclass(frozen=True, slots=True)
class _Occurrence:
    """An occurrence a search found, with the local date it lands on."""

    instant: datetime
    landing: date


def _could_beat(d: date, landing: date, direction: _Direction, max_shift_days: int) -> bool:
    """Whether an occurrence scheduled on `d` can precede, in `direction`, the best one,
    which landed on `landing`."""
    # An occurrence lands from its own date to max_shift_days after it, always on a first
    # pass, and first-pass instants keep wall-clock order.
    if direction is _Direction.FORWARD:
        return d <= landing
    return (landing - d).days <= max_shift_days


def _behind(d: date, now_date: date, direction: _Direction) -> bool:
    """Whether no occurrence scheduled on `d` can be beyond now in `direction`: a shifted
    time lands at most _MAX_SHIFT_DAYS after its date, and from the second pass of a
    fall-back across midnight, now's date is at most one behind a date that has begun."""
    return direction.sign * (now_date - d).days > _MAX_SHIFT_DAYS


@dataclass(frozen=True, slots=True)
class _FixedTimes:
    """Fixed times of day, each shifted out of a gap, which can carry it onto the next date."""

    times: tuple[time, ...]
    max_shift_days: ClassVar[int] = _MAX_SHIFT_DAYS


@dataclass(frozen=True, slots=True)
class _Slots:
    """Interval slots in minutes after midnight, each skipped in a gap, so one always lands
    on its own date."""

    minutes: tuple[int, ...]
    max_shift_days: ClassVar[int] = 0


_DailyTimes = _FixedTimes | _Slots


def _daily_times(expr: ScheduleExpr) -> _DailyTimes:
    match expr:
        case IntervalRepeat(interval=interval, unit=unit, from_time=start, to_time=end):
            return _Slots(_interval_slots(interval, unit, start, end))
        case _:
            return _FixedTimes(tuple(civil_time(t) for t in expr.times))


def _interval_slots(
    interval: int, unit: IntervalUnit, start: TimeOfDay, end: TimeOfDay
) -> tuple[int, ...]:
    """Wall-clock minutes of the slots `start + k × interval` up to and including `end`."""
    step = max(interval, 1) * (1 if unit == IntervalUnit.MIN else MINUTES_PER_HOUR)
    first = minute_of_day(civil_time(start))
    return tuple(range(first, minute_of_day(civil_time(end)) + 1, step))


@dataclass(frozen=True, slots=True)
class _Clauses:
    """The trailing clauses, resolved once. `during` applies to a candidate's target month;
    `except`, `until` and `starting` to its date (spec/README.md, "Nearest weekday and
    `during`", "The `starting` clause")."""

    during: frozenset[int]
    except_month_days: frozenset[tuple[int, int]]
    except_dates: frozenset[date]
    until: date | None
    starting: date | None

    @classmethod
    def of(cls, schedule: ScheduleData, starting: date | None, during: frozenset[int]) -> _Clauses:
        exceptions = schedule.except_
        return cls(
            during=during,
            except_month_days=frozenset(
                (e.month.number, e.day) for e in exceptions if isinstance(e, NamedException)
            ),
            except_dates=frozenset(
                date.fromisoformat(e.date) for e in exceptions if isinstance(e, IsoException)
            ),
            until=None if schedule.until is None else _resolve_until(schedule.until, starting),
            starting=starting,
        )

    def allows(self, candidate: _Candidate) -> bool:
        d = candidate.date
        return (
            (not self.during or candidate.target_month in self.during)
            and (d.month, d.day) not in self.except_month_days
            and d not in self.except_dates
            and (self.until is None or d <= self.until)
            and (self.starting is None or d >= self.starting)
        )

    def farthest_except_date(self, direction: _Direction) -> date | None:
        """The one-off except date farthest along `direction`: the calendar repeats only
        beyond it (spec/README.md, "Search horizon")."""
        if not self.except_dates:
            return None
        return max(self.except_dates) if direction is _Direction.FORWARD else min(self.except_dates)

    def clamp(self, d: date, direction: _Direction) -> date:
        """The date a search starts from: nothing fires before `starting` or after `until`."""
        if direction is _Direction.FORWARD:
            return d if self.starting is None else max(d, self.starting)
        return d if self.until is None else min(d, self.until)

    def ends_search(self, d: date, direction: _Direction) -> bool:
        """Whether `d`, and every date beyond it in `direction`, is past the bound the
        search moves toward."""
        if direction is _Direction.FORWARD:
            return self.until is not None and d > self.until
        return self.starting is not None and d < self.starting


def _resolve_until(until: UntilSpec, starting: date | None) -> date | None:
    """A named until date is the first such date on or after the starting date
    (spec/README.md, "Named `until`"). Parse requires `starting`; a schedule built without
    one resolves from the default anchor, the epoch. None when no such date exists before the
    calendar ends, so nothing bounds the schedule."""
    match until:
        case IsoUntil(date=iso):
            return date.fromisoformat(iso)
        case NamedUntil(month=month, day=day):
            start = starting or _EPOCH_DATE
            last_year = min(start.year + _NAMED_UNTIL_MAX_YEARS, MAXYEAR)
            dates = (
                date_if_valid(year, month.number, day) for year in range(start.year, last_year + 1)
            )
            return next((d for d in dates if d is not None and d >= start), None)


class _Unit(Enum):
    DAY = DAYS_PER_400_YEARS
    WEEK = DAYS_PER_400_YEARS // 7
    MONTH = 400 * 12
    YEAR = 400

    @property
    def per_400_years(self) -> int:
        """Units in 400 years, after which the proleptic Gregorian calendar repeats."""
        return self.value


@dataclass(frozen=True, slots=True)
class _Cadence:
    """The periods (days, weeks, months or years) an expression fires in, numbered from
    `origin`: period `k` is aligned when `k` is a multiple of `interval`."""

    unit: _Unit
    origin: date
    interval: int
    # The months `during` keeps, for a cadence of days or months, whose candidates all
    # target their period's own month. period_starts steps over the other months: the
    # clauses would reject every candidate there, and the search's stop checks only become
    # true further along, so the result is the same and a schedule that never fires does
    # not walk every day of its horizon.
    months: frozenset[int]
    # A single ISO date has one period, the one holding that date.
    single: bool
    # Aligned periods in lcm(400 years, interval units), after which both the calendar and
    # the alignment repeat, plus _HORIZON_MARGIN_PERIODS.
    horizon: int

    @classmethod
    def of(cls, expr: ScheduleExpr, starting: date | None, during: frozenset[int]) -> _Cadence:
        anchor = starting
        match expr:
            case SingleDateExpr(date=IsoDate(date=iso)):
                unit, interval, anchor = _Unit.DAY, 1, date.fromisoformat(iso)
            case SingleDateExpr():
                unit, interval = _Unit.YEAR, 1
            case IntervalRepeat():
                unit, interval = _Unit.DAY, 1
            case DayRepeat(interval=interval):
                unit = _Unit.DAY
            case WeekRepeat(interval=interval):
                unit = _Unit.WEEK
            case MonthRepeat(interval=interval):
                unit = _Unit.MONTH
            case YearRepeat(interval=interval):
                unit = _Unit.YEAR
        anchor = anchor or (_EPOCH_MONDAY if unit is _Unit.WEEK else _EPOCH_DATE)
        match unit:
            case _Unit.DAY:
                origin = anchor
            case _Unit.WEEK:
                origin = monday_of_week(anchor)
            case _Unit.MONTH:
                origin = anchor.replace(day=1)
            case _Unit.YEAR:
                origin = anchor.replace(month=1, day=1)
        interval = max(interval, 1)
        return cls(
            unit=unit,
            origin=origin,
            interval=interval,
            months=during if unit in (_Unit.DAY, _Unit.MONTH) else frozenset(),
            single=isinstance(expr, SingleDateExpr) and isinstance(expr.date, IsoDate),
            horizon=unit.per_400_years // gcd(unit.per_400_years, interval)
            + _HORIZON_MARGIN_PERIODS,
        )

    def period_of(self, d: date) -> int:
        match self.unit:
            case _Unit.DAY:
                return days_between(self.origin, d)
            case _Unit.WEEK:
                return days_between(self.origin, d) // 7
            case _Unit.MONTH:
                return month_index(d) - month_index(self.origin)
            case _Unit.YEAR:
                return d.year - self.origin.year

    def start_of(self, k: int) -> date | YearMonth | None:
        """The first day of period `k`, or the month for a monthly cadence. None beyond
        what `date` can hold, which for months starts a year earlier, in year 0."""
        match self.unit:
            case _Unit.DAY:
                return add_days(self.origin, k)
            case _Unit.WEEK:
                return add_days(self.origin, 7 * k)
            case _Unit.MONTH:
                return year_month(month_index(self.origin) + k)
            case _Unit.YEAR:
                year = self.origin.year + k
                return date(year, 1, 1) if MINYEAR <= year <= MAXYEAR else None

    def period_starts(
        self, first_period: int, reach: int, direction: _Direction
    ) -> Iterator[date | YearMonth]:
        """The starts of the aligned periods from `first_period` in `direction`, through one
        search horizon beyond whichever of `first_period` and `reach` is farther along it
        (spec/README.md, "Search horizon"), in the months the cadence keeps."""
        if self.single:
            first, count = 0, 1
        else:
            first = self.align(first_period, direction)
            beyond = direction.sign * (self.align(reach, direction) - first)
            count = self.horizon + max(beyond, 0) // self.interval
        step = direction.sign * self.interval
        k, end = first, first + count * step
        start = self.start_of(k)
        if start is None:
            # Only the period a search starts from, behind the first date's, can lie past
            # the calendar's edge with the calendar still ahead.
            k += step
            start = self.start_of(k)
        while start is not None and direction.sign * (end - k) > 0:
            if self.months and start.month not in self.months:
                k = self.align(k + self._to_next_month(start, direction), direction)
            else:
                yield start
                k += step
            start = self.start_of(k)

    def _to_next_month(self, start: date | YearMonth, direction: _Direction) -> int:
        """The periods to step along `direction` from `start`, in a month the walk passes
        over: for a cadence of months to the next month it keeps, for days to the adjacent
        month."""
        if isinstance(start, YearMonth):
            return direction.sign * min(
                direction.sign * (m - start.month) % 12 for m in self.months
            )
        if direction is _Direction.FORWARD:
            return days_in_month(start.year, start.month) - start.day + 1
        return -start.day

    def align(self, k: int, direction: _Direction) -> int:
        """The first aligned period at or beyond period `k` in `direction`."""
        if direction is _Direction.FORWARD:
            return k + -k % self.interval
        return k - k % self.interval


class _Candidate(NamedTuple):
    """A date the expression fires on, with the month whose day it names. They differ only
    when a directional nearest weekday crosses into the adjacent month."""

    date: date
    target_month: int


# Takes the cadence's period start: a YearMonth for a monthly expression, a date otherwise.
_CandidatesInPeriod = Callable[[Any], list[_Candidate]]


def _candidates_in_period_of(expr: ScheduleExpr) -> _CandidatesInPeriod:
    """`expr`'s candidates in the period starting at a given start, earliest first."""
    match expr:
        case IntervalRepeat(day_filter=day_filter) | DayRepeat(days=day_filter):
            if day_filter is None or isinstance(day_filter, DayFilterEvery):
                return _the_day
            days: DayFilter = day_filter
            return lambda day: _the_day(day) if matches_day_filter(day, days) else []
        case WeekRepeat(days=weekdays):
            offsets = sorted({weekday.number - 1 for weekday in weekdays})
            return lambda monday: _candidates_on(add_days(monday, n) for n in offsets)
        case MonthRepeat(target=month_target):
            return lambda month: [
                _Candidate(d, month.month) for d in month_target_dates(month, month_target)
            ]
        case YearRepeat(target=year_target):
            return lambda first_day: _candidates_on([year_target_date(first_day.year, year_target)])
        case SingleDateExpr(date=NamedDate(month=month, day=day)):
            return lambda first_day: _candidates_on(
                [date_if_valid(first_day.year, month.number, day)]
            )
        case SingleDateExpr():
            return _the_day


def _the_day(day: date) -> list[_Candidate]:
    return [_Candidate(day, day.month)]


def _candidates_on(dates: Iterable[date | None]) -> list[_Candidate]:
    return [_Candidate(d, d.month) for d in dates if d is not None]
