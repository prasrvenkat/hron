from __future__ import annotations

from collections.abc import Iterator
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
)
from ._cron import from_cron, to_cron
from ._display import display
from ._error import HronError, HronErrorKind, Span
from ._eval import PreparedSchedule
from ._eval import between as _between
from ._eval import matches as _matches
from ._eval import next_from as _next_from
from ._eval import next_n_from as _next_n_from
from ._eval import occurrences as _occurrences
from ._eval import previous_from as _previous_from
from ._parser import parse


class Schedule:
    _data: ScheduleData
    _prepared: PreparedSchedule

    def __init__(self, data: ScheduleData) -> None:
        self._data = data
        self._prepared = PreparedSchedule(data)

    @classmethod
    def parse(cls, input_text: str) -> Schedule:
        """Raises HronError if `input_text` is not a valid expression."""
        return cls(parse(input_text))

    @classmethod
    def from_cron(cls, cron_expr: str) -> Schedule:
        """Raises HronError for an invalid 5-field cron expression or @ shortcut."""
        return cls(from_cron(cron_expr))

    @classmethod
    def validate(cls, input_text: str) -> bool:
        """False, rather than throwing, for anything `parse` rejects."""
        try:
            parse(input_text)
            return True
        except HronError:
            return False

    def next_from(self, now: datetime) -> datetime | None:
        """Return the first occurrence strictly after `now`, or None if there is none."""
        return _next_from(self._prepared, now)

    def next_n_from(self, now: datetime, n: int) -> list[datetime]:
        """Return up to `n` occurrences after `now`; fewer if the schedule ends."""
        return _next_n_from(self._prepared, now, n)

    def previous_from(self, now: datetime) -> datetime | None:
        """Return the most recent occurrence strictly before `now`, or None if there is none."""
        return _previous_from(self._prepared, now)

    def matches(self, dt: datetime) -> bool:
        """True if `dt`'s minute on the schedule's wall clock is an occurrence; seconds ignored."""
        return _matches(self._prepared, dt)

    def occurrences(self, from_: datetime) -> Iterator[datetime]:
        """Return a lazy iterator of occurrences strictly after `from_`.

        Unbounded for repeating schedules unless an `until` clause ends them.
        """
        return _occurrences(self._prepared, from_)

    def between(self, from_: datetime, to: datetime) -> Iterator[datetime]:
        """Return a lazy iterator of occurrences where `from_ < occurrence <= to`."""
        return _between(self._prepared, from_, to)

    def to_cron(self) -> str:
        """Raises HronError when the schedule has no cron equivalent."""
        return to_cron(self._data)

    def __str__(self) -> str:
        return display(self._data)

    def __repr__(self) -> str:
        return f"Schedule({display(self._data)!r})"

    @property
    def timezone(self) -> str | None:
        """The IANA name in canonical capitalization, or None if unset."""
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
    "OrdinalWeekdayTarget",
    "SingleDateExpr",
    "YearRepeat",
]
