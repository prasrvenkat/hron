from __future__ import annotations

from dataclasses import dataclass
from enum import Enum


class Weekday(Enum):
    MONDAY = "monday"
    TUESDAY = "tuesday"
    WEDNESDAY = "wednesday"
    THURSDAY = "thursday"
    FRIDAY = "friday"
    SATURDAY = "saturday"
    SUNDAY = "sunday"

    @property
    def number(self) -> int:
        """ISO 8601 day number: Monday=1, Sunday=7."""
        return _WEEKDAY_NUMBERS[self]

    @property
    def cron_dow(self) -> int:
        """Cron DOW number: Sunday=0, Monday=1, ..., Saturday=6."""
        return _CRON_DOW[self]

    @classmethod
    def from_number(cls, n: int) -> Weekday | None:
        return _NUMBER_TO_WEEKDAY.get(n)

    @classmethod
    def try_parse(cls, s: str) -> Weekday | None:
        return _WEEKDAY_PARSE.get(s.lower())

    def __str__(self) -> str:
        return self.value


_WEEKDAY_NUMBERS = {
    Weekday.MONDAY: 1,
    Weekday.TUESDAY: 2,
    Weekday.WEDNESDAY: 3,
    Weekday.THURSDAY: 4,
    Weekday.FRIDAY: 5,
    Weekday.SATURDAY: 6,
    Weekday.SUNDAY: 7,
}

_CRON_DOW = {
    Weekday.SUNDAY: 0,
    Weekday.MONDAY: 1,
    Weekday.TUESDAY: 2,
    Weekday.WEDNESDAY: 3,
    Weekday.THURSDAY: 4,
    Weekday.FRIDAY: 5,
    Weekday.SATURDAY: 6,
}

_NUMBER_TO_WEEKDAY = {v: k for k, v in _WEEKDAY_NUMBERS.items()}

_WEEKDAY_PARSE: dict[str, Weekday] = {
    "monday": Weekday.MONDAY,
    "mon": Weekday.MONDAY,
    "tuesday": Weekday.TUESDAY,
    "tue": Weekday.TUESDAY,
    "wednesday": Weekday.WEDNESDAY,
    "wed": Weekday.WEDNESDAY,
    "thursday": Weekday.THURSDAY,
    "thu": Weekday.THURSDAY,
    "friday": Weekday.FRIDAY,
    "fri": Weekday.FRIDAY,
    "saturday": Weekday.SATURDAY,
    "sat": Weekday.SATURDAY,
    "sunday": Weekday.SUNDAY,
    "sun": Weekday.SUNDAY,
}


class MonthName(Enum):
    JAN = "jan"
    FEB = "feb"
    MAR = "mar"
    APR = "apr"
    MAY = "may"
    JUN = "jun"
    JUL = "jul"
    AUG = "aug"
    SEP = "sep"
    OCT = "oct"
    NOV = "nov"
    DEC = "dec"

    @property
    def number(self) -> int:
        return _MONTH_NUMBERS[self]

    @classmethod
    def try_parse(cls, s: str) -> MonthName | None:
        return _MONTH_PARSE.get(s.lower())

    def __str__(self) -> str:
        return self.value


_MONTH_NUMBERS = {
    MonthName.JAN: 1,
    MonthName.FEB: 2,
    MonthName.MAR: 3,
    MonthName.APR: 4,
    MonthName.MAY: 5,
    MonthName.JUN: 6,
    MonthName.JUL: 7,
    MonthName.AUG: 8,
    MonthName.SEP: 9,
    MonthName.OCT: 10,
    MonthName.NOV: 11,
    MonthName.DEC: 12,
}

_MONTH_PARSE: dict[str, MonthName] = {
    "january": MonthName.JAN,
    "jan": MonthName.JAN,
    "february": MonthName.FEB,
    "feb": MonthName.FEB,
    "march": MonthName.MAR,
    "mar": MonthName.MAR,
    "april": MonthName.APR,
    "apr": MonthName.APR,
    "may": MonthName.MAY,
    "june": MonthName.JUN,
    "jun": MonthName.JUN,
    "july": MonthName.JUL,
    "jul": MonthName.JUL,
    "august": MonthName.AUG,
    "aug": MonthName.AUG,
    "september": MonthName.SEP,
    "sep": MonthName.SEP,
    "october": MonthName.OCT,
    "oct": MonthName.OCT,
    "november": MonthName.NOV,
    "nov": MonthName.NOV,
    "december": MonthName.DEC,
    "dec": MonthName.DEC,
}


class IntervalUnit(Enum):
    MIN = "min"
    HOURS = "hours"

    def __str__(self) -> str:
        return self.value


class OrdinalPosition(Enum):
    FIRST = "first"
    SECOND = "second"
    THIRD = "third"
    FOURTH = "fourth"
    FIFTH = "fifth"
    LAST = "last"

    def to_n(self) -> int:
        return _ORDINAL_TO_N[self]

    def __str__(self) -> str:
        return self.value


_ORDINAL_TO_N: dict[OrdinalPosition, int] = {
    OrdinalPosition.FIRST: 1,
    OrdinalPosition.SECOND: 2,
    OrdinalPosition.THIRD: 3,
    OrdinalPosition.FOURTH: 4,
    OrdinalPosition.FIFTH: 5,
}


class NearestDirection(Enum):
    """Direction for nearest weekday (hron extension beyond cron W)."""

    NEXT = "next"  # Always prefer following weekday (can cross to next month)
    PREVIOUS = "previous"  # Always prefer preceding weekday (can cross to prev month)

    def __str__(self) -> str:
        return self.value


@dataclass(frozen=True, slots=True)
class TimeOfDay:
    hour: int
    minute: int

    def __str__(self) -> str:
        return f"{self.hour:02d}:{self.minute:02d}"


