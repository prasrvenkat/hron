from __future__ import annotations

import datetime
import functools
import zoneinfo

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
    Weekday,
    WeekRepeat,
    YearDateTarget,
    YearDayOfMonthTarget,
    YearLastWeekdayTarget,
    YearOrdinalWeekdayTarget,
    YearRepeat,
    YearTarget,
    new_schedule_data,
)
from ._error import HronError, Span
from ._lexer import (
    TAt,
    TComma,
    TDay,
    TDayName,
    TDuring,
    TEvery,
    TExcept,
    TFrom,
    TIn,
    TIntervalUnit,
    TIsoDate,
    TLast,
    TMonth,
    TMonthName,
    TNearest,
    TNext,
    TNumber,
    TOf,
    Token,
    TOn,
    TOrdinal,
    TOrdinalNumber,
    TPrevious,
    TStarting,
    TThe,
    TTime,
    TTimezone,
    TTo,
    TUntil,
    TWeekday,
    TWeekend,
    TWeeks,
    TYear,
    tokenize,
)


class _Expected:
    """The `{what}` of each `expected {what}, got ...` error, one per phrase in the position
    table of spec/README.md, "Parse errors"."""

    EVERY_OR_ON = "'every' or 'on'"
    REPEATER = "'day', 'weekday', 'weekend', a day name, 'week', 'month', 'year' or a number"
    UNIT = "a unit ('min', 'hours', 'days', 'weeks', 'months' or 'years')"
    AT = "'at'"
    TIME = "a time (HH:MM)"
    FROM = "'from'"
    TO = "'to'"
    DAY_TARGET = "'day', 'weekday', 'weekend' or a day name"
    ON = "'on'"
    DAY_NAME = "a day name"
    THE = "'the'"
    MONTH_TARGET = (
        "a day such as 15th, 'last', an ordinal such as 'first', 'next', 'previous' or 'nearest'"
    )
    MONTH_LAST = "'day', 'weekday' or a day name"
    NEAREST = "'nearest'"
    WEEKDAY = "'weekday'"
    DAY_OF_MONTH = "a day such as 15th"
    YEAR_TARGET = "a month name or 'the'"
    YEAR_THE = "a day such as 15th, 'last' or an ordinal such as 'first'"
    YEAR_LAST = "'weekday' or a day name"
    OF = "'of'"
    MONTH_NAME = "a month name"
    DAY_NUMBER = "a day number"
    DATE = "a date (YYYY-MM-DD, or a month and day)"
    ISO_DATE = "a date (YYYY-MM-DD)"
    TIMEZONE = "a timezone"


_CLAUSE_ORDER: tuple[tuple[type, str], ...] = (
    (TExcept, "except"),
    (TUntil, "until"),
    (TStarting, "starting"),
    (TDuring, "during"),
    (TIn, "in"),
)

_MONTH_LENGTHS = {
    MonthName.FEB: 29,
    MonthName.APR: 30,
    MonthName.JUN: 30,
    MonthName.SEP: 30,
    MonthName.NOV: 30,
}


@functools.cache
def _timezones_by_lowercase_name() -> dict[str, str]:
    names = {
        name.lower(): name
        for name in zoneinfo.available_timezones()
        # System zoneinfo directories that are not IANA names of their own.
        if "/" in name and not name.startswith(("SystemV/", "posix/", "right/"))
    }
    return names | {"utc": "UTC"}


