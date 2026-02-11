from __future__ import annotations

from datetime import datetime

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
    OrdinalPosition,
    OrdinalRepeat,
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
)
from ._cron import from_cron, to_cron
from ._display import display
from ._error import HronError, HronErrorKind, Span
from ._eval import matches as _matches
from ._eval import next_from as _next_from
from ._eval import next_n_from as _next_n_from
from ._parser import parse


class Schedule:
    _data: ScheduleData

    def __init__(self, data: ScheduleData) -> None:
        self._data = data

    @classmethod
    def parse(cls, input_text: str) -> Schedule:
        return cls(parse(input_text))

    @classmethod
    def from_cron(cls, cron_expr: str) -> Schedule:
        return cls(from_cron(cron_expr))

    @classmethod
    def validate(cls, input_text: str) -> bool:
        try:
            parse(input_text)
            return True
        except HronError:
            return False

    def next_from(self, now: datetime) -> datetime | None:
        return _next_from(self._data, now)

    def next_n_from(self, now: datetime, n: int) -> list[datetime]:
        return _next_n_from(self._data, now, n)

    def matches(self, dt: datetime) -> bool:
        return _matches(self._data, dt)

    def to_cron(self) -> str:
        return to_cron(self._data)

    def __str__(self) -> str:
        return display(self._data)

    def __repr__(self) -> str:
        return f"Schedule({display(self._data)!r})"

    @property
    def timezone(self) -> str | None:
        return self._data.timezone

    @property
    def expression(self) -> ScheduleExpr:
        return self._data.expr


__all__ = [
    "Schedule",
    "HronError",
    "HronErrorKind",
    "Span",
    "ScheduleData",
    "ScheduleExpr",
    "TimeOfDay",
    "Weekday",
    "MonthName",
    "IntervalUnit",
    "OrdinalPosition",
    "DayFilter",
    "DayFilterEvery",
    "DayFilterWeekday",
    "DayFilterWeekend",
    "DayFilterDays",
    "DayOfMonthSpec",
    "SingleDay",
    "DayRange",
    "MonthTarget",
    "DaysTarget",
    "LastDayTarget",
    "LastWeekdayTarget",
    "YearTarget",
    "YearDateTarget",
    "YearOrdinalWeekdayTarget",
    "YearDayOfMonthTarget",
    "YearLastWeekdayTarget",
    "DateSpec",
    "NamedDate",
    "IsoDate",
    "ExceptionSpec",
    "NamedException",
    "IsoException",
    "UntilSpec",
    "IsoUntil",
    "NamedUntil",
    "IntervalRepeat",
    "DayRepeat",
    "WeekRepeat",
    "MonthRepeat",
    "OrdinalRepeat",
    "SingleDateExpr",
    "YearRepeat",
]
