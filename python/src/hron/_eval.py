from __future__ import annotations

import calendar
from collections.abc import Callable, Iterator
from dataclasses import dataclass
from datetime import MAXYEAR, MINYEAR, UTC, date, datetime, time, timedelta
from itertools import islice, takewhile
from math import gcd
from zoneinfo import ZoneInfo

from ._ast import (
    DateSpec,
    DayFilter,
    DayFilterDays,
    DayFilterEvery,
    DayFilterWeekday,
    DayFilterWeekend,
    DayRepeat,
    DaysTarget,
    ExceptionSpec,
    IntervalRepeat,
    IntervalUnit,
    IsoDate,
    IsoException,
    IsoUntil,
    LastDayTarget,
    LastWeekdayTarget,
    MonthName,
    MonthRepeat,
    MonthTarget,
    NamedDate,
    NamedException,
    NamedUntil,
    NearestDirection,
    NearestWeekdayTarget,
    OrdinalPosition,
    OrdinalWeekdayTarget,
    ScheduleData,
    ScheduleExpr,
    SingleDateExpr,
    TimeOfDay,
    UntilSpec,
    Weekday,
    WeekRepeat,
    YearDateTarget,
    YearDayOfMonthTarget,
    YearLastWeekdayTarget,
    YearOrdinalWeekdayTarget,
    YearRepeat,
    YearTarget,
    expand_month_target,
)


def _resolve_tz(tz_name: str | None) -> ZoneInfo:
    """Resolve timezone, defaulting to UTC for deterministic behavior."""
    return ZoneInfo(tz_name) if tz_name else ZoneInfo("UTC")


def _make_aware(d: date, t: time, tz: ZoneInfo) -> datetime:
    """Create a timezone-aware datetime with 'compatible' disambiguation (fold=0)."""
    naive = datetime.combine(d, t)
    return naive.replace(tzinfo=tz, fold=0)


_FIRST_INSTANT = datetime(1, 1, 2, tzinfo=UTC)
_END_INSTANT = datetime(9999, 12, 30, tzinfo=UTC)


def _supported_utc(dt: datetime) -> datetime | None:
    """`dt` as a UTC instant, or None outside the supported range (spec/README.md).

    Searches compare UTC instants because datetimes sharing one ZoneInfo compare by wall clock.
    """
    try:
        instant = dt.astimezone(UTC)
    except OverflowError:
        return None
    return instant if _FIRST_INSTANT <= instant < _END_INSTANT else None


def _at_time_on_date(d: date, tod: TimeOfDay, tz: ZoneInfo) -> datetime | None:
    """The instant a wall-clock time resolves to, or None outside the supported range."""
    aware = _make_aware(d, time(tod.hour, tod.minute), tz)
    # With fold=0, a time in a DST gap converts at the pre-gap offset, so the round-trip
    # shifts it forward by the gap length (02:30 becomes 03:30).
    instant = _supported_utc(aware)
    return None if instant is None else instant.astimezone(tz)


