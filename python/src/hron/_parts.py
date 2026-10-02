"""The checks of spec/README.md, "Schedules built in code", in its order. `checked` returns a new
ScheduleData of frozen parts and tuples, so a built schedule shares nothing its caller can change.
A name is an Enum member, so a value of another type where a name goes is a TypeError; the AST's
unions (expression, day filter, ...) have no type of their own, so any other value in their place
is an unknown value of its kind."""

from __future__ import annotations

from datetime import date
from enum import Enum
from typing import TypeVar

from ._ast import (
    DateSpec,
    DayFilter,
    DayFilterDays,
    DayFilterEvery,
    DayFilterWeekday,
    DayFilterWeekend,
    DayOfMonthSpec,
    DayRange,
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
    SingleDay,
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
    max_day,
)
from ._display import ordinal_suffix
from ._error import HronError
from ._parser import canonical_timezone

_MAX_INTERVAL = 2147483647

_ASCII_DIGITS = frozenset("0123456789")

_Member = TypeVar("_Member", bound=Enum)


def checked(data: ScheduleData) -> ScheduleData:
    if not isinstance(data, ScheduleData):
        raise TypeError(f"a schedule is built from ScheduleData, got {type(data).__name__}")
    expr = _expression(data.expr)
    except_ = tuple(_exception(e) for e in _sequence("except_", data.except_))
    until = None if data.until is None else _until(data.until)
    anchor = None if data.anchor is None else _iso_date(data.anchor)
    during = tuple(_member(MonthName, "month", m) for m in _sequence("during", data.during))
    timezone = None if data.timezone is None else _timezone(data.timezone)
    if isinstance(until, NamedUntil) and anchor is None:
        raise _error(
            f"until {until.month} {until.day} has no year: add a starting date, or use an ISO date"
        )
    return ScheduleData(expr, timezone, except_, until, anchor, during)


def _expression(expr: object) -> ScheduleExpr:
    match expr:
        case IntervalRepeat():
            interval = _interval(expr.interval)
            unit = _member(IntervalUnit, "interval unit", expr.unit)
            start, end = _time(expr.from_time), _time(expr.to_time)
            if (start.hour, start.minute) > (end.hour, end.minute):
                raise _error(
                    f"time window must not run backwards: {start} to {end}"
                    " (a window cannot cross midnight)"
                )
            day_filter = None if expr.day_filter is None else _day_filter(expr.day_filter)
            return IntervalRepeat(interval, unit, start, end, day_filter)
        case DayRepeat():
            interval = _interval(expr.interval)
            # `every 2 days` has no place for a day filter, so other days would not survive display.
            if interval > 1 and not isinstance(expr.days, DayFilterEvery):
                raise _error("days must be every day when the interval is above 1")
            return DayRepeat(interval, _day_filter(expr.days), _times(expr.times))
        case WeekRepeat():
            interval = _interval(expr.interval)
            return WeekRepeat(interval, _weekdays(expr.days), _times(expr.times))
        case MonthRepeat():
            interval = _interval(expr.interval)
            return MonthRepeat(interval, _month_target(expr.target), _times(expr.times))
        case SingleDateExpr():
            return SingleDateExpr(_date(expr.date), _times(expr.times))
        case YearRepeat():
            interval = _interval(expr.interval)
            return YearRepeat(interval, _year_target(expr.target), _times(expr.times))
        case _:
            raise _unknown("expression", expr)


def _interval(value: object) -> int:
    interval = _integer("interval", value)
    if not 1 <= interval <= _MAX_INTERVAL:
        raise _error(f"interval must be 1-{_MAX_INTERVAL}, got {interval}")
    return interval


def _times(value: object) -> tuple[TimeOfDay, ...]:
    times = _sequence("times", value)
    if not times:
        raise _error("times must not be empty")
    return tuple(_time(t) for t in times)


def _time(value: object) -> TimeOfDay:
    if not isinstance(value, TimeOfDay):
        raise TypeError(f"a time must be a TimeOfDay, got {type(value).__name__}")
    time = TimeOfDay(_integer("hour", value.hour), _integer("minute", value.minute))
    if not (0 <= time.hour <= 23 and 0 <= time.minute <= 59):
        raise _error(f"time must be 00:00-23:59, got {time}")
    return time


def _day_filter(value: object) -> DayFilter:
    match value:
        case DayFilterEvery():
            return DayFilterEvery()
        case DayFilterWeekday():
            return DayFilterWeekday()
        case DayFilterWeekend():
            return DayFilterWeekend()
        case DayFilterDays():
            return DayFilterDays(_weekdays(value.days))
        case _:
            raise _unknown("day filter", value)


def _weekdays(value: object) -> tuple[Weekday, ...]:
    days = _sequence("days", value)
    if not days:
        raise _error("days must not be empty")
    return tuple(_member(Weekday, "weekday", d) for d in days)


