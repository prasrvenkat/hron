from __future__ import annotations

import calendar
from collections.abc import Iterator
from datetime import UTC, date, datetime, time, timedelta
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


def _last_day_of_month(year: int, month: int) -> date:
    _, last = calendar.monthrange(year, month)
    return date(year, month, last)


def _last_weekday_of_month(year: int, month: int) -> date:
    d = _last_day_of_month(year, month)
    while d.isoweekday() in (6, 7):
        d -= timedelta(days=1)
    return d


def _nth_weekday_of_month(year: int, month: int, weekday: Weekday, n: int) -> date | None:
    target_dow = weekday.number
    d = date(year, month, 1)
    while d.isoweekday() != target_dow:
        d += timedelta(days=1)
    for _ in range(n - 1):
        d += timedelta(days=7)
    if d.month != month:
        return None
    return d


def _last_weekday_in_month(year: int, month: int, weekday: Weekday) -> date:
    target_dow = weekday.number
    d = _last_day_of_month(year, month)
    while d.isoweekday() != target_dow:
        d -= timedelta(days=1)
    return d


def _ordinal_weekday(
    year: int, month: int, ordinal: OrdinalPosition, weekday: Weekday
) -> date | None:
    if ordinal == OrdinalPosition.LAST:
        return _last_weekday_in_month(year, month, weekday)
    return _nth_weekday_of_month(year, month, weekday, ordinal.to_n())


def _nearest_weekday(
    year: int, month: int, target_day: int, direction: NearestDirection | None
) -> date | None:
    """Return the nearest weekday to target_day, or None if target_day is not in the month."""
    last = _last_day_of_month(year, month)
    last_day = last.day

    if target_day > last_day:
        return None

    try:
        d = date(year, month, target_day)
    except ValueError:
        return None

    dow = d.isoweekday()  # Monday=1, Sunday=7

    if 1 <= dow <= 5:
        return d

    if dow == 6:
        if direction is None:
            # Standard: prefer Friday, but if at month start, use Monday
            if target_day == 1:
                return d + timedelta(days=2)
            else:
                return d - timedelta(days=1)  # Friday
        elif direction == NearestDirection.NEXT:
            return d + timedelta(days=2)
        else:  # PREVIOUS
            return d - timedelta(days=1)

    if dow == 7:
        if direction is None:
            # Standard: prefer Monday, but if at month end, use Friday
            if target_day >= last_day:
                return d - timedelta(days=2)
            else:
                return d + timedelta(days=1)  # Monday
        elif direction == NearestDirection.NEXT:
            return d + timedelta(days=1)
        else:  # PREVIOUS
            return d - timedelta(days=2)

    return d


def _month_target_dates(target: MonthTarget, year: int, month: int) -> list[date]:
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
_DAY_REPEAT_SCAN_DAYS = 7 + 3
_EPOCH_DATE = date(1970, 1, 1)
_EPOCH_MONDAY = date(1970, 1, 5)
_DAYS_PER_400_YEARS = 146097


def _weeks_between(a: date, b: date) -> int:
    return (b - a).days // 7


def _days_between(a: date, b: date) -> int:
    return (b - a).days


def _month_index(d: date) -> int:
    return d.year * 12 + d.month - 1


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


def _is_excepted_parsed(
    d: date,
    named: set[tuple[int, int]],
    iso_dates: set[date],
) -> bool:
    return (d.month, d.day) in named or d in iso_dates


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
    current_month = d.month
    months = sorted(mn.number for mn in during)

    for m in months:
        if m > current_month:
            return date(d.year, m, 1)
    return date(d.year + 1, months[0], 1)


def _prev_during_month(d: date, during: tuple[MonthName, ...]) -> date:
    """Find the last day of the previous month in the during list."""
    during_months = sorted((mn.number for mn in during), reverse=True)
    year = d.year
    month = d.month - 1
    if month < 1:
        month = 12
        year -= 1

    for _ in range(13):
        if month in during_months:
            return _last_day_of_month(year, month)
        month -= 1
        if month < 1:
            month = 12
            year -= 1

    return d - timedelta(days=1)


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


# An occurrence and its scheduled date: the date whose wall-clock time it resolves, which
# `during`, `except`, `until` and `starting` check even when a gap shifts it onto the next date.
_Occurrence = tuple[datetime, date]


