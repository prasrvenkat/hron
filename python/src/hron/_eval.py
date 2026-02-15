from __future__ import annotations

import calendar
import contextlib
from collections.abc import Iterator
from datetime import date, datetime, time, timedelta
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
    OrdinalRepeat,
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

# =============================================================================
# Iteration Safety Limits
# =============================================================================
# MAX_ITERATIONS (1000): Maximum iterations for next_from/previous_from loops.
# Prevents infinite loops when searching for valid occurrences.
#
# Expression-specific limits:
# - Day repeat: 8 days (covers one week + margin)
# - Week repeat: 54 weeks (covers one year + margin)
# - Month repeat: 24 * interval months (covers 2 years scaled by interval)
# - Year repeat: 8 * interval years (covers reasonable future horizon)
#
# These limits are generous safety bounds. In practice, valid schedules
# find occurrences within the first few iterations.
# =============================================================================

# =============================================================================
# DST (Daylight Saving Time) Handling
# =============================================================================
# When resolving a wall-clock time to an instant:
#
# 1. DST Gap (Spring Forward):
#    - Time doesn't exist (e.g., 2:30 AM during spring forward)
#    - Solution: Push forward to the next valid time after the gap
#    - Example: 2:30 AM -> 3:00 AM (or 3:30 AM depending on gap size)
#
# 2. DST Fold (Fall Back):
#    - Time is ambiguous (e.g., 1:30 AM occurs twice)
#    - Solution: Use first occurrence (fold=0 / pre-transition time)
#    - This matches user expectation for scheduling
#
# All implementations use the same algorithm for cross-language consistency.
# =============================================================================

# =============================================================================
# Interval Alignment (Anchor Date)
# =============================================================================
# For schedules with interval > 1 (e.g., "every 3 days"), we need to
# determine which dates are valid based on alignment with an anchor.
#
# Formula: (date_offset - anchor_offset) mod interval == 0
#
# Where:
#   - date_offset: days/weeks/months from epoch to candidate date
#   - anchor_offset: days/weeks/months from epoch to anchor date
#   - interval: the repeat interval (e.g., 3 for "every 3 days")
#
# Default anchor: Epoch (1970-01-01)
# Custom anchor: Set via "starting YYYY-MM-DD" clause
#
# For week repeats, we use epoch Monday (1970-01-05) as the reference
# point to align week boundaries correctly.
# =============================================================================

# --- Timezone resolution ---


def _resolve_tz(tz_name: str | None) -> ZoneInfo:
    """Resolve timezone, defaulting to UTC for deterministic behavior."""
    return ZoneInfo(tz_name) if tz_name else ZoneInfo("UTC")


# --- Helpers ---


def _make_aware(d: date, t: time, tz: ZoneInfo) -> datetime:
    """Create a timezone-aware datetime with 'compatible' disambiguation (fold=0)."""
    naive = datetime.combine(d, t)
    return naive.replace(tzinfo=tz, fold=0)


def _at_time_on_date(d: date, tod: TimeOfDay, tz: ZoneInfo) -> datetime:
    t = time(tod.hour, tod.minute)
    # Create with fold=0 (compatible disambiguation — first occurrence in fall-back)
    aware = _make_aware(d, t, tz)
    # Normalize through UTC round-trip to handle spring-forward gaps
    utc_ts = aware.timestamp()
    return datetime.fromtimestamp(utc_ts, tz=tz)


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


def _nearest_weekday(
    year: int, month: int, target_day: int, direction: NearestDirection | None
) -> date | None:
    """Get the nearest weekday to a given day in a month.

    Args:
        year: The year
        month: The month (1-12)
        target_day: The target day of month (1-31)
        direction: None for standard cron W behavior (never crosses month boundary),
                   NearestDirection.NEXT for always prefer following weekday,
                   NearestDirection.PREVIOUS for always prefer preceding weekday.

    Returns:
        The nearest weekday date, or None if target_day doesn't exist in the month.
    """
    last = _last_day_of_month(year, month)
    last_day = last.day

    # If target day doesn't exist in this month, return None (skip this month)
    if target_day > last_day:
        return None

    try:
        d = date(year, month, target_day)
    except ValueError:
        return None

    dow = d.isoweekday()  # Monday=1, Sunday=7

    # Already a weekday (Mon-Fri)
    if 1 <= dow <= 5:
        return d

    # Saturday (dow=6)
    if dow == 6:
        if direction is None:
            # Standard: prefer Friday, but if at month start, use Monday
            if target_day == 1:
                # Can't go to previous month, use Monday (day 3)
                return d + timedelta(days=2)
            else:
                return d - timedelta(days=1)  # Friday
        elif direction == NearestDirection.NEXT:
            # Always Monday (may cross month)
            return d + timedelta(days=2)
        else:  # PREVIOUS
            # Always Friday (may cross month if day==1)
            return d - timedelta(days=1)

    # Sunday (dow=7)
    if dow == 7:
        if direction is None:
            # Standard: prefer Monday, but if at month end, use Friday
            if target_day >= last_day:
                # Can't go to next month, use Friday (day - 2)
                return d - timedelta(days=2)
            else:
                return d + timedelta(days=1)  # Monday
        elif direction == NearestDirection.NEXT:
            # Always Monday (may cross month)
            return d + timedelta(days=1)
        else:  # PREVIOUS
            # Always Friday (go back 2 days, may cross month)
            return d - timedelta(days=2)

    return d