def _slot_on_date(d: date, minutes: int, tz: ZoneInfo) -> datetime | None:
    """Resolve an interval slot, or None when its wall time falls in a spring-forward gap."""
    resolved = _at_time_on_date(d, TimeOfDay(minutes // 60, minutes % 60), tz)
    if resolved is None or resolved.date() != d or resolved.hour * 60 + resolved.minute != minutes:
        return None
    return resolved


def _day_ends_in_gap(d: date, tz: ZoneInfo) -> bool:
    last_minute = _at_time_on_date(d, TimeOfDay(23, 59), tz)
    return last_minute is not None and last_minute.date() != d


def _matches_day_filter(d: date, f: DayFilter) -> bool:
    dow = d.isoweekday()  # Monday=1 ... Sunday=7
    match f:
        case DayFilterEvery():
            return True
        case DayFilterWeekday():
            return 1 <= dow <= 5
        case DayFilterWeekend():
            return dow in (6, 7)
        case DayFilterDays(days=days):
            return any(wd.number == dow for wd in days)


def _date_if_valid(year: int, month: int, day: int) -> date | None:
    try:
        return date(year, month, day)
    except ValueError:
        return None


def _proleptic_ordinal(year: int, month: int, day: int) -> int:
    """`date.toordinal()`, extended to the years just outside Python's calendar."""
    cycles = 0 if MINYEAR <= year <= MAXYEAR else (year - 2000) // 400
    return date(year - 400 * cycles, month, day).toordinal() + cycles * _DAYS_PER_400_YEARS


def _last_day_of_month(year: int, month: int) -> date:
    _, last = calendar.monthrange(year, month)
    return date(year, month, last)


def _last_weekday_of_month(year: int, month: int) -> date:
    d = _last_day_of_month(year, month)
    while d.isoweekday() in (6, 7):
        d -= timedelta(days=1)
    return d


def _nth_weekday_of_month(year: int, month: int, weekday: Weekday, n: int) -> date | None:
    first_dow = calendar.weekday(year, month, 1) + 1
    return _date_if_valid(year, month, 1 + (weekday.number - first_dow) % 7 + 7 * (n - 1))


def _last_weekday_in_month(year: int, month: int, weekday: Weekday) -> date:
    last = _last_day_of_month(year, month)
    return last - timedelta(days=(last.isoweekday() - weekday.number) % 7)


def _ordinal_weekday(
    year: int, month: int, ordinal: OrdinalPosition, weekday: Weekday
) -> date | None:
    if ordinal == OrdinalPosition.LAST:
        return _last_weekday_in_month(year, month, weekday)
    return _nth_weekday_of_month(year, month, weekday, ordinal.to_n())


def _nearest_weekday(
    year: int, month: int, target_day: int, direction: NearestDirection | None
) -> date | None:
    """The nearest weekday to target_day, or None if the month has no such day or the
    weekday falls outside Python's calendar. The year may be 0 or 10000.
    """
    last_day = calendar.monthrange(year, month)[1]
    if target_day > last_day:
        return None

    # Without a direction the weekday stays in the month, as with cron's W.
    shift = 0
    match calendar.weekday(year, month, target_day):
        case calendar.SATURDAY:
            to_monday = direction == NearestDirection.NEXT or (
                direction is None and target_day == 1
            )
            shift = 2 if to_monday else -1
        case calendar.SUNDAY:
            to_friday = direction == NearestDirection.PREVIOUS or (
                direction is None and target_day == last_day
            )
            shift = -2 if to_friday else 1

    ordinal = _proleptic_ordinal(year, month, target_day) + shift
    return date.fromordinal(ordinal) if 1 <= ordinal <= date.max.toordinal() else None


def _month_target_dates(target: MonthTarget, year: int, month: int) -> list[date]:
    if not MINYEAR <= year <= MAXYEAR and not isinstance(target, NearestWeekdayTarget):
        return []
    match target:
        case DaysTarget():
            last_day = _last_day_of_month(year, month).day
            return [
                date(year, month, day) for day in expand_month_target(target) if day <= last_day
            ]
        case LastDayTarget():
            return [_last_day_of_month(year, month)]
        case LastWeekdayTarget():
            return [_last_weekday_of_month(year, month)]
        case NearestWeekdayTarget(day=target_day, direction=direction):
            nearest = _nearest_weekday(year, month, target_day, direction)
            return [] if nearest is None else [nearest]
        case OrdinalWeekdayTarget(ordinal=ordinal, weekday=weekday):
            ordinal_date = _ordinal_weekday(year, month, ordinal, weekday)
            return [] if ordinal_date is None else [ordinal_date]
    return []  # pragma: no cover


def _year_target_date(target: YearTarget, year: int) -> date | None:
    match target:
        case YearDateTarget(month=m, day=day) | YearDayOfMonthTarget(month=m, day=day):
            return _date_if_valid(year, m.number, day)
        case YearOrdinalWeekdayTarget(ordinal=ordinal, weekday=weekday, month=m):
            return _ordinal_weekday(year, m.number, ordinal, weekday)
        case YearLastWeekdayTarget(month=m):
            return _last_weekday_of_month(year, m.number)
    return None  # pragma: no cover


# Every day filter matches within a week, plus a day at each end for times that a gap or an
# overlap moves across midnight, and a day for a shifted time equal to `now`.
_DAYS_TO_SCAN = 7 + 3
# A skipped day (Pacific/Apia, 2011-12-30) loses its interval slots, so a weekly filter can
# next match a week later.
_INTERVAL_DAYS_TO_SCAN = _DAYS_TO_SCAN + 7
_EPOCH_DATE = date(1970, 1, 1)
_EPOCH_MONDAY = date(1970, 1, 5)
_DAYS_PER_400_YEARS = 146097


def _weeks_between(a: date, b: date) -> int:
    return (b - a).days // 7


def _days_between(a: date, b: date) -> int:
    return (b - a).days


def _month_index(d: date) -> int:
    return d.year * 12 + d.month - 1


def _month_start(index: int) -> date:
    year, month_of_year = divmod(index, 12)
    if not MINYEAR <= year <= MAXYEAR:
        # Ends the search the same way as date arithmetic past the calendar.
        raise OverflowError(f"year {year} is out of range")
    return date(year, month_of_year + 1, 1)


def _search_span_days(expr: ScheduleExpr) -> int:
    """lcm(400 years, the interval): the calendar and the schedule both repeat after it."""
    match expr:
        case DayRepeat(interval=interval):
            units_per_400_years = _DAYS_PER_400_YEARS
        case WeekRepeat(interval=interval):
            units_per_400_years = _DAYS_PER_400_YEARS // 7
        case MonthRepeat(interval=interval):
            units_per_400_years = 400 * 12
        case YearRepeat(interval=interval):
            units_per_400_years = 400
        case SingleDateExpr(date=IsoDate()):
            return (date.max - date.min).days
        case _:
            return _DAYS_PER_400_YEARS
    return _DAYS_PER_400_YEARS * (interval // gcd(units_per_400_years, interval))


def _add_days_clamped(d: date, days: int) -> date:
    try:
        return d + timedelta(days=days)
    except OverflowError:
        return date.max if days > 0 else date.min


def _parse_exceptions(
    exceptions: tuple[ExceptionSpec, ...],
) -> tuple[set[tuple[int, int]], set[date]]:
    named: set[tuple[int, int]] = set()
    iso_dates: set[date] = set()
    for exc in exceptions:
        match exc:
            case NamedException(month=m, day=day):
                named.add((m.number, day))
            case IsoException(date=iso_str):
                iso_dates.add(date.fromisoformat(iso_str))
    return named, iso_dates


def _matches_during(d: date, during: tuple[MonthName, ...]) -> bool:
    if not during:
        return True
    return any(mn.number == d.month for mn in during)


def _next_during_month(d: date, during: tuple[MonthName, ...]) -> date:
    """The first day of the first month after d's that `during` names."""
    months = {mn.number for mn in during}
    index = _month_index(d) + 1
    while index % 12 + 1 not in months:
        index += 1
    return _month_start(index)


def _prev_during_month(d: date, during: tuple[MonthName, ...]) -> date:
    """The last day of the last month before d's that `during` names."""
    months = {mn.number for mn in during}
    index = _month_index(d) - 1
    while index % 12 + 1 not in months:
        index -= 1
    return _month_start(index + 1) - timedelta(days=1)


def _resolve_until(until: UntilSpec, now: datetime) -> date:
    match until:
        case IsoUntil(date=iso_str):
            return date.fromisoformat(iso_str)
        case NamedUntil(month=m, day=day):
            # Feb 29 recurs within 8 years.
            for year in range(now.year, now.year + 9):
                d = _date_if_valid(year, m.number, day)
                if d is not None and d >= now.date():
                    return d
            return date.max


@dataclass(frozen=True)
class _Clauses:
    """The trailing clauses, which check an occurrence's scheduled date."""

    until: date | None
    starting: date | None
    during: tuple[MonthName, ...]
    named_exceptions: set[tuple[int, int]]
    iso_exceptions: set[date]

    def rejects(self, d: date) -> bool:
        return (
            not _matches_during(d, self.during)
            or (d.month, d.day) in self.named_exceptions
            or d in self.iso_exceptions
        )

    def after_rejected(self, d: date) -> date:
        if _matches_during(d, self.during):
            return d + timedelta(days=1)
        return _next_during_month(d, self.during)

    def before_rejected(self, d: date) -> date:
        if _matches_during(d, self.during):
            return d - timedelta(days=1)
        return _prev_during_month(d, self.during)


def _clauses(schedule: ScheduleData, now_in_tz: datetime) -> _Clauses:
    named, iso_dates = _parse_exceptions(schedule.except_)
    return _Clauses(
        until=_resolve_until(schedule.until, now_in_tz) if schedule.until else None,
        starting=date.fromisoformat(schedule.anchor) if schedule.anchor else None,
        # A month repeat applies `during` itself, to the month it targets, which a nearest
        # weekday can leave; every other expression applies it to the scheduled date.
        during=() if isinstance(schedule.expr, MonthRepeat) else schedule.during,
        named_exceptions=named,
        iso_exceptions=iso_dates,
    )


# An occurrence and its scheduled date: the date whose wall-clock time it resolves, which
# the trailing clauses check even when a gap shifts it onto the next date. The occurrence is
# None when the clauses reject that date, which is checked before resolving any time.
_Found = tuple[datetime | None, date]
_Rejects = Callable[[date], bool]


def _earliest_on(
    d: date, times: tuple[TimeOfDay, ...], tz: ZoneInfo, now: datetime
) -> _Found | None:
    resolved = (_at_time_on_date(d, tod, tz) for tod in times)
    future = [c for c in resolved if c is not None and c > now]
    return (min(future), d) if future else None


def _latest_on(d: date, times: tuple[TimeOfDay, ...], tz: ZoneInfo, now: datetime) -> _Found | None:
    resolved = (_at_time_on_date(d, tod, tz) for tod in times)
    past = [c for c in resolved if c is not None and c < now]
    return (max(past), d) if past else None


def next_from(schedule: ScheduleData, now: datetime) -> datetime | None:
    instant = _supported_utc(now)
    return None if instant is None else _next(schedule, instant)


def _next(schedule: ScheduleData, now: datetime) -> datetime | None:
    tz = _resolve_tz(schedule.timezone)
    now_in_tz = now.astimezone(tz)
    clauses = _clauses(schedule, now_in_tz)

    # A time shifted past midnight by a gap lands on the date after its scheduled date.
    start = _add_days_clamped(now_in_tz.date(), -1)
    if clauses.starting is not None and clauses.starting > start:
        start = clauses.starting
    limit = _add_days_clamped(max(start, now_in_tz.date()), _search_span_days(schedule.expr))
    shifted: datetime | None = None

    try:
        while found := _next_expr(
            schedule.expr, tz, schedule.anchor, now, start, schedule.during, limit, clauses.rejects
        ):
            candidate, scheduled = found
            if scheduled > limit or (clauses.until is not None and scheduled > clauses.until):
                break
            if candidate is None:
                start = clauses.after_rejected(scheduled)
                continue
            if shifted is not None:
                return min(shifted, candidate)
            if candidate.date() == scheduled:
                return candidate
            # The next date's own times can come before this shifted one.
            shifted = candidate
            start = scheduled + timedelta(days=1)
    except OverflowError:
        pass
    return shifted


def _next_expr(
    expr: ScheduleExpr,
    tz: ZoneInfo,
    anchor: str | None,
    now: datetime,
    start: date,
    during: tuple[MonthName, ...],
    limit: date,
    rejects: _Rejects,
) -> _Found | None:
    """The first occurrence after `now` whose scheduled date is on or after `start`."""
    match expr:
        case DayRepeat(interval=interval, days=days, times=times):
            return _next_day_repeat(interval, days, times, tz, anchor, now, start, rejects)
        case IntervalRepeat(
            interval=interval,
            unit=unit,
            from_time=ft,
            to_time=tt,
            day_filter=df,
        ):
            return _next_interval_repeat(interval, unit, ft, tt, df, tz, now, start, rejects)
        case WeekRepeat(interval=interval, days=days, times=times):
            return _next_week_repeat(interval, days, times, tz, anchor, now, start, rejects)
        case MonthRepeat(interval=interval, target=target, times=times):
            return _next_month_repeat(
                interval, target, times, tz, anchor, now, start, during, limit, rejects
            )
        case SingleDateExpr(date=date_spec, times=times):
            return _next_single_date(date_spec, times, tz, now, start, limit, rejects)
        case YearRepeat(interval=interval, target=target, times=times):
            return _next_year_repeat(
                interval, target, times, tz, anchor, now, start, limit, rejects
            )
    return None  # pragma: no cover


def next_n_from(schedule: ScheduleData, now: datetime, n: int) -> list[datetime]:
    return list(islice(occurrences(schedule, now), max(n, 0)))


def matches(schedule: ScheduleData, dt: datetime) -> bool:
    """True when the minute containing `dt`, on the schedule's wall clock, is an occurrence."""
    instant = _supported_utc(dt)
    if instant is None:
        return False
    tz = _resolve_tz(schedule.timezone)
    minute_start = instant.astimezone(tz).replace(second=0, microsecond=0).astimezone(UTC)
    latest = _previous(schedule, minute_start + timedelta(minutes=1))
    return latest is not None and latest.astimezone(UTC) == minute_start


def _next_day_repeat(
    interval: int,
    days: DayFilter,
    times: tuple[TimeOfDay, ...],
    tz: ZoneInfo,
    anchor: str | None,
    now: datetime,
    start: date,
    rejects: _Rejects,
) -> _Found | None:
    d = start
    if interval > 1:
        anchor_date = date.fromisoformat(anchor) if anchor else _EPOCH_DATE
        d += timedelta(days=_days_between(d, anchor_date) % interval)

    for _ in range(_DAYS_TO_SCAN):
        if _matches_day_filter(d, days):
            if rejects(d):
                return None, d
            if found := _earliest_on(d, times, tz, now):
                return found
        d += timedelta(days=interval)

    return None


def _next_interval_repeat(
    interval: int,
    unit: IntervalUnit,
    from_time: TimeOfDay,
    to_time: TimeOfDay,
    day_filter: DayFilter | None,
    tz: ZoneInfo,
    now: datetime,
    start: date,
    rejects: _Rejects,
) -> _Found | None:
    now_in_tz = now.astimezone(tz)
    step_minutes = interval if unit == IntervalUnit.MIN else interval * 60
    from_minutes = from_time.hour * 60 + from_time.minute
    to_minutes = to_time.hour * 60 + to_time.minute
    now_minutes = now_in_tz.hour * 60 + now_in_tz.minute

    d = start
    for _ in range(_INTERVAL_DAYS_TO_SCAN):
        if day_filter is None or _matches_day_filter(d, day_filter):
            if rejects(d):
                return None, d
            elapsed = now_minutes + _days_between(d, now_in_tz.date()) * 1440 - from_minutes
            first_slot = from_minutes + max(elapsed, 0) // step_minutes * step_minutes
            for minutes in range(first_slot, to_minutes + 1, step_minutes):
                slot = _slot_on_date(d, minutes, tz)
                if slot is not None and slot > now:
                    return slot, d
        d += timedelta(days=1)

    return None


def _next_week_repeat(
    interval: int,
    days: tuple[Weekday, ...],
    times: tuple[TimeOfDay, ...],
    tz: ZoneInfo,
    anchor: str | None,
    now: datetime,
    start: date,
    rejects: _Rejects,
) -> _Found | None:
    anchor_date = date.fromisoformat(anchor) if anchor else _EPOCH_MONDAY
    anchor_monday = anchor_date - timedelta(days=anchor_date.isoweekday() - 1)

    monday = start - timedelta(days=start.isoweekday() - 1)
    monday += timedelta(weeks=_weeks_between(monday, anchor_monday) % interval)

    sorted_days = sorted(days, key=lambda wd: wd.number)
    for _ in range(3):
        for wd in sorted_days:
            d = monday + timedelta(days=wd.number - 1)
            if d < start:
                continue
            if rejects(d):
                return None, d
            if found := _earliest_on(d, times, tz, now):
                return found
        monday += timedelta(weeks=interval)

    return None


def _next_month_repeat(
    interval: int,
    target: MonthTarget,
    times: tuple[TimeOfDay, ...],
    tz: ZoneInfo,
    anchor: str | None,
    now: datetime,
    start: date,
    during: tuple[MonthName, ...],
    limit: date,
    rejects: _Rejects,
) -> _Found | None:
    anchor_month = _month_index(date.fromisoformat(anchor) if anchor else _EPOCH_DATE)
    during_months = {mn.number for mn in during}

    # `next nearest weekday` can land in the month after its target, so start a month early.
    month = _month_index(start) - 1
    month += (anchor_month - month) % interval

    while month <= _month_index(limit) + 1:
        year, month_of_year = divmod(month, 12)
        if not during_months or month_of_year + 1 in during_months:
            for d in sorted(_month_target_dates(target, year, month_of_year + 1)):
                if d < start:
                    continue
                if rejects(d):
                    return None, d
                if found := _earliest_on(d, times, tz, now):
                    return found
        month += interval

    return None


def _next_single_date(
    date_spec: DateSpec,
    times: tuple[TimeOfDay, ...],
    tz: ZoneInfo,
    now: datetime,
    start: date,
    limit: date,
    rejects: _Rejects,
) -> _Found | None:
    match date_spec:
        case IsoDate(date=iso_str):
            d = date.fromisoformat(iso_str)
            if d < start:
                return None
            return (None, d) if rejects(d) else _earliest_on(d, times, tz, now)
        case NamedDate(month=m, day=day):
            for year in range(start.year, limit.year + 1):
                d = _date_if_valid(year, m.number, day)
                if d is None or d < start:
                    continue
                if rejects(d):
                    return None, d
                if found := _earliest_on(d, times, tz, now):
                    return found
            return None

    return None  # pragma: no cover


def _next_year_repeat(
    interval: int,
    target: YearTarget,
    times: tuple[TimeOfDay, ...],
    tz: ZoneInfo,
    anchor: str | None,
    now: datetime,
    start: date,
    limit: date,
    rejects: _Rejects,
) -> _Found | None:
    anchor_year = date.fromisoformat(anchor).year if anchor else _EPOCH_DATE.year

    year = start.year
    year += (anchor_year - year) % interval

    while year <= limit.year:
        d = _year_target_date(target, year)
        if d is not None and d >= start:
            if rejects(d):
                return None, d
            if found := _earliest_on(d, times, tz, now):
                return found
        year += interval

    return None


def occurrences(schedule: ScheduleData, from_: datetime) -> Iterator[datetime]:
    current = next_from(schedule, from_)
    while current is not None:
        yield current
        current = next_from(schedule, current)


def between(schedule: ScheduleData, from_: datetime, to: datetime) -> Iterator[datetime]:
    end = _supported_utc(to)
    if end is None:
        return iter(())
    return takewhile(lambda dt: dt <= end, occurrences(schedule, from_))


def previous_from(schedule: ScheduleData, now: datetime) -> datetime | None:
    instant = _supported_utc(now)
    return None if instant is None else _previous(schedule, instant)


def _previous(schedule: ScheduleData, now: datetime) -> datetime | None:
    tz = _resolve_tz(schedule.timezone)
    now_in_tz = now.astimezone(tz)
    clauses = _clauses(schedule, now_in_tz)

    # An overlap crossing midnight can put an earlier date's wall clock on a later occurrence.
    start = _add_days_clamped(now_in_tz.date(), 1)
    if clauses.until is not None and clauses.until < start:
        start = clauses.until
    limit = _add_days_clamped(min(start, now_in_tz.date()), -_search_span_days(schedule.expr))
    shifted_over: datetime | None = None

    try:
        while found := _prev_expr(
            schedule.expr, tz, schedule.anchor, now, start, schedule.during, limit, clauses.rejects
        ):
            candidate, scheduled = found
            if scheduled < limit or (clauses.starting is not None and scheduled < clauses.starting):
                break
            if candidate is None:
                start = clauses.before_rejected(scheduled)
                continue
            if shifted_over is not None:
                return max(shifted_over, candidate)
            if scheduled == date.min or not _day_ends_in_gap(scheduled - timedelta(days=1), tz):
                return candidate
            # A time of the date before, shifted past midnight, can come after this one.
            shifted_over = candidate
            start = scheduled - timedelta(days=1)
    except OverflowError:
        pass
    return shifted_over


def _prev_expr(
    expr: ScheduleExpr,
    tz: ZoneInfo,
    anchor: str | None,
    now: datetime,
    start: date,
    during: tuple[MonthName, ...],
    limit: date,
    rejects: _Rejects,
) -> _Found | None:
    """The last occurrence before `now` whose scheduled date is on or before `start`."""
    match expr:
        case DayRepeat(interval=interval, days=days, times=times):
            return _prev_day_repeat(interval, days, times, tz, anchor, now, start, rejects)
        case IntervalRepeat(
            interval=interval,
            unit=unit,
            from_time=ft,
            to_time=tt,
            day_filter=df,
        ):
            return _prev_interval_repeat(interval, unit, ft, tt, df, tz, now, start, rejects)
        case WeekRepeat(interval=interval, days=days, times=times):
            return _prev_week_repeat(interval, days, times, tz, anchor, now, start, rejects)
        case MonthRepeat(interval=interval, target=target, times=times):
            return _prev_month_repeat(
                interval, target, times, tz, anchor, now, start, during, limit, rejects
            )
        case SingleDateExpr(date=date_spec, times=times):
            return _prev_single_date(date_spec, times, tz, now, start, limit, rejects)
        case YearRepeat(interval=interval, target=target, times=times):
            return _prev_year_repeat(
                interval, target, times, tz, anchor, now, start, limit, rejects
            )
    return None  # pragma: no cover


def _prev_day_repeat(
    interval: int,
    days: DayFilter,
    times: tuple[TimeOfDay, ...],
    tz: ZoneInfo,
    anchor: str | None,
    now: datetime,
    start: date,
    rejects: _Rejects,
) -> _Found | None:
    d = start
    if interval > 1:
        anchor_date = date.fromisoformat(anchor) if anchor else _EPOCH_DATE
        d -= timedelta(days=_days_between(anchor_date, d) % interval)

    for _ in range(_DAYS_TO_SCAN):
        if _matches_day_filter(d, days):
            if rejects(d):
                return None, d
            if found := _latest_on(d, times, tz, now):
                return found
        d -= timedelta(days=interval)

    return None


def _prev_interval_repeat(
    interval: int,
    unit: IntervalUnit,
    from_time: TimeOfDay,
    to_time: TimeOfDay,
    day_filter: DayFilter | None,
    tz: ZoneInfo,
    now: datetime,
    start: date,
    rejects: _Rejects,
) -> _Found | None:
    now_in_tz = now.astimezone(tz)
    step_minutes = interval if unit == IntervalUnit.MIN else interval * 60
    from_minutes = from_time.hour * 60 + from_time.minute
    to_minutes = to_time.hour * 60 + to_time.minute
    last_of_day = from_minutes + (to_minutes - from_minutes) // step_minutes * step_minutes
    # In the second pass of a fall-back, first-pass slots later on the wall clock are past.
    second_pass_minutes = int(now.timestamp() - now_in_tz.replace(fold=0).timestamp()) // 60
    now_minutes = now_in_tz.hour * 60 + now_in_tz.minute + second_pass_minutes

    d = start
    for _ in range(_INTERVAL_DAYS_TO_SCAN):
        if day_filter is None or _matches_day_filter(d, day_filter):
            if rejects(d):
                return None, d
            elapsed = now_minutes + _days_between(d, now_in_tz.date()) * 1440 - from_minutes
            last_slot = min(last_of_day, from_minutes + elapsed // step_minutes * step_minutes)
            for minutes in range(last_slot, from_minutes - 1, -step_minutes):
                slot = _slot_on_date(d, minutes, tz)
                if slot is not None and slot < now:
                    return slot, d
        d -= timedelta(days=1)

    return None


def _prev_week_repeat(
    interval: int,
    days: tuple[Weekday, ...],
    times: tuple[TimeOfDay, ...],
    tz: ZoneInfo,
    anchor: str | None,
    now: datetime,
    start: date,
    rejects: _Rejects,
) -> _Found | None:
    anchor_date = date.fromisoformat(anchor) if anchor else _EPOCH_MONDAY
    anchor_monday = anchor_date - timedelta(days=anchor_date.isoweekday() - 1)

    monday = start - timedelta(days=start.isoweekday() - 1)
    monday -= timedelta(weeks=_weeks_between(anchor_monday, monday) % interval)

    sorted_days = sorted(days, key=lambda wd: wd.number, reverse=True)
    for _ in range(3):
        for wd in sorted_days:
            d = monday + timedelta(days=wd.number - 1)
            if d > start:
                continue
            if rejects(d):
                return None, d
            if found := _latest_on(d, times, tz, now):
                return found
        monday -= timedelta(weeks=interval)

    return None


def _prev_month_repeat(
    interval: int,
    target: MonthTarget,
    times: tuple[TimeOfDay, ...],
    tz: ZoneInfo,
    anchor: str | None,
    now: datetime,
    start: date,
    during: tuple[MonthName, ...],
    limit: date,
    rejects: _Rejects,
) -> _Found | None:
    anchor_month = _month_index(date.fromisoformat(anchor) if anchor else _EPOCH_DATE)
    during_months = {mn.number for mn in during}

    # `previous nearest weekday` can land in the month before its target, so start a month late.
    month = _month_index(start) + 1
    month -= (month - anchor_month) % interval

    while month >= _month_index(limit) - 1:
        year, month_of_year = divmod(month, 12)
        if not during_months or month_of_year + 1 in during_months:
            for d in sorted(_month_target_dates(target, year, month_of_year + 1), reverse=True):
                if d > start:
                    continue
                if rejects(d):
                    return None, d
                if found := _latest_on(d, times, tz, now):
                    return found
        month -= interval

    return None


def _prev_single_date(
    date_spec: DateSpec,
    times: tuple[TimeOfDay, ...],
    tz: ZoneInfo,
    now: datetime,
    start: date,
    limit: date,
    rejects: _Rejects,
) -> _Found | None:
    match date_spec:
        case IsoDate(date=iso_str):
            d = date.fromisoformat(iso_str)
            if d > start:
                return None
            return (None, d) if rejects(d) else _latest_on(d, times, tz, now)
        case NamedDate(month=m, day=day):
            for year in range(start.year, limit.year - 1, -1):
                d = _date_if_valid(year, m.number, day)
                if d is None or d > start:
                    continue
                if rejects(d):
                    return None, d
                if found := _latest_on(d, times, tz, now):
                    return found
            return None

    return None  # pragma: no cover


def _prev_year_repeat(
    interval: int,
    target: YearTarget,
    times: tuple[TimeOfDay, ...],
    tz: ZoneInfo,
    anchor: str | None,
    now: datetime,
    start: date,
    limit: date,
    rejects: _Rejects,
) -> _Found | None:
    anchor_year = date.fromisoformat(anchor).year if anchor else _EPOCH_DATE.year

    year = start.year
    year -= (year - anchor_year) % interval

    while year >= limit.year:
        d = _year_target_date(target, year)
        if d is not None and d <= start:
            if rejects(d):
                return None, d
            if found := _latest_on(d, times, tz, now):
                return found
        year -= interval

    return None
