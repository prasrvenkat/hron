from __future__ import annotations

from collections.abc import Iterable
from itertools import pairwise
from typing import NamedTuple

from ._ast import (
    ALL_WEEKDAYS,
    ALL_WEEKEND,
    DayFilter,
    DayFilterDays,
    DayFilterEvery,
    DayFilterWeekday,
    DayFilterWeekend,
    DayOfMonthSpec,
    DayRange,
    DayRepeat,
    DaysTarget,
    IntervalRepeat,
    IntervalUnit,
    IsoDate,
    LastDayTarget,
    LastWeekdayTarget,
    MonthName,
    MonthRepeat,
    MonthTarget,
    NamedDate,
    NearestWeekdayTarget,
    OrdinalPosition,
    OrdinalWeekdayTarget,
    ScheduleData,
    ScheduleExpr,
    SingleDateExpr,
    SingleDay,
    TimeOfDay,
    Weekday,
    WeekRepeat,
    YearDateTarget,
    YearDayOfMonthTarget,
    YearLastWeekdayTarget,
    YearOrdinalWeekdayTarget,
    YearRepeat,
    YearTarget,
    expand_month_target,
    new_schedule_data,
)
from ._error import HronError
from ._eval import interval_slots

_MAX_LISTED_TIMES = 24
_BOTH_DAYS_RESTRICTED = (
    "not expressible in hron: cron fires on either the day of month or the day of week"
)
_INTERVAL_DAYS = (
    "not expressible in hron: an interval runs only on every day, weekdays, the weekend"
    " or listed days"
)
_MINUTES_PER_DAY = 24 * 60
_MIDNIGHT = TimeOfDay(0, 0)
_END_OF_DAY = TimeOfDay(23, 59)

# Digit strings may be of any length. Every number at or above this cap is out of every
# field's range and steps past every range's end, so saturating at it keeps each
# comparison exact.
_NUMBER_CAP = 1000

_ASCII_LOWER = str.maketrans("ABCDEFGHIJKLMNOPQRSTUVWXYZ", "abcdefghijklmnopqrstuvwxyz")
_DIGITS = "0123456789"

_MONTH_NAMES = ("jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec")
_DAY_NAMES = ("sun", "mon", "tue", "wed", "thu", "fri", "sat")
_MONTHS = tuple(MonthName)
_WEEKDAYS = (
    Weekday.SUNDAY,
    Weekday.MONDAY,
    Weekday.TUESDAY,
    Weekday.WEDNESDAY,
    Weekday.THURSDAY,
    Weekday.FRIDAY,
    Weekday.SATURDAY,
)
_ORDINALS = (
    OrdinalPosition.FIRST,
    OrdinalPosition.SECOND,
    OrdinalPosition.THIRD,
    OrdinalPosition.FOURTH,
    OrdinalPosition.FIFTH,
)


class _Field(NamedTuple):
    name: str
    min: int
    max: int
    # In the day of week, 7 is Sunday only where written: `*` and `a/n` end at 6.
    star_end: int
    names: tuple[str, ...]


_MINUTE = _Field("minute", 0, 59, 59, ())
_HOUR = _Field("hour", 0, 23, 23, ())
_DAY_OF_MONTH = _Field("day of month", 1, 31, 31, ())
_MONTH = _Field("month", 1, 12, 12, _MONTH_NAMES)
_DAY_OF_WEEK = _Field("day of week", 0, 7, 6, _DAY_NAMES)


class _Item(NamedTuple):
    bounds: tuple[str] | tuple[str, str]
    step: str | None


_MonthDays = list[int] | LastDayTarget | LastWeekdayTarget | NearestWeekdayTarget | None
_WeekDays = list[int] | OrdinalWeekdayTarget | None
_Days = DayFilter | MonthTarget


def from_cron(cron: str) -> ScheduleData:
    text = cron.strip(" \t\r\n")
    if text.startswith("@"):
        text = _shortcut(text)
    fields = [field for field in text.replace("\t", " ").split(" ") if field]
    if len(fields) != 5:
        raise HronError.cron(f"expected 5 cron fields, got {len(fields)}")
    minute, hour, day_of_month, month, day_of_week = fields

    minutes = sorted(_values(minute, _MINUTE))
    hours = sorted(_values(hour, _HOUR))
    month_days = _parse_day_of_month(day_of_month)
    months = sorted(_values(month, _MONTH))
    week_days = _parse_day_of_week(day_of_week)
    days = _day_expression(month_days, week_days)
    times = [TimeOfDay(h, m) for h in hours for m in minutes]

    gap = _equal_gap(times)
    expr: ScheduleExpr
    if isinstance(days, DayFilter) and gap is not None:
        expr = _interval(times, gap, days)
    elif len(times) > _MAX_LISTED_TIMES:
        raise _too_many_times(len(times), gap)
    elif (target := _year_target(days, months)) is not None:
        expr = YearRepeat(interval=1, target=target, times=tuple(times))
    elif isinstance(days, DayFilter):
        expr = DayRepeat(interval=1, days=days, times=tuple(times))
    else:
        expr = MonthRepeat(interval=1, target=days, times=tuple(times))
    schedule = new_schedule_data(expr)
    if not isinstance(expr, YearRepeat) and len(months) < len(_MONTHS):
        schedule.during = tuple(_MONTHS[m - 1] for m in months)
    return schedule