def _earliest_on(
    d: date, times: tuple[TimeOfDay, ...], tz: ZoneInfo, now: datetime
) -> _Occurrence | None:
    resolved = (_at_time_on_date(d, tod, tz) for tod in times)
    future = [c for c in resolved if c is not None and c > now]
    return (min(future), d) if future else None


def _latest_on(
    d: date, times: tuple[TimeOfDay, ...], tz: ZoneInfo, now: datetime
) -> _Occurrence | None:
    resolved = (_at_time_on_date(d, tod, tz) for tod in times)
    past = [c for c in resolved if c is not None and c < now]
    return (max(past), d) if past else None


def next_from(schedule: ScheduleData, now: datetime) -> datetime | None:
    instant = _supported_utc(now)
    return None if instant is None else _next(schedule, instant)


def _next(schedule: ScheduleData, now: datetime) -> datetime | None:
    tz = _resolve_tz(schedule.timezone)
    now_in_tz = now.astimezone(tz)
    until_date = _resolve_until(schedule.until, now_in_tz) if schedule.until else None
    starting = date.fromisoformat(schedule.anchor) if schedule.anchor else None
    named_exc, iso_exc = _parse_exceptions(schedule.except_)
    # A month repeat applies `during` itself, to the month it targets, which a nearest weekday
    # can leave; every other expression applies it to the scheduled date.
    during_on_result = () if isinstance(schedule.expr, MonthRepeat) else schedule.during

    # A time shifted past midnight by a gap lands on the date after its scheduled date.
    start = _add_days_clamped(now_in_tz.date(), -1)
    if starting is not None and starting > start:
        start = starting
    limit = _add_days_clamped(max(start, now_in_tz.date()), _search_span_days(schedule.expr))
    shifted: datetime | None = None

    try:
        while found := _next_expr(
            schedule.expr, tz, schedule.anchor, now, start, schedule.during, limit
        ):
            candidate, scheduled = found
            if scheduled > limit or (until_date is not None and scheduled > until_date):
                break
            if during_on_result and not _matches_during(scheduled, during_on_result):
                start = _next_during_month(scheduled, during_on_result)
                continue
            if not _is_excepted_parsed(scheduled, named_exc, iso_exc):
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
) -> _Occurrence | None:
    """The first occurrence after `now` whose scheduled date is on or after `start`."""
    match expr:
        case DayRepeat(interval=interval, days=days, times=times):
            return _next_day_repeat(interval, days, times, tz, anchor, now, start)
        case IntervalRepeat(
            interval=interval,
            unit=unit,
            from_time=ft,
            to_time=tt,
            day_filter=df,
        ):
            return _next_interval_repeat(interval, unit, ft, tt, df, tz, now, start)
        case WeekRepeat(interval=interval, days=days, times=times):
            return _next_week_repeat(interval, days, times, tz, anchor, now, start)
        case MonthRepeat(interval=interval, target=target, times=times):
            return _next_month_repeat(
                interval, target, times, tz, anchor, now, start, during, limit
            )
        case SingleDateExpr(date=date_spec, times=times):
            return _next_single_date(date_spec, times, tz, now, start, limit)
        case YearRepeat(interval=interval, target=target, times=times):
            return _next_year_repeat(interval, target, times, tz, anchor, now, start, limit)
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
) -> _Occurrence | None:
    d = start
    if interval > 1:
        anchor_date = date.fromisoformat(anchor) if anchor else _EPOCH_DATE
        d += timedelta(days=_days_between(d, anchor_date) % interval)

    for _ in range(_DAY_REPEAT_SCAN_DAYS):
        if _matches_day_filter(d, days) and (found := _earliest_on(d, times, tz, now)):
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
) -> _Occurrence | None:
    now_in_tz = now.astimezone(tz)
    step_minutes = interval if unit == IntervalUnit.MIN else interval * 60
    from_minutes = from_time.hour * 60 + from_time.minute
    to_minutes = to_time.hour * 60 + to_time.minute

    first_slot = from_minutes
    d = max(start, now_in_tz.date())
    if d == now_in_tz.date():
        now_minutes = now_in_tz.hour * 60 + now_in_tz.minute
        first_slot += max(now_minutes - from_minutes, 0) // step_minutes * step_minutes

    for _ in range(8):
        if day_filter is None or _matches_day_filter(d, day_filter):
            for minutes in range(first_slot, to_minutes + 1, step_minutes):
                slot = _slot_on_date(d, minutes, tz)
                if slot is not None and slot > now:
                    return slot, d
        d += timedelta(days=1)
        first_slot = from_minutes

    return None


