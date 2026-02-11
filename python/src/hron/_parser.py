from __future__ import annotations

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
    TNumber,
    TOf,
    Token,
    TokenKind,
    TOn,
    TOrdinal,
    TOrdinalNumber,
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


class _Parser:
    def __init__(self, tokens: list[Token], input_text: str) -> None:
        self._tokens = tokens
        self._pos = 0
        self._input = input_text

    def peek(self) -> Token | None:
        if self._pos < len(self._tokens):
            return self._tokens[self._pos]
        return None

    def peek_kind(self) -> TokenKind | None:
        tok = self.peek()
        return tok.kind if tok else None

    def advance(self) -> Token | None:
        tok = self.peek()
        if tok:
            self._pos += 1
        return tok

    def current_span(self) -> Span:
        tok = self.peek()
        if tok:
            return tok.span
        if self._tokens:
            last = self._tokens[-1]
            return Span(last.span.end, last.span.end)
        return Span(0, 0)

    def _error(self, message: str, span: Span) -> HronError:
        return HronError.parse(message, span, self._input)

    def _error_at_end(self, message: str) -> HronError:
        if self._tokens:
            end = self._tokens[-1].span.end
            span = Span(end, end)
        else:
            span = Span(0, 0)
        return HronError.parse(message, span, self._input)

    def _consume(self, expected: str, check: type) -> Token:
        span = self.current_span()
        tok = self.peek()
        if tok and isinstance(tok.kind, check):
            self._pos += 1
            return tok
        if tok:
            raise self._error(f"expected {expected}, got {type(tok.kind).__name__}", span)
        raise self._error_at_end(f"expected {expected}")

    # --- Grammar productions ---

    def parse_expression(self) -> ScheduleData:
        span = self.current_span()
        kind = self.peek_kind()

        match kind:
            case TEvery():
                self.advance()
                expr = self._parse_every()
            case TOn():
                self.advance()
                expr = self._parse_on()
            case TOrdinal() | TLast():
                expr = self._parse_ordinal_repeat()
            case _:
                raise self._error(
                    "expected 'every', 'on', or an ordinal (first, second, ...)", span
                )

        return self._parse_trailing_clauses(expr)

    def _parse_trailing_clauses(self, expr: ScheduleExpr) -> ScheduleData:
        schedule = new_schedule_data(expr)

        # except
        if isinstance(self.peek_kind(), TExcept):
            self.advance()
            schedule.except_ = tuple(self._parse_exception_list())

        # until
        if isinstance(self.peek_kind(), TUntil):
            self.advance()
            schedule.until = self._parse_until_spec()

        # starting
        if isinstance(self.peek_kind(), TStarting):
            self.advance()
            k = self.peek_kind()
            if isinstance(k, TIsoDate):
                schedule.anchor = k.date
                self.advance()
            else:
                raise self._error(
                    "expected ISO date (YYYY-MM-DD) after 'starting'", self.current_span()
                )

        # during
        if isinstance(self.peek_kind(), TDuring):
            self.advance()
            schedule.during = tuple(self._parse_month_list())

        # in <timezone>
        if isinstance(self.peek_kind(), TIn):
            self.advance()
            k = self.peek_kind()
            if isinstance(k, TTimezone):
                schedule.timezone = k.tz
                self.advance()
            else:
                raise self._error("expected timezone after 'in'", self.current_span())

        return schedule

    def _parse_exception_list(self) -> list[ExceptionSpec]:
        exceptions: list[ExceptionSpec] = [self._parse_exception()]
        while isinstance(self.peek_kind(), TComma):
            self.advance()
            exceptions.append(self._parse_exception())
        return exceptions

    def _parse_exception(self) -> ExceptionSpec:
        k = self.peek_kind()
        if isinstance(k, TIsoDate):
            self.advance()
            return IsoException(k.date)
        if isinstance(k, TMonthName):
            month = k.name
            self.advance()
            day = self._parse_day_number("expected day number after month name in exception")
            return NamedException(month, day)
        raise self._error("expected ISO date or month-day in exception", self.current_span())

    def _parse_until_spec(self) -> UntilSpec:
        k = self.peek_kind()
        if isinstance(k, TIsoDate):
            self.advance()
            return IsoUntil(k.date)
        if isinstance(k, TMonthName):
            month = k.name
            self.advance()
            day = self._parse_day_number("expected day number after month name in until")
            return NamedUntil(month, day)
        raise self._error("expected ISO date or month-day after 'until'", self.current_span())

    def _parse_day_number(self, error_msg: str) -> int:
        k = self.peek_kind()
        if isinstance(k, TNumber):
            self.advance()
            return k.value
        if isinstance(k, TOrdinalNumber):
            self.advance()
            return k.value
        raise self._error(error_msg, self.current_span())

    # After "every": dispatch
    def _parse_every(self) -> ScheduleExpr:
        if not self.peek():
            raise self._error_at_end("expected repeater")

        k = self.peek_kind()

        match k:
            case TYear():
                self.advance()
                return self._parse_year_repeat(1)
            case TDay():
                return self._parse_day_repeat(1, DayFilterEvery())
            case TWeekday():
                self.advance()
                return self._parse_day_repeat(1, DayFilterWeekday())
            case TWeekend():
                self.advance()
                return self._parse_day_repeat(1, DayFilterWeekend())
            case TDayName():
                days = self._parse_day_list()
                return self._parse_day_repeat(1, DayFilterDays(tuple(days)))
            case TMonth():
                self.advance()
                return self._parse_month_repeat(1)
            case TNumber():
                return self._parse_number_repeat()
            case _:
                raise self._error(
                    "expected day, weekday, weekend, year, day name, month,"
                    " or number after 'every'",
                    self.current_span(),
                )

    def _parse_day_repeat(self, interval: int, days: DayFilter) -> ScheduleExpr:
        if isinstance(days, DayFilterEvery):
            self._consume("'day'", TDay)
        self._consume("'at'", TAt)
        times = self._parse_time_list()
        return DayRepeat(interval, days, tuple(times))

    def _parse_number_repeat(self) -> ScheduleExpr:
        span = self.current_span()
        k = self.peek_kind()
        assert isinstance(k, TNumber)
        num = k.value
        if num == 0:
            raise self._error("interval must be at least 1", span)
        self.advance()

        nk = self.peek_kind()
        match nk:
            case TWeeks():
                self.advance()
                return self._parse_week_repeat(num)
            case TIntervalUnit():
                return self._parse_interval_repeat(num)
            case TDay():
                return self._parse_day_repeat(num, DayFilterEvery())
            case TMonth():
                self.advance()
                return self._parse_month_repeat(num)
            case TYear():
                self.advance()
                return self._parse_year_repeat(num)
            case _:
                raise self._error(
                    "expected 'weeks', 'min', 'minutes', 'hour', 'hours',"
                    " 'day(s)', 'month(s)', or 'year(s)' after number",
                    self.current_span(),
                )

    def _parse_interval_repeat(self, interval: int) -> ScheduleExpr:
        k = self.peek_kind()
        assert isinstance(k, TIntervalUnit)
        unit = k.unit
        self.advance()

        self._consume("'from'", TFrom)
        from_time = self._parse_time()
        self._consume("'to'", TTo)
        to_time = self._parse_time()

        day_filter: DayFilter | None = None
        if isinstance(self.peek_kind(), TOn):
            self.advance()
            day_filter = self._parse_day_target()

        return IntervalRepeat(interval, unit, from_time, to_time, day_filter)

    def _parse_week_repeat(self, interval: int) -> ScheduleExpr:
        self._consume("'on'", TOn)
        days = self._parse_day_list()
        self._consume("'at'", TAt)
        times = self._parse_time_list()
        return WeekRepeat(interval, tuple(days), tuple(times))

    def _parse_month_repeat(self, interval: int) -> ScheduleExpr:
        self._consume("'on'", TOn)
        self._consume("'the'", TThe)

        k = self.peek_kind()

        if isinstance(k, TLast):
            self.advance()
            nk = self.peek_kind()
            if isinstance(nk, TDay):
                self.advance()
                target: MonthTarget = LastDayTarget()
            elif isinstance(nk, TWeekday):
                self.advance()
                target = LastWeekdayTarget()
            else:
                raise self._error("expected 'day' or 'weekday' after 'last'", self.current_span())
        elif isinstance(k, TOrdinalNumber):
            specs = self._parse_ordinal_day_list()
            target = DaysTarget(tuple(specs))
        else:
            raise self._error(
                "expected ordinal day (1st, 15th) or 'last' after 'the'",
                self.current_span(),
            )

        self._consume("'at'", TAt)
        times = self._parse_time_list()
        return MonthRepeat(interval, target, tuple(times))

    def _parse_ordinal_repeat(self) -> ScheduleExpr:
        ordinal = self._parse_ordinal_position()

        k = self.peek_kind()
        if not isinstance(k, TDayName):
            raise self._error("expected day name after ordinal", self.current_span())
        day = k.name
        self.advance()

        self._consume("'of'", TOf)
        self._consume("'every'", TEvery)

        # "of every [N] month(s) at ..."
        interval = 1
        nk = self.peek_kind()
        if isinstance(nk, TNumber):
            interval = nk.value
            if interval == 0:
                raise self._error("interval must be at least 1", self.current_span())
            self.advance()

        self._consume("'month'", TMonth)
        self._consume("'at'", TAt)
        times = self._parse_time_list()

        return OrdinalRepeat(interval, ordinal, day, tuple(times))

    def _parse_year_repeat(self, interval: int) -> ScheduleExpr:
        self._consume("'on'", TOn)

        k = self.peek_kind()

        if isinstance(k, TThe):
            self.advance()
            target = self._parse_year_target_after_the()
        elif isinstance(k, TMonthName):
            month = k.name
            self.advance()
            day = self._parse_day_number("expected day number after month name")
            target = YearDateTarget(month, day)
        else:
            raise self._error(
                "expected month name or 'the' after 'every year on'",
                self.current_span(),
            )

        self._consume("'at'", TAt)
        times = self._parse_time_list()
        return YearRepeat(interval, target, tuple(times))

    def _parse_year_target_after_the(
        self,
    ) -> YearDateTarget | YearOrdinalWeekdayTarget | YearDayOfMonthTarget | YearLastWeekdayTarget:
        k = self.peek_kind()

        if isinstance(k, TLast):
            self.advance()
            nk = self.peek_kind()
            if isinstance(nk, TWeekday):
                self.advance()
                self._consume("'of'", TOf)
                month = self._parse_month_name_token()
                return YearLastWeekdayTarget(month)
            if isinstance(nk, TDayName):
                weekday = nk.name
                self.advance()
                self._consume("'of'", TOf)
                month = self._parse_month_name_token()
                return YearOrdinalWeekdayTarget(OrdinalPosition.LAST, weekday, month)
            raise self._error(
                "expected 'weekday' or day name after 'last' in yearly expression",
                self.current_span(),
            )

        if isinstance(k, TOrdinal):
            ordinal = self._parse_ordinal_position()
            nk = self.peek_kind()
            if isinstance(nk, TDayName):
                weekday = nk.name
                self.advance()
                self._consume("'of'", TOf)
                month = self._parse_month_name_token()
                return YearOrdinalWeekdayTarget(ordinal, weekday, month)
            raise self._error(
                "expected day name after ordinal in yearly expression",
                self.current_span(),
            )

        if isinstance(k, TOrdinalNumber):
            day = k.value
            self.advance()
            self._consume("'of'", TOf)
            month = self._parse_month_name_token()
            return YearDayOfMonthTarget(day, month)

        raise self._error(
            "expected ordinal, day number, or 'last' after 'the' in yearly expression",
            self.current_span(),
        )

    def _parse_month_name_token(self) -> MonthName:
        k = self.peek_kind()
        if isinstance(k, TMonthName):
            self.advance()
            return k.name
        raise self._error("expected month name", self.current_span())

    def _parse_ordinal_position(self) -> OrdinalPosition:
        span = self.current_span()
        k = self.peek_kind()
        if isinstance(k, TOrdinal):
            self.advance()
            return k.name
        if isinstance(k, TLast):
            self.advance()
            return OrdinalPosition.LAST
        raise self._error("expected ordinal (first, second, third, fourth, fifth, last)", span)

    def _parse_on(self) -> ScheduleExpr:
        date = self._parse_date_target()
        self._consume("'at'", TAt)
        times = self._parse_time_list()
        return SingleDateExpr(date, tuple(times))

    def _parse_date_target(self) -> DateSpec:
        k = self.peek_kind()
        if isinstance(k, TIsoDate):
            self.advance()
            return IsoDate(k.date)
        if isinstance(k, TMonthName):
            month = k.name
            self.advance()
            day = self._parse_day_number("expected day number after month name")
            return NamedDate(month, day)
        raise self._error("expected date (ISO date or month name)", self.current_span())

    def _parse_day_target(self) -> DayFilter:
        k = self.peek_kind()
        match k:
            case TDay():
                self.advance()
                return DayFilterEvery()
            case TWeekday():
                self.advance()
                return DayFilterWeekday()
            case TWeekend():
                self.advance()
                return DayFilterWeekend()
            case TDayName():
                days = self._parse_day_list()
                return DayFilterDays(tuple(days))
            case _:
                raise self._error(
                    "expected 'day', 'weekday', 'weekend', or day name",
                    self.current_span(),
                )

    def _parse_day_list(self) -> list[Weekday]:
        k = self.peek_kind()
        if not isinstance(k, TDayName):
            raise self._error("expected day name", self.current_span())
        days: list[Weekday] = [k.name]
        self.advance()

        while isinstance(self.peek_kind(), TComma):
            self.advance()
            nk = self.peek_kind()
            if not isinstance(nk, TDayName):
                raise self._error("expected day name after ','", self.current_span())
            days.append(nk.name)
            self.advance()
        return days

    def _parse_ordinal_day_list(self) -> list[DayOfMonthSpec]:
        specs: list[DayOfMonthSpec] = [self._parse_ordinal_day_spec()]
        while isinstance(self.peek_kind(), TComma):
            self.advance()
            specs.append(self._parse_ordinal_day_spec())
        return specs

    def _parse_ordinal_day_spec(self) -> DayOfMonthSpec:
        k = self.peek_kind()
        if not isinstance(k, TOrdinalNumber):
            raise self._error("expected ordinal day number", self.current_span())
        start = k.value
        self.advance()

        if isinstance(self.peek_kind(), TTo):
            self.advance()
            nk = self.peek_kind()
            if not isinstance(nk, TOrdinalNumber):
                raise self._error("expected ordinal day number after 'to'", self.current_span())
            end = nk.value
            self.advance()
            return DayRange(start, end)

        return SingleDay(start)

    def _parse_month_list(self) -> list[MonthName]:
        months: list[MonthName] = [self._parse_month_name_token()]
        while isinstance(self.peek_kind(), TComma):
            self.advance()
            months.append(self._parse_month_name_token())
        return months

    def _parse_time_list(self) -> list[TimeOfDay]:
        times: list[TimeOfDay] = [self._parse_time()]
        while isinstance(self.peek_kind(), TComma):
            self.advance()
            times.append(self._parse_time())
        return times

    def _parse_time(self) -> TimeOfDay:
        span = self.current_span()
        k = self.peek_kind()
        if isinstance(k, TTime):
            self.advance()
            return TimeOfDay(k.hour, k.minute)
        raise self._error("expected time (HH:MM)", span)


def parse(input_text: str) -> ScheduleData:
    tokens = tokenize(input_text)

    if not tokens:
        raise HronError.parse("empty expression", Span(0, 0), input_text)

    parser = _Parser(tokens, input_text)
    schedule = parser.parse_expression()

    if parser.peek():
        raise HronError.parse(
            "unexpected tokens after expression",
            parser.current_span(),
            input_text,
        )

    return schedule