def _shortcut(text: str) -> str:
    match text.translate(_ASCII_LOWER):
        case "@yearly" | "@annually":
            return "0 0 1 1 *"
        case "@monthly":
            return "0 0 1 * *"
        case "@weekly":
            return "0 0 * * 0"
        case "@daily" | "@midnight":
            return "0 0 * * *"
        case "@hourly":
            return "0 * * * *"
        case _:
            raise HronError.cron(f"unknown cron shortcut: {text}")


def _parse_day_of_month(text: str) -> _MonthDays:
    if text in ("*", "?"):
        return None
    lower = text.translate(_ASCII_LOWER)
    if lower == "l":
        return LastDayTarget()
    if lower == "lw":
        return LastWeekdayTarget()
    if lower.endswith("w") and _is_number(text[:-1]):
        return NearestWeekdayTarget(day=_field_value(text[:-1], _DAY_OF_MONTH), direction=None)
    return _values(text, _DAY_OF_MONTH)


def _parse_day_of_week(text: str) -> _WeekDays:
    field = _DAY_OF_WEEK
    if text in ("*", "?"):
        return None
    day, hash_sign, nth = text.partition("#")
    if hash_sign and _is_value(day, field) and _is_number(nth):
        weekday = _WEEKDAYS[_field_value(day, field) % 7]
        n = _number(nth)
        if not 1 <= n <= 5:
            raise HronError.cron(f"day of week ordinal must be 1-5, got {nth}")
        return OrdinalWeekdayTarget(ordinal=_ORDINALS[n - 1], weekday=weekday)
    if text.translate(_ASCII_LOWER).endswith("l") and _is_value(text[:-1], field):
        weekday = _WEEKDAYS[_field_value(text[:-1], field) % 7]
        return OrdinalWeekdayTarget(ordinal=OrdinalPosition.LAST, weekday=weekday)
    return _values(text, field)


# Keeps the order of first appearance, in which fromCron lists days of the week.
def _values(text: str, field: _Field) -> list[int]:
    items = _items(text, field)
    if items is None:
        raise HronError.cron(f"invalid {field.name}: {text}")
    values: list[int] = []
    for item in items:
        if item.bounds == ("*",):
            first, last = field.min, field.star_end
        elif len(item.bounds) == 1:
            first = _field_value(item.bounds[0], field)
            # `7/n` starts past the end of `*`, so it is Sunday alone.
            last = max(first, field.star_end) if item.step is not None else first
        else:
            a, b = item.bounds
            first, last = _field_value(a, field), _field_value(b, field)
            if first > last:
                raise HronError.cron(f"{field.name} range must not run backwards: {a}-{b}")
        step = 1 if item.step is None else _number(item.step)
        if step == 0:
            raise HronError.cron(f"{field.name} step must be at least 1")
        for value in range(first, last + 1, step):
            if field is _DAY_OF_WEEK:
                value %= 7
            if value not in values:
                values.append(value)
    return values


def _items(text: str, field: _Field) -> list[_Item] | None:
    items: list[_Item] = []
    for item in text.split(","):
        base, slash, step_text = item.partition("/")
        step = step_text if slash else None
        a, dash, b = base.partition("-")
        bounds: tuple[str] | tuple[str, str] = (a, b) if dash else (base,)
        valid = (step is None or _is_number(step)) and (
            base == "*" or all(_is_value(v, field) for v in bounds)
        )
        if not valid:
            return None
        items.append(_Item(bounds, step))
    return items


def _is_number(text: str) -> bool:
    return text != "" and all(c in _DIGITS for c in text)


def _is_value(text: str, field: _Field) -> bool:
    return _is_number(text) or _name_value(text, field) is not None


def _name_value(text: str, field: _Field) -> int | None:
    lower = text.translate(_ASCII_LOWER)
    for index, name in enumerate(field.names):
        if name == lower:
            return index + field.min
    return None


def _number(digits: str) -> int:
    n = 0
    for digit in digits:
        n = min(n * 10 + ord(digit) - ord("0"), _NUMBER_CAP)
    return n


def _field_value(text: str, field: _Field) -> int:
    value = _name_value(text, field)
    if value is None:
        value = _number(text)
    if value < field.min or value > field.max:
        raise HronError.cron(f"{field.name} must be {field.min}-{field.max}, got {text}")
    return value