_EPOCH_DATE = date(1970, 1, 1)
_EPOCH_MONDAY = date(1970, 1, 5)


def _weeks_between(a: date, b: date) -> int:
    return (b - a).days // 7


def _days_between(a: date, b: date) -> int:
    return (b - a).days


def _months_between_ym(a: date, b: date) -> int:
    return b.year * 12 + b.month - (a.year * 12 + a.month)


def _is_excepted(d: date, exceptions: tuple[ExceptionSpec, ...]) -> bool:
    for exc in exceptions:
        match exc:
            case NamedException(month=m, day=day):
                if d.month == m.number and d.day == day:
                    return True
            case IsoException(date=iso_str):
                exc_date = date.fromisoformat(iso_str)
                if d == exc_date:
                    return True
    return False


def _is_excepted_parsed(
    d: date,
    named: list[tuple[int, int]],
    iso_dates: list[date],
) -> bool:
    return any(d.month == m and d.day == day for m, day in named) or any(
        d == iso_d for iso_d in iso_dates
    )


def _parse_exceptions(
    exceptions: tuple[ExceptionSpec, ...],
) -> tuple[list[tuple[int, int]], list[date]]:
    named: list[tuple[int, int]] = []
    iso_dates: list[date] = []
    for exc in exceptions:
        match exc:
            case NamedException(month=m, day=day):
                named.append((m.number, day))
            case IsoException(date=iso_str):
                iso_dates.append(date.fromisoformat(iso_str))
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
    # Wrap to first month of next year
    return date(d.year + 1, months[0], 1)


def _resolve_until(until: UntilSpec, now: datetime) -> date:
    match until:
        case IsoUntil(date=iso_str):
            return date.fromisoformat(iso_str)
        case NamedUntil(month=m, day=day):
            year = now.year
            for y in (year, year + 1):
                try:
                    d = date(y, m.number, day)
                    if d >= now.date():
                        return d
                except ValueError:
                    continue
            return date(year + 1, m.number, day)


def _earliest_future_at_times(
    d: date,
    times: tuple[TimeOfDay, ...],
    tz: ZoneInfo,
    now: datetime,
) -> datetime | None:
    best: datetime | None = None
    for tod in times:
        candidate = _at_time_on_date(d, tod, tz)
        if candidate > now and (best is None or candidate < best):
            best = candidate
    return best


# --- Public API ---


def next_from(schedule: ScheduleData, now: datetime) -> datetime | None:
    tz = _resolve_tz(schedule.timezone)

    until_date = _resolve_until(schedule.until, now) if schedule.until else None

    named_exc, iso_exc = _parse_exceptions(schedule.except_)
    has_exceptions = len(schedule.except_) > 0
    has_during = len(schedule.during) > 0

    # Check if expression is NearestWeekday with direction (can cross month boundaries)
    handles_during_internally = (
        isinstance(schedule.expr, MonthRepeat)
        and isinstance(schedule.expr.target, NearestWeekdayTarget)
        and schedule.expr.target.direction is not None
    )

    current = now
    for _ in range(1000):
        candidate = _next_expr(schedule.expr, tz, schedule.anchor, current, schedule.during)

        if candidate is None:
            return None

        c_date = candidate.astimezone(tz).date()

        # Apply until filter
        if until_date is not None and c_date > until_date:
            return None

        # Apply during filter
        # Skip for expressions that handle during internally (NearestWeekday w/ direction)
        during_mismatch = has_during and not _matches_during(c_date, schedule.during)
        if during_mismatch and not handles_during_internally:
            skip_to = _next_during_month(c_date, schedule.during)
            midnight = _at_time_on_date(skip_to, TimeOfDay(0, 0), tz)
            current = midnight - timedelta(seconds=1)
            continue

        # Apply except filter
        if has_exceptions and _is_excepted_parsed(c_date, named_exc, iso_exc):
            next_day = c_date + timedelta(days=1)
            midnight = _at_time_on_date(next_day, TimeOfDay(0, 0), tz)
            current = midnight - timedelta(seconds=1)
            continue

        return candidate

    return None


def _next_expr(
    expr: ScheduleExpr,
    tz: ZoneInfo,
    anchor: str | None,
    now: datetime,
    during: tuple[MonthName, ...] = (),
) -> datetime | None:
    match expr:
        case DayRepeat(interval=interval, days=days, times=times):
            return _next_day_repeat(interval, days, times, tz, anchor, now)
        case IntervalRepeat(
            interval=interval,
            unit=unit,
            from_time=ft,
            to_time=tt,
            day_filter=df,
        ):
            return _next_interval_repeat(interval, unit, ft, tt, df, tz, now)
        case WeekRepeat(interval=interval, days=days, times=times):
            return _next_week_repeat(interval, days, times, tz, anchor, now)
        case MonthRepeat(interval=interval, target=target, times=times):
            return _next_month_repeat(interval, target, times, tz, anchor, now, during)
        case OrdinalRepeat(interval=interval, ordinal=ordinal, day=day, times=times):
            return _next_ordinal_repeat(interval, ordinal, day, times, tz, anchor, now)
        case SingleDateExpr(date=date_spec, times=times):
            return _next_single_date(date_spec, times, tz, now)
        case YearRepeat(interval=interval, target=target, times=times):
            return _next_year_repeat(interval, target, times, tz, anchor, now)
    return None  # pragma: no cover