class _Parser:
    def __init__(self, tokens: list[Token], input_text: str) -> None:
        self._tokens = tokens
        self._pos = 0
        self._input = input_text
        self._until_span: Span | None = None

    def peek(self) -> Token | None:
        return self._tokens[self._pos] if self._pos < len(self._tokens) else None

    def _peek_kind(self) -> object:
        token = self.peek()
        return token.kind if token else None

    def _advance(self) -> Token:
        token = self._tokens[self._pos]
        self._pos += 1
        return token

    def _previous(self) -> Token:
        return self._tokens[self._pos - 1]

    def _eat(self, kind: type) -> bool:
        found = isinstance(self._peek_kind(), kind)
        if found:
            self._pos += 1
        return found

    def _expect(self, kind: type, what: str) -> None:
        if not self._eat(kind):
            raise self._expected(what)

    def _text(self, token: Token) -> str:
        return self._input[token.span.start : token.span.end]

    def _error(self, message: str, start: int, end: int) -> HronError:
        # Python strings index code points, so token offsets are already the spec's unit.
        return HronError.parse(message, Span(start, end), self._input)

    def _expected(self, what: str) -> HronError:
        token = self.peek()
        if token is not None:
            message = f"expected {what}, got '{self._text(token)}'"
            return self._error(message, token.span.start, token.span.end)
        end = self._tokens[-1].span.end if self._tokens else 0
        return self._error(f"expected {what}, got end of input", end, end)

    def parse_expression(self) -> ScheduleExpr:
        if self._eat(TEvery):
            return self._parse_every()
        if self._eat(TOn):
            return self._parse_on()
        raise self._expected(_Expected.EVERY_OR_ON)

    def parse_clauses(self, expr: ScheduleExpr) -> ScheduleData:
        schedule = new_schedule_data(expr)

        if self._eat(TExcept):
            schedule.except_ = tuple(self._parse_exception_list())

        if isinstance(self._peek_kind(), TUntil):
            until = self._advance()
            match self._parse_date():
                case IsoDate(date=date):
                    schedule.until = IsoUntil(date)
                case NamedDate(month=month, day=day):
                    schedule.until = NamedUntil(month, day)
            self._until_span = Span(until.span.start, self._previous().span.end)

        if self._eat(TStarting):
            if not isinstance(self._peek_kind(), TIsoDate):
                raise self._expected(_Expected.ISO_DATE)
            schedule.anchor = self._iso_date(self._advance())

        if self._eat(TDuring):
            schedule.during = tuple(self._parse_month_list())

        if self._eat(TIn):
            if not isinstance(self._peek_kind(), TTimezone):
                raise self._expected(_Expected.TIMEZONE)
            schedule.timezone = self._timezone(self._advance())

        return schedule

    def leftover(self, schedule: ScheduleData) -> HronError:
        token = self._tokens[self._pos]
        # Every clause holds at least one item, so a clause was read exactly when its field is set.
        read = [
            bool(schedule.except_),
            schedule.until is not None,
            schedule.anchor is not None,
            bool(schedule.during),
            schedule.timezone is not None,
        ]
        clause = next(
            (i for i, (kind, _) in enumerate(_CLAUSE_ORDER) if isinstance(token.kind, kind)), None
        )
        last_read = max((i for i, was_read in enumerate(read) if was_read), default=None)
        if clause is not None and read[clause]:
            message = f"duplicate '{_CLAUSE_ORDER[clause][1]}' clause"
        elif clause is not None and last_read is not None:
            keyword, last = _CLAUSE_ORDER[clause][1], _CLAUSE_ORDER[last_read][1]
            message = f"'{keyword}' must come before '{last}'"
        else:
            message = f"unexpected '{self._text(token)}' after the schedule"
        return self._error(message, token.span.start, token.span.end)

    def check_named_until(self, schedule: ScheduleData) -> None:
        until = schedule.until
        if isinstance(until, NamedUntil) and schedule.anchor is None and self._until_span:
            month, day = until.month.value, until.day
            raise HronError.parse(
                f"until {month} {day} has no year: add a starting date, or use an ISO date",
                self._until_span,
                self._input,
                suggestion=f"until {month} {day} starting YYYY-MM-DD",
            )

    def _parse_exception_list(self) -> list[ExceptionSpec]:
        exceptions = [self._parse_exception()]
        while self._eat(TComma):
            exceptions.append(self._parse_exception())
        return exceptions

    def _parse_exception(self) -> ExceptionSpec:
        date = self._parse_date()
        if isinstance(date, IsoDate):
            return IsoException(date.date)
        return NamedException(date.month, date.day)

    def _parse_date(self) -> DateSpec:
        kind = self._peek_kind()
        if isinstance(kind, TIsoDate):
            return IsoDate(self._iso_date(self._advance()))
        if isinstance(kind, TMonthName):
            self._advance()
            return NamedDate(kind.name, self._parse_day_of(kind.name))
        raise self._expected(_Expected.DATE)

    def _iso_date(self, token: Token) -> str:
        text = self._text(token)
        try:
            datetime.date.fromisoformat(text)
        except ValueError:
            raise self._error(
                f"date must be a calendar date from 0001-01-01 to 9999-12-31, got {text}",
                token.span.start,
                token.span.end,
            ) from None
        return text

    def _timezone(self, token: Token) -> str:
        """spec/README.md, "Parse-time validation": `UTC` or an IANA Area/Location name in any
        case, stored with the database's capitalization."""
        name = self._text(token)
        # The ASCII check comes first: lowercasing non-ASCII can produce ASCII (Kelvin sign to "k").
        canonical = _timezones_by_lowercase_name().get(name.lower()) if name.isascii() else None
        if canonical is None:
            raise self._error(
                "timezone must be UTC or an Area/Location name such as America/New_York,"
                f" got {name}",
                token.span.start,
                token.span.end,
            )
        return canonical

    def _parse_every(self) -> ScheduleExpr:
        match self._peek_kind():
            case TDay():
                self._advance()
                return self._parse_day_repeat(1, DayFilterEvery())
            case TWeekday():
                self._advance()
                return self._parse_day_repeat(1, DayFilterWeekday())
            case TWeekend():
                self._advance()
                return self._parse_day_repeat(1, DayFilterWeekend())
            case TDayName():
                days = self._parse_day_list()
                return self._parse_day_repeat(1, DayFilterDays(tuple(days)))
            case TWeeks():
                self._advance()
                return self._parse_week_repeat(1)
            case TMonth():
                self._advance()
                return self._parse_month_repeat(1)
            case TYear():
                self._advance()
                return self._parse_year_repeat(1)
            case TNumber(value=interval):
                return self._parse_number_repeat(interval)
            case _:
                raise self._expected(_Expected.REPEATER)

    def _parse_day_repeat(self, interval: int, days: DayFilter) -> ScheduleExpr:
        self._expect(TAt, _Expected.AT)
        return DayRepeat(interval, days, tuple(self._parse_time_list()))

    def _parse_number_repeat(self, interval: int) -> ScheduleExpr:
        number = self._advance()
        if interval == 0:
            raise self._error(
                f"interval must be 1-2147483647, got {self._text(number)}",
                number.span.start,
                number.span.end,
            )

        match self._peek_kind():
            case TWeeks():
                self._advance()
                return self._parse_week_repeat(interval)
            case TIntervalUnit(unit=unit):
                self._advance()
                return self._parse_interval_repeat(interval, unit)
            case TDay():
                self._advance()
                return self._parse_day_repeat(interval, DayFilterEvery())
            case TMonth():
                self._advance()
                return self._parse_month_repeat(interval)
            case TYear():
                self._advance()
                return self._parse_year_repeat(interval)
            case _:
                raise self._expected(_Expected.UNIT)

    def _parse_interval_repeat(self, interval: int, unit: IntervalUnit) -> ScheduleExpr:
        self._expect(TFrom, _Expected.FROM)
        from_time = self._parse_time()
        from_token = self._previous()
        self._expect(TTo, _Expected.TO)
        to_time = self._parse_time()
        to_token = self._previous()
        if (from_time.hour, from_time.minute) > (to_time.hour, to_time.minute):
            raise self._error(
                f"time window must not run backwards: {self._text(from_token)} to"
                f" {self._text(to_token)} (a window cannot cross midnight)",
                from_token.span.start,
                to_token.span.end,
            )

        day_filter = self._parse_day_target() if self._eat(TOn) else None
        return IntervalRepeat(interval, unit, from_time, to_time, day_filter)

    def _parse_week_repeat(self, interval: int) -> ScheduleExpr:
        self._expect(TOn, _Expected.ON)
        days = self._parse_day_list()
        self._expect(TAt, _Expected.AT)
        return WeekRepeat(interval, tuple(days), tuple(self._parse_time_list()))

    def _parse_month_repeat(self, interval: int) -> ScheduleExpr:
        self._expect(TOn, _Expected.ON)
        self._expect(TThe, _Expected.THE)

        target: MonthTarget
        match self._peek_kind():
            case TLast():
                self._advance()
                match self._peek_kind():
                    case TDay():
                        target = LastDayTarget()
                    case TWeekday():
                        target = LastWeekdayTarget()
                    case TDayName(name=weekday):
                        target = OrdinalWeekdayTarget(OrdinalPosition.LAST, weekday)
                    case _:
                        raise self._expected(_Expected.MONTH_LAST)
                self._advance()
            case TOrdinal(name=ordinal):
                self._advance()
                target = OrdinalWeekdayTarget(ordinal, self._parse_day_name())
            case TOrdinalNumber():
                target = DaysTarget(tuple(self._parse_ordinal_day_list()))
            case TNext() | TPrevious() | TNearest():
                target = self._parse_nearest_weekday_target()
            case _:
                raise self._expected(_Expected.MONTH_TARGET)

        self._expect(TAt, _Expected.AT)
        return MonthRepeat(interval, target, tuple(self._parse_time_list()))

    def _parse_nearest_weekday_target(self) -> NearestWeekdayTarget:
        direction: NearestDirection | None = None
        if self._eat(TNext):
            direction = NearestDirection.NEXT
        elif self._eat(TPrevious):
            direction = NearestDirection.PREVIOUS
        self._expect(TNearest, _Expected.NEAREST)
        self._expect(TWeekday, _Expected.WEEKDAY)
        self._expect(TTo, _Expected.TO)
        day, _ = self._parse_ordinal_day()
        return NearestWeekdayTarget(day, direction)

    def _parse_ordinal_day_list(self) -> list[DayOfMonthSpec]:
        specs = [self._parse_ordinal_day_spec()]
        while self._eat(TComma):
            specs.append(self._parse_ordinal_day_spec())
        return specs

    def _parse_ordinal_day_spec(self) -> DayOfMonthSpec:
        start, start_token = self._parse_ordinal_day()
        if not self._eat(TTo):
            return SingleDay(start)
        end, end_token = self._parse_ordinal_day()
        if start > end:
            raise self._error(
                f"day range must not run backwards: {self._text(start_token)} to"
                f" {self._text(end_token)}",
                start_token.span.start,
                end_token.span.end,
            )
        return DayRange(start, end)

    def _parse_ordinal_day(self) -> tuple[int, Token]:
        kind = self._peek_kind()
        if not isinstance(kind, TOrdinalNumber):
            raise self._expected(_Expected.DAY_OF_MONTH)
        token = self._advance()
        return self._day_of_month(kind.value, token), token

    def _parse_day_of(self, month: MonthName) -> int:
        kind = self._peek_kind()
        if not isinstance(kind, TNumber | TOrdinalNumber):
            raise self._expected(_Expected.DAY_NUMBER)
        token = self._advance()
        day = self._day_of_month(kind.value, token)
        self._check_day_in_month(day, token, month)
        return day

    def _day_of_month(self, n: int, token: Token) -> int:
        if not 1 <= n <= 31:
            raise self._error(
                f"day must be 1-31, got {self._text(token)}", token.span.start, token.span.end
            )
        return n

    def _check_day_in_month(self, day: int, token: Token, month: MonthName) -> None:
        length = _MONTH_LENGTHS.get(month, 31)
        if day > length:
            raise self._error(
                f"day must be 1-{length} for {month.value}, got {self._text(token)}",
                token.span.start,
                token.span.end,
            )

    def _parse_year_repeat(self, interval: int) -> ScheduleExpr:
        self._expect(TOn, _Expected.ON)

        target: YearTarget
        match self._peek_kind():
            case TThe():
                self._advance()
                target = self._parse_year_target_after_the()
            case TMonthName(name=month):
                self._advance()
                target = YearDateTarget(month, self._parse_day_of(month))
            case _:
                raise self._expected(_Expected.YEAR_TARGET)

        self._expect(TAt, _Expected.AT)
        return YearRepeat(interval, target, tuple(self._parse_time_list()))

    def _parse_year_target_after_the(self) -> YearTarget:
        match self._peek_kind():
            case TLast():
                self._advance()
                match self._peek_kind():
                    case TWeekday():
                        self._advance()
                        self._expect(TOf, _Expected.OF)
                        return YearLastWeekdayTarget(self._parse_month_name())
                    case TDayName(name=weekday):
                        self._advance()
                        self._expect(TOf, _Expected.OF)
                        month = self._parse_month_name()
                        return YearOrdinalWeekdayTarget(OrdinalPosition.LAST, weekday, month)
                    case _:
                        raise self._expected(_Expected.YEAR_LAST)
            case TOrdinal(name=ordinal):
                self._advance()
                weekday = self._parse_day_name()
                self._expect(TOf, _Expected.OF)
                month = self._parse_month_name()
                return YearOrdinalWeekdayTarget(ordinal, weekday, month)
            case TOrdinalNumber():
                day, day_token = self._parse_ordinal_day()
                self._expect(TOf, _Expected.OF)
                month = self._parse_month_name()
                self._check_day_in_month(day, day_token, month)
                return YearDayOfMonthTarget(day, month)
            case _:
                raise self._expected(_Expected.YEAR_THE)

    def _parse_month_name(self) -> MonthName:
        kind = self._peek_kind()
        if not isinstance(kind, TMonthName):
            raise self._expected(_Expected.MONTH_NAME)
        self._advance()
        return kind.name

    def _parse_month_list(self) -> list[MonthName]:
        months = [self._parse_month_name()]
        while self._eat(TComma):
            months.append(self._parse_month_name())
        return months

    def _parse_on(self) -> ScheduleExpr:
        date = self._parse_date()
        self._expect(TAt, _Expected.AT)
        return SingleDateExpr(date, tuple(self._parse_time_list()))

    def _parse_day_target(self) -> DayFilter:
        match self._peek_kind():
            case TDay():
                self._advance()
                return DayFilterEvery()
            case TWeekday():
                self._advance()
                return DayFilterWeekday()
            case TWeekend():
                self._advance()
                return DayFilterWeekend()
            case TDayName():
                return DayFilterDays(tuple(self._parse_day_list()))
            case _:
                raise self._expected(_Expected.DAY_TARGET)

    def _parse_day_name(self) -> Weekday:
        kind = self._peek_kind()
        if not isinstance(kind, TDayName):
            raise self._expected(_Expected.DAY_NAME)
        self._advance()
        return kind.name

    def _parse_day_list(self) -> list[Weekday]:
        days = [self._parse_day_name()]
        while self._eat(TComma):
            days.append(self._parse_day_name())
        return days

    def _parse_time_list(self) -> list[TimeOfDay]:
        times = [self._parse_time()]
        while self._eat(TComma):
            times.append(self._parse_time())
        return times

    def _parse_time(self) -> TimeOfDay:
        kind = self._peek_kind()
        if not isinstance(kind, TTime):
            raise self._expected(_Expected.TIME)
        self._advance()
        return TimeOfDay(kind.hour, kind.minute)


def parse(input_text: str) -> ScheduleData:
    tokens = tokenize(input_text)
    if not tokens:
        raise HronError.parse("empty expression", Span(0, 0), input_text)

    parser = _Parser(tokens, input_text)
    schedule = parser.parse_clauses(parser.parse_expression())
    if parser.peek() is not None:
        raise parser.leftover(schedule)
    # spec/README.md, "Parse errors": every other error wins over a named until without starting.
    parser.check_named_until(schedule)
    return schedule