def _day_expression(month_days: _MonthDays, week_days: _WeekDays) -> _Days:
    match month_days, week_days:
        case None, None:
            return DayFilterEvery()
        case None, list(days):
            return _weekday_filter(days)
        case None, OrdinalWeekdayTarget() as target:
            return target
        case list(days), None if len(days) == 31:
            return DayFilterEvery()
        case list(days), None:
            specs: list[DayOfMonthSpec] = [
                SingleDay(first) if first == last else DayRange(first, last)
                for first, last in _runs(sorted(days))
            ]
            return DaysTarget(tuple(specs))
        case (LastDayTarget() | LastWeekdayTarget() | NearestWeekdayTarget()) as target, None:
            return target
        case _:
            raise HronError.cron(_BOTH_DAYS_RESTRICTED)


def _weekday_filter(days: list[int]) -> DayFilter:
    match sorted(days):
        case [0, 1, 2, 3, 4, 5, 6]:
            return DayFilterEvery()
        case [1, 2, 3, 4, 5]:
            return DayFilterWeekday()
        case [0, 6]:
            return DayFilterWeekend()
        case _:
            return DayFilterDays(tuple(_WEEKDAYS[d] for d in days))


def _equal_gap(times: list[TimeOfDay]) -> int | None:
    minutes = [_minute_of_day(t) for t in times]
    if len(minutes) < 2:
        return None
    gap = minutes[1] - minutes[0]
    equal = len(minutes) >= 3 and all(b - a == gap for a, b in pairwise(minutes))
    return gap if equal else None


def _interval(times: list[TimeOfDay], gap: int, days: DayFilter) -> IntervalRepeat:
    start = times[0]
    last = times[-1]
    if start == _MIDNIGHT and _minute_of_day(last) + gap >= _MINUTES_PER_DAY:
        end = _END_OF_DAY
    else:
        end = last
    if gap % 60 == 0:
        interval, unit = gap // 60, IntervalUnit.HOURS
    else:
        interval, unit = gap, IntervalUnit.MIN
    return IntervalRepeat(
        interval=interval,
        unit=unit,
        from_time=start,
        to_time=end,
        day_filter=None if days == DayFilterEvery() else days,
    )


def _too_many_times(count: int, gap: int | None) -> HronError:
    if gap is not None:
        return HronError.cron(_INTERVAL_DAYS)
    return HronError.cron(f"not expressible in hron: {count} times a day are too many to list")


def _year_target(days: _Days, months: list[int]) -> YearTarget | None:
    if isinstance(days, DayFilter) or len(months) != 1:
        return None
    month = _MONTHS[months[0] - 1]
    match days:
        case DaysTarget(specs=(SingleDay(day=day),)) if day <= _max_day(month):
            return YearDateTarget(month=month, day=day)
        case LastWeekdayTarget():
            return YearLastWeekdayTarget(month=month)
        case OrdinalWeekdayTarget(ordinal=ordinal, weekday=weekday):
            return YearOrdinalWeekdayTarget(ordinal=ordinal, weekday=weekday, month=month)
        case _:
            return None


def _max_day(month: MonthName) -> int:
    match month:
        case MonthName.FEB:
            return 29
        case MonthName.APR | MonthName.JUN | MonthName.SEP | MonthName.NOV:
            return 30
        case _:
            return 31


def to_cron(schedule: ScheduleData) -> str:
    if schedule.except_:
        raise _not_expressible("except clauses not supported")
    if schedule.until is not None:
        raise _not_expressible("until clauses not supported")
    if schedule.anchor is not None:
        raise _not_expressible("starting clauses not supported")
    day_of_month, day_of_week = _day_fields(schedule.expr)
    # A schedule built in code can have an empty day list, which writes an empty field.
    if not day_of_month or not day_of_week:
        raise _not_expressible("schedule has no days")
    month = _month_field(schedule)
    minute, hour = _time_fields(schedule.expr)
    return f"{minute} {hour} {day_of_month} {month} {day_of_week}"


def _not_expressible(reason: str) -> HronError:
    return HronError.cron(f"not expressible as cron: {reason}")


def _repeats_once(interval: int, unit: str) -> None:
    if interval > 1:
        raise _not_expressible(f"multi-{unit} repeats not supported")