def _next_week_repeat(
    interval: int,
    days: tuple[Weekday, ...],
    times: tuple[TimeOfDay, ...],
    tz: ZoneInfo,
    anchor: str | None,
    now: datetime,
    start: date,
) -> _Occurrence | None:
    anchor_date = date.fromisoformat(anchor) if anchor else _EPOCH_MONDAY
    anchor_monday = anchor_date - timedelta(days=anchor_date.isoweekday() - 1)

    monday = start - timedelta(days=start.isoweekday() - 1)
    monday += timedelta(weeks=_weeks_between(monday, anchor_monday) % interval)

    sorted_days = sorted(days, key=lambda wd: wd.number)
    for _ in range(3):
        for wd in sorted_days:
            d = monday + timedelta(days=wd.number - 1)
            if d >= start and (found := _earliest_on(d, times, tz, now)):
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
) -> _Occurrence | None:
    anchor_month = _month_index(date.fromisoformat(anchor) if anchor else _EPOCH_DATE)
    during_months = {mn.number for mn in during}

    # `next nearest weekday` can land in the month after its target, so start a month early.
    month = max(_month_index(start) - 1, _month_index(date.min))
    month += (anchor_month - month) % interval

    while month <= _month_index(limit):
        year, month_of_year = divmod(month, 12)
        if not during_months or month_of_year + 1 in during_months:
            for d in sorted(_month_target_dates(target, year, month_of_year + 1)):
                if d >= start and (found := _earliest_on(d, times, tz, now)):
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
) -> _Occurrence | None:
    match date_spec:
        case IsoDate(date=iso_str):
            d = date.fromisoformat(iso_str)
            return _earliest_on(d, times, tz, now) if d >= start else None
        case NamedDate(month=m, day=day):
            for year in range(start.year, limit.year + 1):
                d = _date_if_valid(year, m.number, day)
                if d is not None and d >= start and (found := _earliest_on(d, times, tz, now)):
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
) -> _Occurrence | None:
    anchor_year = date.fromisoformat(anchor).year if anchor else _EPOCH_DATE.year

    year = start.year
    year += (anchor_year - year) % interval

    while year <= limit.year:
        d = _year_target_date(target, year)
        if d is not None and d >= start and (found := _earliest_on(d, times, tz, now)):
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
    until_date = _resolve_until(schedule.until, now_in_tz) if schedule.until else None
    starting = date.fromisoformat(schedule.anchor) if schedule.anchor else None
    named_exc, iso_exc = _parse_exceptions(schedule.except_)
    during_on_result = () if isinstance(schedule.expr, MonthRepeat) else schedule.during

    # An overlap crossing midnight can put an earlier date's wall clock on a later occurrence.
    start = _add_days_clamped(now_in_tz.date(), 1)
    if until_date is not None and until_date < start:
        start = until_date
    limit = _add_days_clamped(min(start, now_in_tz.date()), -_search_span_days(schedule.expr))
    shifted_over: datetime | None = None

    try:
        while found := _prev_expr(
            schedule.expr, tz, schedule.anchor, now, start, schedule.during, limit
        ):
            candidate, scheduled = found
            if scheduled < limit or (starting is not None and scheduled < starting):
                break
            if during_on_result and not _matches_during(scheduled, during_on_result):
                start = _prev_during_month(scheduled, during_on_result)
                continue
            if not _is_excepted_parsed(scheduled, named_exc, iso_exc):
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
) -> _Occurrence | None:
    """The last occurrence before `now` whose scheduled date is on or before `start`."""
    match expr:
        case DayRepeat(interval=interval, days=days, times=times):
            return _prev_day_repeat(interval, days, times, tz, anchor, now, start)
        case IntervalRepeat(
            interval=interval,
            unit=unit,
            from_time=ft,
            to_time=tt,
            day_filter=df,
        ):
            return _prev_interval_repeat(interval, unit, ft, tt, df, tz, now, start)
        case WeekRepeat(interval=interval, days=days, times=times):
            return _prev_week_repeat(interval, days, times, tz, anchor, now, start)
        case MonthRepeat(interval=interval, target=target, times=times):
            return _prev_month_repeat(
                interval, target, times, tz, anchor, now, start, during, limit
            )
        case SingleDateExpr(date=date_spec, times=times):
            return _prev_single_date(date_spec, times, tz, now, start, limit)
        case YearRepeat(interval=interval, target=target, times=times):
            return _prev_year_repeat(interval, target, times, tz, anchor, now, start, limit)
    return None  # pragma: no cover


