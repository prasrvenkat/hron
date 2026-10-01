"""Date arithmetic on the proleptic Gregorian calendar: no time zones, no schedules."""

from __future__ import annotations

import calendar
from dataclasses import dataclass
from datetime import MAXYEAR, MINYEAR, date, timedelta

from ._ast import (
    DayFilter,
    DayFilterDays,
    DayFilterEvery,
    DayFilterWeekday,
    DayFilterWeekend,
    DaysTarget,
    LastDayTarget,
    LastWeekdayTarget,
    MonthTarget,
    NearestDirection,
    NearestWeekdayTarget,
    OrdinalPosition,
    OrdinalWeekdayTarget,
    Weekday,
    YearDateTarget,
    YearDayOfMonthTarget,
    YearLastWeekdayTarget,
    YearOrdinalWeekdayTarget,
    YearTarget,
    expand_month_target,
)

DAYS_PER_400_YEARS = 146_097


@dataclass(frozen=True, slots=True)
class YearMonth:
    """A month that may lie in year 0, before `date`'s years, where a directional nearest
    weekday can still land inside them: `next nearest weekday to 31st` moves Sunday
    0000-12-31 to Monday 0001-01-01."""

    year: int
    month: int


def year_month(index: int) -> YearMonth | None:
    """Month `index` counted from January of year 0, or None outside year 0 and `date`'s
    years."""
    year, month = divmod(index, 12)
    return YearMonth(year, month + 1) if MINYEAR - 1 <= year <= MAXYEAR else None


def month_index(d: date) -> int:
    return d.year * 12 + d.month - 1


def add_days(d: date, days: int) -> date | None:
    try:
        return d + timedelta(days=days)
    except OverflowError:
        return None


def days_between(a: date, b: date) -> int:
    return (b - a).days


def days_in_month(year: int, month: int) -> int:
    return calendar.monthrange(year, month)[1]


def monday_of_week(d: date) -> date:
    return d - timedelta(days=d.weekday())


def date_if_valid(year: int, month: int, day: int) -> date | None:
    try:
        return date(year, month, day)
    except ValueError:
        return None


def matches_day_filter(d: date, day_filter: DayFilter) -> bool:
    match day_filter:
        case DayFilterEvery():
            return True
        case DayFilterWeekday():
            return d.isoweekday() <= 5
        case DayFilterWeekend():
            return d.isoweekday() >= 6
        case DayFilterDays(days=days):
            return any(day.number == d.isoweekday() for day in days)


def month_target_dates(month: YearMonth, target: MonthTarget) -> list[date]:
    """The dates a monthly target names in a month, earliest first."""
    year, number = month.year, month.month
    if isinstance(target, NearestWeekdayTarget):
        nearest = nearest_weekday(month, target.day, target.direction)
        return [] if nearest is None else [nearest]
    if not MINYEAR <= year <= MAXYEAR:
        return []
    match target:
        case DaysTarget():
            last = days_in_month(year, number)
            days = sorted(expand_month_target(target))
            return [date(year, number, day) for day in days if day <= last]
        case LastDayTarget():
            return [last_day_of_month(year, number)]
        case LastWeekdayTarget():
            return [last_weekday_of_month(year, number)]
        case OrdinalWeekdayTarget(ordinal=ordinal, weekday=weekday):
            nth = ordinal_weekday(year, number, ordinal, weekday)
            return [] if nth is None else [nth]


def year_target_date(year: int, target: YearTarget) -> date | None:
    match target:
        case YearDateTarget(month=month, day=day) | YearDayOfMonthTarget(month=month, day=day):
            return date_if_valid(year, month.number, day)
        case YearOrdinalWeekdayTarget(ordinal=ordinal, weekday=weekday, month=month):
            return ordinal_weekday(year, month.number, ordinal, weekday)
        case YearLastWeekdayTarget(month=month):
            return last_weekday_of_month(year, month.number)


def last_day_of_month(year: int, month: int) -> date:
    return date(year, month, days_in_month(year, month))


def last_weekday_of_month(year: int, month: int) -> date:
    """The last Monday to Friday of a month."""
    last = last_day_of_month(year, month)
    return last - timedelta(days=max(last.isoweekday() - 5, 0))


def ordinal_weekday(
    year: int, month: int, ordinal: OrdinalPosition, weekday: Weekday
) -> date | None:
    if ordinal == OrdinalPosition.LAST:
        last = last_day_of_month(year, month)
        return last - timedelta(days=(last.isoweekday() - weekday.number) % 7)
    first = calendar.weekday(year, month, 1) + 1
    return date_if_valid(year, month, 1 + (weekday.number - first) % 7 + 7 * (ordinal.to_n() - 1))


def nearest_weekday(month: YearMonth, day: int, toward: NearestDirection | None) -> date | None:
    """The weekday nearest `day` of a month, or None when the month is shorter or the
    weekday lies outside `date`'s years. Without a direction it stays in the month, as
    cron's `W` does; with one it can cross into the adjacent month (spec/README.md,
    "Nearest weekday and `during`")."""
    year, number = month.year, month.month
    last = days_in_month(year, number)
    if day > last:
        return None
    shift = 0
    match calendar.weekday(year, number, day):
        case calendar.SATURDAY:
            to_monday = toward == NearestDirection.NEXT or (toward is None and day == 1)
            shift = 2 if to_monday else -1
        case calendar.SUNDAY:
            to_friday = toward == NearestDirection.PREVIOUS or (toward is None and day == last)
            shift = -2 if to_friday else 1
    ordinal = _proleptic_ordinal(year, number, day) + shift
    return date.fromordinal(ordinal) if 1 <= ordinal <= date.max.toordinal() else None


def _proleptic_ordinal(year: int, month: int, day: int) -> int:
    """`date.toordinal()`, extended to years outside `date`'s through the 400-year cycle."""
    cycles = 0 if MINYEAR <= year <= MAXYEAR else (year - 2000) // 400
    return date(year - 400 * cycles, month, day).toordinal() + cycles * DAYS_PER_400_YEARS