def _day_fields(expr: ScheduleExpr) -> tuple[str, str]:
    match expr:
        case IntervalRepeat(day_filter=day_filter):
            return "*", "*" if day_filter is None else _filter_field(day_filter)
        case DayRepeat(interval=interval, days=days):
            _repeats_once(interval, "day")
            return "*", _filter_field(days)
        case WeekRepeat(interval=interval, days=week_days):
            _repeats_once(interval, "week")
            return "*", _weekdays_field(week_days)
        case MonthRepeat(interval=interval, target=target):
            _repeats_once(interval, "month")
            match target:
                case DaysTarget():
                    days = _sorted_unique(expand_month_target(target))
                    return _list_field(days, 31), "*"
                case LastDayTarget():
                    return "L", "*"
                case LastWeekdayTarget():
                    return "LW", "*"
                case NearestWeekdayTarget(day=day, direction=direction):
                    if direction is not None:
                        raise _not_expressible("directional nearest weekday not supported")
                    return f"{day}W", "*"
                case OrdinalWeekdayTarget(ordinal=ordinal, weekday=weekday):
                    return "*", _ordinal_field(ordinal, weekday)
        case YearRepeat(interval=interval, target=year_target):
            _repeats_once(interval, "year")
            match year_target:
                case YearDateTarget(day=day) | YearDayOfMonthTarget(day=day):
                    return str(day), "*"
                case YearOrdinalWeekdayTarget(ordinal=ordinal, weekday=weekday):
                    return "*", _ordinal_field(ordinal, weekday)
                case YearLastWeekdayTarget():
                    return "LW", "*"
        case SingleDateExpr(date=date):
            match date:
                case IsoDate():
                    raise _not_expressible("ISO dates do not repeat")
                case NamedDate(day=day):
                    return str(day), "*"


def _month_field(schedule: ScheduleData) -> str:
    during = schedule.during
    month = _own_month(schedule.expr)
    if month is not None:
        if during and month not in during:
            raise _not_expressible("during excludes the schedule's month")
        return str(month.number)
    if not during:
        return "*"
    return _list_field(_sorted_unique(m.number for m in during), 12)


def _own_month(expr: ScheduleExpr) -> MonthName | None:
    match expr:
        case YearRepeat(target=target):
            return target.month
        case SingleDateExpr(date=NamedDate(month=month)):
            return month
        case _:
            return None


def _time_fields(expr: ScheduleExpr) -> tuple[str, str]:
    times = _daily_times(expr)
    minutes = _sorted_unique(t % 60 for t in times)
    hours = _sorted_unique(t // 60 for t in times)
    # A schedule built in code can have no times, which no cron writes.
    if not times:
        raise _not_expressible("schedule has no times")
    if len(minutes) * len(hours) != len(times):
        raise _not_expressible("times are not every combination of their minutes and hours")
    return _step_field(minutes, 60), _step_field(hours, 24)


def _daily_times(expr: ScheduleExpr) -> list[int]:
    match expr:
        case IntervalRepeat(interval=interval, unit=unit, from_time=start, to_time=end):
            return _sorted_unique(interval_slots(interval, unit, start, end))
        case _:
            return _sorted_unique(_minute_of_day(t) for t in expr.times)


def _filter_field(day_filter: DayFilter) -> str:
    match day_filter:
        case DayFilterEvery():
            return "*"
        case DayFilterWeekday():
            return _weekdays_field(ALL_WEEKDAYS)
        case DayFilterWeekend():
            return _weekdays_field(ALL_WEEKEND)
        case DayFilterDays(days=days):
            return _weekdays_field(days)


def _weekdays_field(days: Iterable[Weekday]) -> str:
    return _list_field(_sorted_unique(d.cron_dow for d in days), 7)


def _ordinal_field(ordinal: OrdinalPosition, weekday: Weekday) -> str:
    day = weekday.cron_dow
    if ordinal in _ORDINALS:
        return f"{day}#{_ORDINALS.index(ordinal) + 1}"
    return f"{day}L"


def _step_field(values: list[int], size: int) -> str:
    first = values[0]
    last = values[-1]
    gap = values[1] - first if len(values) > 1 else None
    equal_gaps = gap is not None and all(b - a == gap for a, b in pairwise(values))
    if len(values) == size:
        return "*"
    if gap is None:
        return str(first)
    if equal_gaps and first == 0 and last + gap == size:
        return f"*/{gap}"
    if equal_gaps and gap == 1:
        return f"{first}-{last}"
    if equal_gaps and len(values) >= 3:
        return f"{first}-{last}/{gap}"
    return _list_field(values, size)


def _list_field(values: list[int], size: int) -> str:
    if len(values) == size:
        return "*"
    return ",".join(
        str(first) if first == last else f"{first}-{last}" for first, last in _runs(values)
    )


def _runs(sorted_values: list[int]) -> list[tuple[int, int]]:
    runs: list[tuple[int, int]] = []
    for value in sorted_values:
        if runs and runs[-1][1] + 1 == value:
            runs[-1] = (runs[-1][0], value)
        else:
            runs.append((value, value))
    return runs


def _minute_of_day(time: TimeOfDay) -> int:
    return time.hour * 60 + time.minute


def _sorted_unique(values: Iterable[int]) -> list[int]:
    return sorted(set(values))