def next_n_from(schedule: ScheduleData, now: datetime, n: int) -> list[datetime]:
    results: list[datetime] = []
    current = now
    for _ in range(n):
        nxt = next_from(schedule, current)
        if nxt is None:
            break
        current = nxt + timedelta(minutes=1)
        results.append(nxt)
    return results


def matches(schedule: ScheduleData, dt: datetime) -> bool:
    tz = _resolve_tz(schedule.timezone)
    zdt = dt.astimezone(tz)
    d = zdt.date()

    if not _matches_during(d, schedule.during):
        return False
    if _is_excepted(d, schedule.except_):
        return False

    if schedule.until:
        until_date = _resolve_until(schedule.until, dt)
        if d > until_date:
            return False

    def time_matches_with_dst(times: tuple[TimeOfDay, ...]) -> bool:
        for tod in times:
            if zdt.hour == tod.hour and zdt.minute == tod.minute:
                return True
            # DST gap check: if scheduled time falls in a gap, check if it resolves
            # to the same instant as the candidate
            resolved = _at_time_on_date(d, tod, tz)
            if resolved.timestamp() == dt.timestamp():
                return True
        return False

    match schedule.expr:
        case DayRepeat(interval=interval, days=days, times=times):
            if not _matches_day_filter(d, days):
                return False
            if not time_matches_with_dst(times):
                return False
            if interval > 1:
                anchor_date = (
                    date.fromisoformat(schedule.anchor) if schedule.anchor else _EPOCH_DATE
                )
                day_offset = _days_between(anchor_date, d)
                return day_offset >= 0 and day_offset % interval == 0
            return True

        case IntervalRepeat(
            interval=interval,
            unit=unit,
            from_time=ft,
            to_time=tt,
            day_filter=df,
        ):
            if df is not None and not _matches_day_filter(d, df):
                return False
            from_minutes = ft.hour * 60 + ft.minute
            to_minutes = tt.hour * 60 + tt.minute
            current_minutes = zdt.hour * 60 + zdt.minute
            if current_minutes < from_minutes or current_minutes > to_minutes:
                return False
            diff = current_minutes - from_minutes
            step = interval if unit == IntervalUnit.MIN else interval * 60
            return diff >= 0 and diff % step == 0

        case WeekRepeat(interval=interval, days=days, times=times):
            dow = d.isoweekday()
            if not any(wd.number == dow for wd in days):
                return False
            if not time_matches_with_dst(times):
                return False
            anchor_date = date.fromisoformat(schedule.anchor) if schedule.anchor else _EPOCH_MONDAY
            weeks = _weeks_between(anchor_date, d)
            return weeks >= 0 and weeks % interval == 0

        case MonthRepeat(interval=interval, target=target, times=times):
            if not time_matches_with_dst(times):
                return False
            if interval > 1:
                anchor_date = (
                    date.fromisoformat(schedule.anchor) if schedule.anchor else _EPOCH_DATE
                )
                month_offset = _months_between_ym(anchor_date, d)
                if month_offset < 0 or month_offset % interval != 0:
                    return False
            match target:
                case DaysTarget():
                    expanded = expand_month_target(target)
                    return d.day in expanded
                case LastDayTarget():
                    last = _last_day_of_month(d.year, d.month)
                    return d == last
                case LastWeekdayTarget():
                    lwd = _last_weekday_of_month(d.year, d.month)
                    return d == lwd
                case NearestWeekdayTarget(day=target_day, direction=direction):
                    target_date = _nearest_weekday(d.year, d.month, target_day, direction)
                    return target_date is not None and d == target_date

        case OrdinalRepeat(interval=interval, ordinal=ordinal, day=day, times=times):
            if not time_matches_with_dst(times):
                return False
            if interval > 1:
                anchor_date = (
                    date.fromisoformat(schedule.anchor) if schedule.anchor else _EPOCH_DATE
                )
                month_offset = _months_between_ym(anchor_date, d)
                if month_offset < 0 or month_offset % interval != 0:
                    return False
            ordinal_target: date | None
            if ordinal == OrdinalPosition.LAST:
                ordinal_target = _last_weekday_in_month(d.year, d.month, day)
            else:
                ordinal_target = _nth_weekday_of_month(d.year, d.month, day, ordinal.to_n())
            if ordinal_target is None:
                return False
            return d == ordinal_target

        case SingleDateExpr(date=date_spec, times=times):
            if not time_matches_with_dst(times):
                return False
            match date_spec:
                case IsoDate(date=iso_str):
                    iso_target = date.fromisoformat(iso_str)
                    return d == iso_target
                case NamedDate(month=m, day=day_num):
                    return d.month == m.number and d.day == day_num
            return False  # pragma: no cover

        case YearRepeat(interval=interval, target=target, times=times):
            if not time_matches_with_dst(times):
                return False
            if interval > 1:
                anchor_year = (
                    date.fromisoformat(schedule.anchor).year
                    if schedule.anchor
                    else _EPOCH_DATE.year
                )
                year_offset = d.year - anchor_year
                if year_offset < 0 or year_offset % interval != 0:
                    return False
            return _matches_year_target(target, d)

    return False  # pragma: no cover