# --- Day filter ---


@dataclass(frozen=True, slots=True)
class DayFilterEvery:
    pass


@dataclass(frozen=True, slots=True)
class DayFilterWeekday:
    pass


@dataclass(frozen=True, slots=True)
class DayFilterWeekend:
    pass


@dataclass(frozen=True, slots=True)
class DayFilterDays:
    days: tuple[Weekday, ...]


DayFilter = DayFilterEvery | DayFilterWeekday | DayFilterWeekend | DayFilterDays


# --- Day of month spec ---


@dataclass(frozen=True, slots=True)
class SingleDay:
    day: int


@dataclass(frozen=True, slots=True)
class DayRange:
    start: int
    end: int


DayOfMonthSpec = SingleDay | DayRange


# --- Month target ---


@dataclass(frozen=True, slots=True)
class DaysTarget:
    specs: tuple[DayOfMonthSpec, ...]


@dataclass(frozen=True, slots=True)
class LastDayTarget:
    pass


@dataclass(frozen=True, slots=True)
class LastWeekdayTarget:
    pass


@dataclass(frozen=True, slots=True)
class NearestWeekdayTarget:
    """Nearest weekday to a given day of month.

    Standard (direction=None): never crosses month boundary (cron W compatibility).
    Directional (direction=Some): can cross month boundary.
    """

    day: int
    direction: NearestDirection | None = None


MonthTarget = DaysTarget | LastDayTarget | LastWeekdayTarget | NearestWeekdayTarget


# --- Year target ---


@dataclass(frozen=True, slots=True)
class YearDateTarget:
    month: MonthName
    day: int


@dataclass(frozen=True, slots=True)
class YearOrdinalWeekdayTarget:
    ordinal: OrdinalPosition
    weekday: Weekday
    month: MonthName


@dataclass(frozen=True, slots=True)
class YearDayOfMonthTarget:
    day: int
    month: MonthName


@dataclass(frozen=True, slots=True)
class YearLastWeekdayTarget:
    month: MonthName


YearTarget = (
    YearDateTarget | YearOrdinalWeekdayTarget | YearDayOfMonthTarget | YearLastWeekdayTarget
)


# --- Date spec ---


@dataclass(frozen=True, slots=True)
class NamedDate:
    month: MonthName
    day: int


@dataclass(frozen=True, slots=True)
class IsoDate:
    date: str


DateSpec = NamedDate | IsoDate


# --- Exception ---


@dataclass(frozen=True, slots=True)
class NamedException:
    month: MonthName
    day: int


@dataclass(frozen=True, slots=True)
class IsoException:
    date: str


ExceptionSpec = NamedException | IsoException


# --- Until spec ---


@dataclass(frozen=True, slots=True)
class IsoUntil:
    date: str


@dataclass(frozen=True, slots=True)
class NamedUntil:
    month: MonthName
    day: int


UntilSpec = IsoUntil | NamedUntil


# --- Schedule expressions ---


@dataclass(frozen=True, slots=True)
class IntervalRepeat:
    interval: int
    unit: IntervalUnit
    from_time: TimeOfDay
    to_time: TimeOfDay
    day_filter: DayFilter | None


@dataclass(frozen=True, slots=True)
class DayRepeat:
    interval: int
    days: DayFilter
    times: tuple[TimeOfDay, ...]


@dataclass(frozen=True, slots=True)
class WeekRepeat:
    interval: int
    days: tuple[Weekday, ...]
    times: tuple[TimeOfDay, ...]


@dataclass(frozen=True, slots=True)
class MonthRepeat:
    interval: int
    target: MonthTarget
    times: tuple[TimeOfDay, ...]


@dataclass(frozen=True, slots=True)
class OrdinalRepeat:
    interval: int
    ordinal: OrdinalPosition
    day: Weekday
    times: tuple[TimeOfDay, ...]


@dataclass(frozen=True, slots=True)
class SingleDateExpr:
    date: DateSpec
    times: tuple[TimeOfDay, ...]


@dataclass(frozen=True, slots=True)
class YearRepeat:
    interval: int
    target: YearTarget
    times: tuple[TimeOfDay, ...]


ScheduleExpr = (
    IntervalRepeat
    | DayRepeat
    | WeekRepeat
    | MonthRepeat
    | OrdinalRepeat
    | SingleDateExpr
    | YearRepeat
)


# --- Schedule data (top-level) ---


@dataclass(slots=True)
class ScheduleData:
    expr: ScheduleExpr
    timezone: str | None = None
    except_: tuple[ExceptionSpec, ...] = ()
    until: UntilSpec | None = None
    anchor: str | None = None
    during: tuple[MonthName, ...] = ()


def new_schedule_data(expr: ScheduleExpr) -> ScheduleData:
    return ScheduleData(expr=expr)


# --- Helper functions ---


ALL_WEEKDAYS: tuple[Weekday, ...] = (
    Weekday.MONDAY,
    Weekday.TUESDAY,
    Weekday.WEDNESDAY,
    Weekday.THURSDAY,
    Weekday.FRIDAY,
)

ALL_WEEKEND: tuple[Weekday, ...] = (Weekday.SATURDAY, Weekday.SUNDAY)


def expand_day_spec(spec: DayOfMonthSpec) -> list[int]:
    match spec:
        case SingleDay(day=d):
            return [d]
        case DayRange(start=s, end=e):
            return list(range(s, e + 1))


def expand_month_target(target: MonthTarget) -> list[int]:
    match target:
        case DaysTarget(specs=specs):
            result: list[int] = []
            for spec in specs:
                result.extend(expand_day_spec(spec))
            return result
        case _:
            return []