def _month_target(value: object) -> MonthTarget:
    match value:
        case DaysTarget():
            specs = _sequence("specs", value.specs)
            if not specs:
                raise _error("days must not be empty")
            return DaysTarget(tuple(_day_spec(s) for s in specs))
        case LastDayTarget():
            return LastDayTarget()
        case LastWeekdayTarget():
            return LastWeekdayTarget()
        case NearestWeekdayTarget():
            direction = value.direction
            if direction is not None:
                direction = _member(NearestDirection, "direction", direction)
            return NearestWeekdayTarget(_day_of_month(value.day), direction)
        case OrdinalWeekdayTarget():
            ordinal = _member(OrdinalPosition, "ordinal", value.ordinal)
            return OrdinalWeekdayTarget(ordinal, _member(Weekday, "weekday", value.weekday))
        case _:
            raise _unknown("month target", value)


def _day_spec(value: object) -> DayOfMonthSpec:
    match value:
        case SingleDay():
            return SingleDay(_day_of_month(value.day))
        case DayRange():
            start, end = _day_of_month(value.start), _day_of_month(value.end)
            if start > end:
                raise _error(
                    f"day range must not run backwards: {_ordinal(start)} to {_ordinal(end)}"
                )
            return DayRange(start, end)
        case _:
            raise _unknown("day spec", value)


def _year_target(value: object) -> YearTarget:
    match value:
        case YearDateTarget():
            return YearDateTarget(*_named_date(value.month, value.day))
        case YearOrdinalWeekdayTarget():
            ordinal = _member(OrdinalPosition, "ordinal", value.ordinal)
            weekday = _member(Weekday, "weekday", value.weekday)
            return YearOrdinalWeekdayTarget(
                ordinal, weekday, _member(MonthName, "month", value.month)
            )
        case YearDayOfMonthTarget():
            month = _member(MonthName, "month", value.month)
            day = _day_of_month(value.day)
            _check_day_in_month(month, day, _ordinal(day))
            return YearDayOfMonthTarget(day, month)
        case YearLastWeekdayTarget():
            return YearLastWeekdayTarget(_member(MonthName, "month", value.month))
        case _:
            raise _unknown("year target", value)


def _date(value: object) -> DateSpec:
    match value:
        case NamedDate():
            return NamedDate(*_named_date(value.month, value.day))
        case IsoDate():
            return IsoDate(_iso_date(value.date))
        case _:
            raise _unknown("date", value)


def _exception(value: object) -> ExceptionSpec:
    match value:
        case NamedException():
            return NamedException(*_named_date(value.month, value.day))
        case IsoException():
            return IsoException(_iso_date(value.date))
        case _:
            raise _unknown("exception", value)


def _until(value: object) -> UntilSpec:
    match value:
        case NamedUntil():
            return NamedUntil(*_named_date(value.month, value.day))
        case IsoUntil():
            return IsoUntil(_iso_date(value.date))
        case _:
            raise _unknown("until", value)


def _named_date(month_value: object, day_value: object) -> tuple[MonthName, int]:
    month = _member(MonthName, "month", month_value)
    day = _integer("day", day_value)
    if not 1 <= day <= 31:
        raise _error(f"day must be 1-31, got {day}")
    _check_day_in_month(month, day, str(day))
    return month, day


def _day_of_month(value: object) -> int:
    day = _integer("day", value)
    if not 1 <= day <= 31:
        raise _error(f"day must be 1-31, got {_ordinal(day)}")
    return day


def _check_day_in_month(month: MonthName, day: int, as_displayed: str) -> None:
    if day > max_day(month):
        raise _error(f"day must be 1-{max_day(month)} for {month}, got {as_displayed}")


def _iso_date(value: object) -> str:
    text = _string("date", value)
    if not _is_calendar_date(text):
        raise _error(f"date must be a calendar date from 0001-01-01 to 9999-12-31, got {text}")
    return text


def _is_calendar_date(text: str) -> bool:
    """date.fromisoformat alone would also read `20260206` and the week date `2026-W06-5`."""
    shaped = len(text) == 10 and all(
        c == "-" if i in (4, 7) else c in _ASCII_DIGITS for i, c in enumerate(text)
    )
    if not shaped:
        return False
    try:
        date.fromisoformat(text)
    except ValueError:
        return False
    return True


def _timezone(value: object) -> str:
    name = _string("timezone", value)
    canonical = canonical_timezone(name)
    if canonical is None:
        raise _error(
            f"timezone must be UTC or an Area/Location name such as America/New_York, got {name}"
        )
    return canonical


def _member(kind: type[_Member], name: str, value: object) -> _Member:
    if not isinstance(value, kind):
        raise TypeError(f"{name} must be a {kind.__name__}, got {type(value).__name__}")
    return value


def _integer(name: str, value: object) -> int:
    # bool is an int subclass, but True as a day or an interval is a mistake, not a 1.
    if isinstance(value, bool) or not isinstance(value, int):
        raise TypeError(f"{name} must be an int, got {type(value).__name__}")
    return int(value)


def _string(name: str, value: object) -> str:
    if not isinstance(value, str):
        raise TypeError(f"{name} must be a str, got {type(value).__name__}")
    return str(value)


def _sequence(name: str, value: object) -> tuple[object, ...]:
    if not isinstance(value, list | tuple):
        raise TypeError(f"{name} must be a list or tuple, got {type(value).__name__}")
    return tuple(value)


def _ordinal(day: int) -> str:
    return f"{day}{ordinal_suffix(day)}"


def _unknown(kind: str, value: object) -> HronError:
    return HronError.eval(f"unknown {kind} {value!r}")


def _error(message: str) -> HronError:
    return HronError.eval(message)