def _matches_year_target(target: YearTarget, d: date) -> bool:
    match target:
        case YearDateTarget(month=m, day=day):
            return d.month == m.number and d.day == day
        case YearOrdinalWeekdayTarget(ordinal=ordinal, weekday=weekday, month=m):
            if d.month != m.number:
                return False
            ordinal_date: date | None
            if ordinal == OrdinalPosition.LAST:
                ordinal_date = _last_weekday_in_month(d.year, d.month, weekday)
            else:
                ordinal_date = _nth_weekday_of_month(d.year, d.month, weekday, ordinal.to_n())
            if ordinal_date is None:
                return False
            return d == ordinal_date
        case YearDayOfMonthTarget(day=day, month=m):
            return d.month == m.number and d.day == day
        case YearLastWeekdayTarget(month=m):
            if d.month != m.number:
                return False
            lwd = _last_weekday_of_month(d.year, d.month)
            return d == lwd
    return False  # pragma: no cover


# --- Per-variant next functions ---


def _next_day_repeat(
    interval: int,
    days: DayFilter,
    times: tuple[TimeOfDay, ...],
    tz: ZoneInfo,
    anchor: str | None,
    now: datetime,
) -> datetime | None:
    now_in_tz = now.astimezone(tz)
    d = now_in_tz.date()

    if interval <= 1:
        # Original behavior for interval=1
        if _matches_day_filter(d, days):
            candidate = _earliest_future_at_times(d, times, tz, now)
            if candidate:
                return candidate

        for _ in range(8):
            d += timedelta(days=1)
            if _matches_day_filter(d, days):
                candidate = _earliest_future_at_times(d, times, tz, now)
                if candidate:
                    return candidate

        return None

    # Interval > 1: day intervals only apply to DayFilter::Every
    anchor_date = date.fromisoformat(anchor) if anchor else _EPOCH_DATE

    # Find the next aligned day >= today
    offset = _days_between(anchor_date, d)
    remainder = offset % interval
    aligned_date = d if remainder == 0 else d + timedelta(days=interval - remainder)

    for _ in range(400):
        candidate = _earliest_future_at_times(aligned_date, times, tz, now)
        if candidate:
            return candidate
        aligned_date += timedelta(days=interval)

    return None


