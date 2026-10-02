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
)
from ._cron import from_cron as _from_cron
from ._cron import to_cron as _to_cron
from ._display import display as _display
from ._error import HronError, HronErrorKind, Span
from ._eval import PreparedSchedule as _PreparedSchedule
from ._eval import between as _between
from ._eval import matches as _matches
from ._eval import next_from as _next_from
from ._eval import next_n_from as _next_n_from
from ._eval import occurrences as _occurrences
from ._eval import previous_from as _previous_from
from ._parser import parse as _parse
from ._parts import checked as _checked


class Schedule:
    """Evaluation methods take a `datetime`, reading a naive one as host local time, and
    return aware datetimes in the schedule's `ZoneInfo`, or `ZoneInfo("UTC")` when it has
    none. They raise TypeError for a timestamp that is not a `datetime`."""

    _data: ScheduleData
    _prepared: _PreparedSchedule

    def __init__(self, data: ScheduleData) -> None:
        """Build a schedule from its parts, checked with the rules `parse` applies, and copied:
        changing them afterwards does not change the schedule. Raises HronError of kind "eval"
        for a part that breaks a rule, and TypeError for a value of the wrong type, such as a
        str, float or bool for an int or None for a list."""
        self._set(_checked(data))

    def _set(self, data: ScheduleData) -> None:
        self._data = data
        self._prepared = _PreparedSchedule(data)

    @classmethod
    def _of_valid(cls, data: ScheduleData) -> Schedule:
        """For `parse` and `from_cron`, whose parts already keep every rule."""
        schedule = cls.__new__(cls)
        schedule._set(data)
        return schedule

    @classmethod
    def parse(cls, input_text: str) -> Schedule:
        """Raises HronError if `input_text` is not a valid expression, and TypeError if it is not
        a str."""
        if not isinstance(input_text, str):
            raise TypeError(f"input_text must be a str, got {type(input_text).__name__}")
        return cls._of_valid(_parse(input_text))

    @classmethod
    def from_cron(cls, cron_expr: str) -> Schedule:
        """Convert a 5-field cron expression or @ shortcut to a Schedule that fires at the same
        times. Raises HronError of kind "cron" when the input is not valid cron or has no exact
        hron equivalent, and TypeError if it is not a str."""
        if not isinstance(cron_expr, str):
            raise TypeError(f"cron_expr must be a str, got {type(cron_expr).__name__}")
        return cls._of_valid(_from_cron(cron_expr))

    @classmethod
    def validate(cls, input_text: str) -> bool:
        """False, rather than throwing, for anything `parse` rejects. Raises TypeError if
        `input_text` is not a str."""
        if not isinstance(input_text, str):
            raise TypeError(f"input_text must be a str, got {type(input_text).__name__}")
        try:
            _parse(input_text)
            return True
        except HronError:
            return False

    def next_from(self, now: datetime) -> datetime | None:
        """Return the first occurrence strictly after `now`, or None if there is none."""
        return _next_from(self._prepared, now)

    def next_n_from(self, now: datetime, n: int) -> list[datetime]:
        """Return up to `n` occurrences after `now`; fewer if the schedule ends, none if
        `n <= 0`. Raises TypeError if `n` is not an integer."""
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
        """Convert to a 5-field cron expression that fires at the same times. Raises HronError of
        kind "cron" when no cron does. The schedule's timezone is not part of the cron."""
        return _to_cron(self._data)

    def __str__(self) -> str:
        return _display(self._data)

    def __repr__(self) -> str:
        return f"Schedule({_display(self._data)!r})"

    def __eq__(self, other: object) -> bool:
        """Equal when built from equal parts."""
        return isinstance(other, Schedule) and self._data == other._data

    def __hash__(self) -> int:
        return hash(self._data)

    @property
    def timezone(self) -> str | None:
        """The IANA name in canonical capitalization, or None if unset."""
        return self._data.timezone

    @property
    def expression(self) -> ScheduleExpr:
        return self._data.expression

    @property
    def except_(self) -> tuple[ExceptionSpec, ...]:
        """Empty without an except clause."""
        return self._data.except_

    @property
    def until(self) -> UntilSpec | None:
        return self._data.until

    @property
    def starting(self) -> str | None:
        """The starting date as `YYYY-MM-DD`, or None if unset."""
        return self._data.starting

    @property
    def during(self) -> tuple[MonthName, ...]:
        """Empty without a during clause."""
        return self._data.during

    @property
    def data(self) -> ScheduleData:
        """The parts this schedule was built from, to change with `dataclasses.replace` and
        build again."""
        return self._data


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
    "NearestDirection",
    "NearestWeekdayTarget",
    "IntervalRepeat",
    "DayRepeat",
    "WeekRepeat",
    "MonthRepeat",
    "OrdinalWeekdayTarget",
    "SingleDateExpr",
    "YearRepeat",
]