def _prev_day_repeat(
    interval: int,
    days: DayFilter,
    times: tuple[TimeOfDay, ...],
    tz: ZoneInfo,
    anchor: str | None,
    now: datetime,
    start: date,
) -> _Occurrence | None:
    d = start
    if interval > 1:
        anchor_date = date.fromisoformat(anchor) if anchor else _EPOCH_DATE
        d -= timedelta(days=_days_between(anchor_date, d) % interval)

    for _ in range(_DAY_REPEAT_SCAN_DAYS):
        if _matches_day_filter(d, days) and (found := _latest_on(d, times, tz, now)):
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
) -> _Occurrence | None:
    now_in_tz = now.astimezone(tz)
    step_minutes = interval if unit == IntervalUnit.MIN else interval * 60
    from_minutes = from_time.hour * 60 + from_time.minute
    to_minutes = to_time.hour * 60 + to_time.minute
    last_of_day = from_minutes + (to_minutes - from_minutes) // step_minutes * step_minutes

    last_slot = last_of_day
    d = min(start, now_in_tz.date())
    if d == now_in_tz.date():
        # In the second pass of a fall-back, first-pass slots later on the wall clock are past.
        second_pass_minutes = int(now.timestamp() - now_in_tz.replace(fold=0).timestamp()) // 60
        now_minutes = now_in_tz.hour * 60 + now_in_tz.minute + second_pass_minutes
        last_slot = min(
            last_of_day,
            from_minutes + (now_minutes - from_minutes) // step_minutes * step_minutes,
        )

    for _ in range(8):
        if day_filter is None or _matches_day_filter(d, day_filter):
            for minutes in range(last_slot, from_minutes - 1, -step_minutes):
                slot = _slot_on_date(d, minutes, tz)
                if slot is not None and slot < now:
                    return slot, d
        d -= timedelta(days=1)
        last_slot = last_of_day

    return None


def _prev_week_repeat(
    interval: int,
    days: tuple[Weekday, ...],
    times: tuple[TimeOfDay, ...],
    tz: ZoneInfo,
    anchor: str | None,
    now: datetime,
    start: date,
) -> _Occurrence | None:
    anchor_date = date.fromisoformat(anchor) if anchor else _EPOCH_MONDAY
    anchor_monday = anchor_date - timedelta(days=anchor_date.isoweekday() - 1)

    monday = start - timedelta(days=start.isoweekday() - 1)
    monday -= timedelta(weeks=_weeks_between(anchor_monday, monday) % interval)

    sorted_days = sorted(days, key=lambda wd: wd.number, reverse=True)
    for _ in range(3):
        for wd in sorted_days:
            d = monday + timedelta(days=wd.number - 1)
            if d <= start and (found := _latest_on(d, times, tz, now)):
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
) -> _Occurrence | None:
    anchor_month = _month_index(date.fromisoformat(anchor) if anchor else _EPOCH_DATE)
    during_months = {mn.number for mn in during}

    # `previous nearest weekday` can land in the month before its target, so start a month late.
    month = min(_month_index(start) + 1, _month_index(date.max))
    month -= (month - anchor_month) % interval

    while month >= _month_index(limit):
        year, month_of_year = divmod(month, 12)
        if not during_months or month_of_year + 1 in during_months:
            for d in sorted(_month_target_dates(target, year, month_of_year + 1), reverse=True):
                if d <= start and (found := _latest_on(d, times, tz, now)):
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
) -> _Occurrence | None:
    match date_spec:
        case IsoDate(date=iso_str):
            d = date.fromisoformat(iso_str)
            return _latest_on(d, times, tz, now) if d <= start else None
        case NamedDate(month=m, day=day):
            for year in range(start.year, limit.year - 1, -1):
                d = _date_if_valid(year, m.number, day)
                if d is not None and d <= start and (found := _latest_on(d, times, tz, now)):
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
) -> _Occurrence | None:
    anchor_year = date.fromisoformat(anchor).year if anchor else _EPOCH_DATE.year

    year = start.year
    year -= (year - anchor_year) % interval

    while year >= limit.year:
        d = _year_target_date(target, year)
        if d is not None and d <= start and (found := _latest_on(d, times, tz, now)):
            return found
        year -= interval

    return None