def _next_interval_repeat(
    interval: int,
    unit: IntervalUnit,
    from_time: TimeOfDay,
    to_time: TimeOfDay,
    day_filter: DayFilter | None,
    tz: ZoneInfo,
    now: datetime,
) -> datetime | None:
    now_in_tz = now.astimezone(tz)
    step_minutes = interval if unit == IntervalUnit.MIN else interval * 60
    from_minutes = from_time.hour * 60 + from_time.minute
    to_minutes = to_time.hour * 60 + to_time.minute

    d = now_in_tz.date()

    for _ in range(400):
        if day_filter is not None and not _matches_day_filter(d, day_filter):
            d += timedelta(days=1)
            continue

        same_day = d == now_in_tz.date()
        now_minutes = now_in_tz.hour * 60 + now_in_tz.minute if same_day else -1

        if now_minutes < from_minutes:
            next_slot = from_minutes
        else:
            elapsed = now_minutes - from_minutes
            next_slot = from_minutes + (elapsed // step_minutes + 1) * step_minutes

        if next_slot <= to_minutes:
            h = next_slot // 60
            m = next_slot % 60
            candidate = _at_time_on_date(d, TimeOfDay(h, m), tz)
            if candidate > now:
                return candidate

        d += timedelta(days=1)

    return None


def _next_week_repeat(
    interval: int,
    days: tuple[Weekday, ...],
    times: tuple[TimeOfDay, ...],
    tz: ZoneInfo,
    anchor: str | None,
    now: datetime,
) -> datetime | None:
    now_in_tz = now.astimezone(tz)
    anchor_date = date.fromisoformat(anchor) if anchor else _EPOCH_MONDAY

    d = now_in_tz.date()

    # Sort target DOWs for earliest-first matching
    sorted_days = sorted(days, key=lambda wd: wd.number)

    # Find Monday of current week and Monday of anchor week
    dow_offset = d.isoweekday() - 1
    current_monday = d - timedelta(days=dow_offset)

    anchor_dow_offset = anchor_date.isoweekday() - 1
    anchor_monday = anchor_date - timedelta(days=anchor_dow_offset)

    for _ in range(54):
        weeks = _weeks_between(anchor_monday, current_monday)

        # Skip weeks before anchor - anchor Monday is always the first aligned week
        if weeks < 0:
            current_monday = anchor_monday
            continue

        if weeks % interval == 0:
            # Aligned week — try each target DOW
            for wd in sorted_days:
                day_offset = wd.number - 1
                target_date = current_monday + timedelta(days=day_offset)
                candidate = _earliest_future_at_times(target_date, times, tz, now)
                if candidate:
                    return candidate

        # Skip to next aligned week
        remainder = weeks % interval
        skip_weeks = interval if remainder == 0 else interval - remainder
        current_monday += timedelta(days=skip_weeks * 7)

    return None


def _next_month_repeat(
    interval: int,
    target: MonthTarget,
    times: tuple[TimeOfDay, ...],
    tz: ZoneInfo,
    anchor: str | None,
    now: datetime,
    during: tuple[MonthName, ...] = (),
) -> datetime | None:
    now_in_tz = now.astimezone(tz)
    year = now_in_tz.year
    month = now_in_tz.month

    anchor_date = date.fromisoformat(anchor) if anchor else _EPOCH_DATE
    max_iter = 24 * interval if interval > 1 else 24

    # For NearestWeekday with direction, we need to apply the during filter here
    # because the result can cross month boundaries
    apply_during_filter = (
        len(during) > 0
        and isinstance(target, NearestWeekdayTarget)
        and target.direction is not None
    )

    for _ in range(max_iter):
        # Check during filter for NearestWeekday with direction
        if apply_during_filter:
            during_months = {mn.number for mn in during}
            if month not in during_months:
                month += 1
                if month > 12:
                    month = 1
                    year += 1
                continue
        # Check interval alignment
        if interval > 1:
            cur = date(year, month, 1)
            month_offset = _months_between_ym(anchor_date, cur)
            if month_offset < 0 or month_offset % interval != 0:
                month += 1
                if month > 12:
                    month = 1
                    year += 1
                continue

        date_candidates: list[date] = []

        match target:
            case DaysTarget():
                expanded = expand_month_target(target)
                last = _last_day_of_month(year, month)
                for day_num in expanded:
                    if day_num <= last.day:
                        with contextlib.suppress(ValueError):
                            date_candidates.append(date(year, month, day_num))
            case LastDayTarget():
                date_candidates.append(_last_day_of_month(year, month))
            case LastWeekdayTarget():
                date_candidates.append(_last_weekday_of_month(year, month))
            case NearestWeekdayTarget(day=target_day, direction=direction):
                nearest_date = _nearest_weekday(year, month, target_day, direction)
                if nearest_date is not None:
                    date_candidates.append(nearest_date)

        best: datetime | None = None
        for dc in date_candidates:
            candidate = _earliest_future_at_times(dc, times, tz, now)
            if candidate and (best is None or candidate < best):
                best = candidate
        if best:
            return best

        month += 1
        if month > 12:
            month = 1
            year += 1

    return None


def _next_ordinal_repeat(
    interval: int,
    ordinal: OrdinalPosition,
    day: Weekday,
    times: tuple[TimeOfDay, ...],
    tz: ZoneInfo,
    anchor: str | None,
    now: datetime,
) -> datetime | None:
    now_in_tz = now.astimezone(tz)
    year = now_in_tz.year
    month = now_in_tz.month

    anchor_date = date.fromisoformat(anchor) if anchor else _EPOCH_DATE
    max_iter = 24 * interval if interval > 1 else 24

    for _ in range(max_iter):
        # Check interval alignment
        if interval > 1:
            cur = date(year, month, 1)
            month_offset = _months_between_ym(anchor_date, cur)
            if month_offset < 0 or month_offset % interval != 0:
                month += 1
                if month > 12:
                    month = 1
                    year += 1
                continue

        if ordinal == OrdinalPosition.LAST:
            ordinal_date: date | None = _last_weekday_in_month(year, month, day)
        else:
            ordinal_date = _nth_weekday_of_month(year, month, day, ordinal.to_n())

        if ordinal_date is not None:
            candidate = _earliest_future_at_times(ordinal_date, times, tz, now)
            if candidate:
                return candidate

        month += 1
        if month > 12:
            month = 1
            year += 1

    return None


def _next_single_date(
    date_spec: DateSpec,
    times: tuple[TimeOfDay, ...],
    tz: ZoneInfo,
    now: datetime,
) -> datetime | None:
    now_in_tz = now.astimezone(tz)

    match date_spec:
        case IsoDate(date=iso_str):
            d = date.fromisoformat(iso_str)
            return _earliest_future_at_times(d, times, tz, now)
        case NamedDate(month=m, day=day):
            start_year = now_in_tz.year
            for y in range(8):
                year = start_year + y
                try:
                    d = date(year, m.number, day)
                    candidate = _earliest_future_at_times(d, times, tz, now)
                    if candidate:
                        return candidate
                except ValueError:
                    pass
            return None

    return None  # pragma: no cover


def _next_year_repeat(
    interval: int,
    target: YearTarget,
    times: tuple[TimeOfDay, ...],
    tz: ZoneInfo,
    anchor: str | None,
    now: datetime,
) -> datetime | None:
    now_in_tz = now.astimezone(tz)
    start_year = now_in_tz.year
    anchor_year = date.fromisoformat(anchor).year if anchor else _EPOCH_DATE.year

    max_iter = 8 * interval if interval > 1 else 8

    for y in range(max_iter):
        year = start_year + y

        # Check interval alignment
        if interval > 1:
            year_offset = year - anchor_year
            if year_offset < 0 or year_offset % interval != 0:
                continue

        target_date: date | None = None

        match target:
            case YearDateTarget(month=m, day=day):
                try:
                    target_date = date(year, m.number, day)
                except ValueError:
                    continue
            case YearOrdinalWeekdayTarget(ordinal=ordinal, weekday=weekday, month=m):
                if ordinal == OrdinalPosition.LAST:
                    target_date = _last_weekday_in_month(year, m.number, weekday)
                else:
                    target_date = _nth_weekday_of_month(year, m.number, weekday, ordinal.to_n())
            case YearDayOfMonthTarget(day=day, month=m):
                try:
                    target_date = date(year, m.number, day)
                except ValueError:
                    continue
            case YearLastWeekdayTarget(month=m):
                target_date = _last_weekday_of_month(year, m.number)

        if target_date is not None:
            candidate = _earliest_future_at_times(target_date, times, tz, now)
            if candidate:
                return candidate

    return None


# --- Iterator functions ---


def occurrences(schedule: ScheduleData, from_: datetime) -> Iterator[datetime]:
    """Returns a lazy iterator of occurrences starting after `from_`.

    The iterator is unbounded for repeating schedules (will iterate forever unless limited),
    but respects the `until` clause if specified in the schedule.
    """
    current = from_
    while True:
        nxt = next_from(schedule, current)
        if nxt is None:
            return
        # Advance cursor by 1 minute to avoid returning same occurrence
        current = nxt + timedelta(minutes=1)
        yield nxt


def between(schedule: ScheduleData, from_: datetime, to: datetime) -> Iterator[datetime]:
    """Returns a bounded iterator of occurrences where `from_ < occurrence <= to`.

    The iterator yields occurrences strictly after `from_` and up to and including `to`.
    """
    for dt in occurrences(schedule, from_):
        if dt > to:
            return
        yield dt


# --- Previous From ---


def previous_from(schedule: ScheduleData, now: datetime) -> datetime | None:
    """Compute the most recent occurrence strictly before `now`.

    Returns None if no previous occurrence exists (e.g., before a starting anchor
    or for single dates in the future).
    """
    tz = _resolve_tz(schedule.timezone)
    anchor = schedule.anchor

    named_exc, iso_exc = _parse_exceptions(schedule.except_)
    has_exceptions = len(schedule.except_) > 0
    has_during = len(schedule.during) > 0

    current = now
    for _ in range(1000):
        candidate = _prev_expr(schedule.expr, tz, anchor, current)

        if candidate is None:
            return None

        c_date = candidate.astimezone(tz).date()

        # Check starting anchor - if before anchor, no previous occurrence
        if anchor:
            anchor_date = date.fromisoformat(anchor)
            if c_date < anchor_date:
                return None

        # Apply until filter for previousFrom:
        # If candidate is after until, search earlier
        if schedule.until:
            until_date = _resolve_until(schedule.until, now)
            if c_date > until_date:
                end_of_day = _at_time_on_date(until_date, TimeOfDay(23, 59), tz)
                current = end_of_day + timedelta(seconds=1)
                continue

        # Apply during filter
        if has_during and not _matches_during(c_date, schedule.during):
            skip_to = _prev_during_month(c_date, schedule.during)
            current = _at_time_on_date(skip_to, TimeOfDay(23, 59), tz) + timedelta(seconds=1)
            continue

        # Apply except filter
        if has_exceptions and _is_excepted_parsed(c_date, named_exc, iso_exc):
            prev_day = c_date - timedelta(days=1)
            current = _at_time_on_date(prev_day, TimeOfDay(23, 59), tz) + timedelta(seconds=1)
            continue

        return candidate

    return None


def _prev_expr(
    expr: ScheduleExpr,
    tz: ZoneInfo,
    anchor: str | None,
    now: datetime,
) -> datetime | None:
    match expr:
        case DayRepeat(interval=interval, days=days, times=times):
            return _prev_day_repeat(interval, days, times, tz, anchor, now)
        case IntervalRepeat(
            interval=interval,
            unit=unit,
            from_time=ft,
            to_time=tt,
            day_filter=df,
        ):
            return _prev_interval_repeat(interval, unit, ft, tt, df, tz, now)
        case WeekRepeat(interval=interval, days=days, times=times):
            return _prev_week_repeat(interval, days, times, tz, anchor, now)
        case MonthRepeat(interval=interval, target=target, times=times):
            return _prev_month_repeat(interval, target, times, tz, anchor, now)
        case OrdinalRepeat(interval=interval, ordinal=ordinal, day=day, times=times):
            return _prev_ordinal_repeat(interval, ordinal, day, times, tz, anchor, now)
        case SingleDateExpr(date=date_spec, times=times):
            return _prev_single_date(date_spec, times, tz, now)
        case YearRepeat(interval=interval, target=target, times=times):
            return _prev_year_repeat(interval, target, times, tz, anchor, now)
    return None  # pragma: no cover


def _prev_during_month(d: date, during: tuple[MonthName, ...]) -> date:
    """Find the last day of the previous month in the during list."""
    during_months = sorted((mn.number for mn in during), reverse=True)
    year = d.year
    month = d.month - 1
    if month < 1:
        month = 12
        year -= 1

    # Search backwards through months to find one in the during list
    for _ in range(13):
        if month in during_months:
            return _last_day_of_month(year, month)
        month -= 1
        if month < 1:
            month = 12
            year -= 1

    return d - timedelta(days=1)


def _latest_past_at_times(
    d: date,
    times: tuple[TimeOfDay, ...],
    tz: ZoneInfo,
    now: datetime,
) -> datetime | None:
    """Find the latest time on date d that is strictly before now."""
    sorted_times = sorted(times, key=lambda t: (t.hour, t.minute), reverse=True)
    for tod in sorted_times:
        candidate = _at_time_on_date(d, tod, tz)
        if candidate < now:
            return candidate
    return None


def _latest_at_times(
    d: date,
    times: tuple[TimeOfDay, ...],
    tz: ZoneInfo,
) -> datetime | None:
    """Find the latest time on date d."""
    if not times:
        return None
    sorted_times = sorted(times, key=lambda t: (t.hour, t.minute))
    latest = sorted_times[-1]
    return _at_time_on_date(d, latest, tz)


def _prev_day_repeat(
    interval: int,
    days: DayFilter,
    times: tuple[TimeOfDay, ...],
    tz: ZoneInfo,
    anchor: str | None,
    now: datetime,
) -> datetime | None:
    now_in_tz = now.astimezone(tz)
    d = now_in_tz.date()

    if interval <= 1:
        # Check today for times that have passed
        if _matches_day_filter(d, days):
            candidate = _latest_past_at_times(d, times, tz, now)
            if candidate is not None:
                return candidate

        # Go back day by day
        for _ in range(8):
            d -= timedelta(days=1)
            if _matches_day_filter(d, days):
                candidate = _latest_at_times(d, times, tz)
                if candidate is not None:
                    return candidate

        return None

    # Interval > 1
    anchor_date = date.fromisoformat(anchor) if anchor else _EPOCH_DATE
    offset = _days_between(anchor_date, d)
    remainder = offset % interval
    aligned_date = d if remainder == 0 else d - timedelta(days=remainder)

    for _ in range(2):
        candidate = _latest_past_at_times(aligned_date, times, tz, now)
        if candidate is not None:
            return candidate
        latest = _latest_at_times(aligned_date, times, tz)
        if latest is not None and latest < now:
            return latest
        aligned_date -= timedelta(days=interval)

    return None


def _prev_interval_repeat(
    interval: int,
    unit: IntervalUnit,
    from_time: TimeOfDay,
    to_time: TimeOfDay,
    day_filter: DayFilter | None,
    tz: ZoneInfo,
    now: datetime,
) -> datetime | None:
    now_in_tz = now.astimezone(tz)
    d = now_in_tz.date()

    step_minutes = interval if unit == IntervalUnit.MIN else interval * 60
    from_minutes = from_time.hour * 60 + from_time.minute
    to_minutes = to_time.hour * 60 + to_time.minute

    for day_offset in range(8):
        if day_filter is not None and not _matches_day_filter(d, day_filter):
            d -= timedelta(days=1)
            continue

        now_minutes = now_in_tz.hour * 60 + now_in_tz.minute if day_offset == 0 else to_minutes + 1
        search_until = min(now_minutes, to_minutes)

        if search_until >= from_minutes:
            slots_in_range = (search_until - from_minutes) // step_minutes
            last_slot_minutes = from_minutes + slots_in_range * step_minutes

            if day_offset == 0 and last_slot_minutes >= now_minutes:
                last_slot_minutes -= step_minutes

            if last_slot_minutes >= from_minutes:
                h = last_slot_minutes // 60
                m = last_slot_minutes % 60
                return _at_time_on_date(d, TimeOfDay(h, m), tz)

        d -= timedelta(days=1)

    return None


def _prev_week_repeat(
    interval: int,
    days: tuple[Weekday, ...],
    times: tuple[TimeOfDay, ...],
    tz: ZoneInfo,
    anchor: str | None,
    now: datetime,
) -> datetime | None:
    now_in_tz = now.astimezone(tz)
    d = now_in_tz.date()
    anchor_date = date.fromisoformat(anchor) if anchor else _EPOCH_MONDAY

    # Sort target DOWs in reverse order for latest-first matching
    sorted_days = sorted(days, key=lambda wd: wd.number, reverse=True)

    # Find Monday of current week and Monday of anchor week
    dow_offset = d.isoweekday() - 1
    current_monday = d - timedelta(days=dow_offset)

    anchor_dow_offset = anchor_date.isoweekday() - 1
    anchor_monday = anchor_date - timedelta(days=anchor_dow_offset)

    for _ in range(54):
        weeks = _weeks_between(anchor_monday, current_monday)

        if weeks < 0:
            return None

        if weeks % interval == 0:
            # Aligned week — try each target DOW in reverse order
            for wd in sorted_days:
                day_offset = wd.number - 1
                target_date = current_monday + timedelta(days=day_offset)
                if target_date > d:
                    continue
                if target_date == d:
                    candidate = _latest_past_at_times(target_date, times, tz, now)
                    if candidate is not None:
                        return candidate
                else:
                    candidate = _latest_at_times(target_date, times, tz)
                    if candidate is not None:
                        return candidate

        # Go back to previous aligned week
        remainder = weeks % interval
        skip_weeks = interval if remainder == 0 else remainder
        current_monday -= timedelta(days=skip_weeks * 7)

    return None


def _prev_month_repeat(
    interval: int,
    target: MonthTarget,
    times: tuple[TimeOfDay, ...],
    tz: ZoneInfo,
    anchor: str | None,
    now: datetime,
) -> datetime | None:
    now_in_tz = now.astimezone(tz)
    start_date = now_in_tz.date()
    year = start_date.year
    month = start_date.month

    anchor_date = date.fromisoformat(anchor) if anchor else _EPOCH_DATE
    max_iter = 24 * interval if interval > 1 else 24

    for _ in range(max_iter):
        # Check interval alignment
        if interval > 1:
            cur = date(year, month, 1)
            month_offset = _months_between_ym(anchor_date, cur)
            if month_offset < 0 or month_offset % interval != 0:
                month -= 1
                if month < 1:
                    month = 12
                    year -= 1
                continue

        date_candidates: list[date] = []

        match target:
            case DaysTarget():
                expanded = expand_month_target(target)
                last = _last_day_of_month(year, month)
                for day_num in expanded:
                    if day_num <= last.day:
                        with contextlib.suppress(ValueError):
                            date_candidates.append(date(year, month, day_num))
            case LastDayTarget():
                date_candidates.append(_last_day_of_month(year, month))
            case LastWeekdayTarget():
                date_candidates.append(_last_weekday_of_month(year, month))
            case NearestWeekdayTarget(day=target_day, direction=direction):
                nearest_date = _nearest_weekday(year, month, target_day, direction)
                if nearest_date is not None:
                    date_candidates.append(nearest_date)

        # Sort in reverse order for latest first
        for dc in sorted(date_candidates, reverse=True):
            if dc > start_date:
                continue
            if dc == start_date:
                candidate = _latest_past_at_times(dc, times, tz, now)
                if candidate is not None:
                    return candidate
            else:
                candidate = _latest_at_times(dc, times, tz)
                if candidate is not None:
                    return candidate

        month -= 1
        if month < 1:
            month = 12
            year -= 1

    return None


def _prev_ordinal_repeat(
    interval: int,
    ordinal: OrdinalPosition,
    day: Weekday,
    times: tuple[TimeOfDay, ...],
    tz: ZoneInfo,
    anchor: str | None,
    now: datetime,
) -> datetime | None:
    now_in_tz = now.astimezone(tz)
    start_date = now_in_tz.date()
    year = start_date.year
    month = start_date.month

    anchor_date = date.fromisoformat(anchor) if anchor else _EPOCH_DATE
    max_iter = 24 * interval if interval > 1 else 24

    for _ in range(max_iter):
        # Check interval alignment
        if interval > 1:
            cur = date(year, month, 1)
            month_offset = _months_between_ym(anchor_date, cur)
            if month_offset < 0 or month_offset % interval != 0:
                month -= 1
                if month < 1:
                    month = 12
                    year -= 1
                continue

        if ordinal == OrdinalPosition.LAST:
            ordinal_date: date | None = _last_weekday_in_month(year, month, day)
        else:
            ordinal_date = _nth_weekday_of_month(year, month, day, ordinal.to_n())

        if ordinal_date is not None:
            if ordinal_date > start_date:
                # Future, skip
                pass
            elif ordinal_date == start_date:
                candidate = _latest_past_at_times(ordinal_date, times, tz, now)
                if candidate is not None:
                    return candidate
            else:
                candidate = _latest_at_times(ordinal_date, times, tz)
                if candidate is not None:
                    return candidate

        month -= 1
        if month < 1:
            month = 12
            year -= 1

    return None


def _prev_single_date(
    date_spec: DateSpec,
    times: tuple[TimeOfDay, ...],
    tz: ZoneInfo,
    now: datetime,
) -> datetime | None:
    now_in_tz = now.astimezone(tz)
    now_date = now_in_tz.date()

    match date_spec:
        case IsoDate(date=iso_str):
            target_date = date.fromisoformat(iso_str)
            if target_date > now_date:
                return None  # Future date
            if target_date == now_date:
                return _latest_past_at_times(target_date, times, tz, now)
            return _latest_at_times(target_date, times, tz)
        case NamedDate(month=m, day=day_num):
            # Find most recent occurrence
            try:
                this_year = date(now_date.year, m.number, day_num)
            except ValueError:
                this_year = None
            try:
                last_year = date(now_date.year - 1, m.number, day_num)
            except ValueError:
                last_year = None

            if this_year is not None and this_year < now_date:
                target_date = this_year
            elif this_year is not None and this_year == now_date:
                candidate = _latest_past_at_times(this_year, times, tz, now)
                if candidate is not None:
                    return candidate
                target_date = last_year
            else:
                target_date = last_year

            if target_date is not None:
                return _latest_at_times(target_date, times, tz)
            return None

    return None  # pragma: no cover


def _prev_year_repeat(
    interval: int,
    target: YearTarget,
    times: tuple[TimeOfDay, ...],
    tz: ZoneInfo,
    anchor: str | None,
    now: datetime,
) -> datetime | None:
    now_in_tz = now.astimezone(tz)
    start_date = now_in_tz.date()
    start_year = start_date.year
    anchor_year = date.fromisoformat(anchor).year if anchor else _EPOCH_DATE.year

    max_iter = 8 * interval if interval > 1 else 8

    for y in range(max_iter):
        year = start_year - y

        # Check interval alignment
        if interval > 1:
            year_offset = year - anchor_year
            if year_offset < 0 or year_offset % interval != 0:
                continue

        target_date: date | None = None

        match target:
            case YearDateTarget(month=m, day=day_val):
                try:
                    target_date = date(year, m.number, day_val)
                except ValueError:
                    continue
            case YearOrdinalWeekdayTarget(ordinal=ord_val, weekday=weekday, month=m):
                if ord_val == OrdinalPosition.LAST:
                    target_date = _last_weekday_in_month(year, m.number, weekday)
                else:
                    target_date = _nth_weekday_of_month(year, m.number, weekday, ord_val.to_n())
            case YearDayOfMonthTarget(day=day_val, month=m):
                try:
                    target_date = date(year, m.number, day_val)
                except ValueError:
                    continue
            case YearLastWeekdayTarget(month=m):
                target_date = _last_weekday_of_month(year, m.number)

        if target_date is not None:
            if target_date > start_date:
                continue  # Future
            if target_date == start_date:
                candidate = _latest_past_at_times(target_date, times, tz, now)
                if candidate is not None:
                    return candidate
            else:
                candidate = _latest_at_times(target_date, times, tz)
                if candidate is not None:
                    return candidate

    return None
