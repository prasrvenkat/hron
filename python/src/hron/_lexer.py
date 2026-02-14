from __future__ import annotations

from dataclasses import dataclass

from ._ast import IntervalUnit, MonthName, OrdinalPosition, Weekday
from ._error import HronError, Span

# --- Token kinds ---


@dataclass(frozen=True, slots=True)
class TEvery:
    pass


@dataclass(frozen=True, slots=True)
class TOn:
    pass


@dataclass(frozen=True, slots=True)
class TAt:
    pass


@dataclass(frozen=True, slots=True)
class TFrom:
    pass


@dataclass(frozen=True, slots=True)
class TTo:
    pass


@dataclass(frozen=True, slots=True)
class TIn:
    pass


@dataclass(frozen=True, slots=True)
class TOf:
    pass


@dataclass(frozen=True, slots=True)
class TThe:
    pass


@dataclass(frozen=True, slots=True)
class TLast:
    pass


@dataclass(frozen=True, slots=True)
class TExcept:
    pass


@dataclass(frozen=True, slots=True)
class TUntil:
    pass


@dataclass(frozen=True, slots=True)
class TStarting:
    pass


@dataclass(frozen=True, slots=True)
class TDuring:
    pass


@dataclass(frozen=True, slots=True)
class TNearest:
    pass


@dataclass(frozen=True, slots=True)
class TNext:
    pass


@dataclass(frozen=True, slots=True)
class TPrevious:
    pass


@dataclass(frozen=True, slots=True)
class TYear:
    pass


@dataclass(frozen=True, slots=True)
class TDay:
    pass


@dataclass(frozen=True, slots=True)
class TWeekday:
    pass


@dataclass(frozen=True, slots=True)
class TWeekend:
    pass


@dataclass(frozen=True, slots=True)
class TWeeks:
    pass


@dataclass(frozen=True, slots=True)
class TMonth:
    pass


@dataclass(frozen=True, slots=True)
class TDayName:
    name: Weekday


@dataclass(frozen=True, slots=True)
class TMonthName:
    name: MonthName


@dataclass(frozen=True, slots=True)
class TOrdinal:
    name: OrdinalPosition


@dataclass(frozen=True, slots=True)
class TIntervalUnit:
    unit: IntervalUnit


@dataclass(frozen=True, slots=True)
class TNumber:
    value: int


@dataclass(frozen=True, slots=True)
class TOrdinalNumber:
    value: int


@dataclass(frozen=True, slots=True)
class TTime:
    hour: int
    minute: int


@dataclass(frozen=True, slots=True)
class TIsoDate:
    date: str


@dataclass(frozen=True, slots=True)
class TComma:
    pass


@dataclass(frozen=True, slots=True)
class TTimezone:
    tz: str


TokenKind = (
    TEvery
    | TOn
    | TAt
    | TFrom
    | TTo
    | TIn
    | TOf
    | TThe
    | TLast
    | TExcept
    | TUntil
    | TStarting
    | TDuring
    | TNearest
    | TNext
    | TPrevious
    | TYear
    | TDay
    | TWeekday
    | TWeekend
    | TWeeks
    | TMonth
    | TDayName
    | TMonthName
    | TOrdinal
    | TIntervalUnit
    | TNumber
    | TOrdinalNumber
    | TTime
    | TIsoDate
    | TComma
    | TTimezone
)


@dataclass(frozen=True, slots=True)
class Token:
    kind: TokenKind
    span: Span


# --- Keyword map ---

_KEYWORD_MAP: dict[str, TokenKind] = {
    "every": TEvery(),
    "on": TOn(),
    "at": TAt(),
    "from": TFrom(),
    "to": TTo(),
    "in": TIn(),
    "of": TOf(),
    "the": TThe(),
    "last": TLast(),
    "except": TExcept(),
    "until": TUntil(),
    "starting": TStarting(),
    "during": TDuring(),
    "nearest": TNearest(),
    "next": TNext(),
    "previous": TPrevious(),
    "year": TYear(),
    "years": TYear(),
    "day": TDay(),
    "days": TDay(),
    "weekday": TWeekday(),
    "weekdays": TWeekday(),
    "weekend": TWeekend(),
    "weekends": TWeekend(),
    "weeks": TWeeks(),
    "week": TWeeks(),
    "month": TMonth(),
    "months": TMonth(),
    # Day names
    "monday": TDayName(Weekday.MONDAY),
    "mon": TDayName(Weekday.MONDAY),
    "tuesday": TDayName(Weekday.TUESDAY),
    "tue": TDayName(Weekday.TUESDAY),
    "wednesday": TDayName(Weekday.WEDNESDAY),
    "wed": TDayName(Weekday.WEDNESDAY),
    "thursday": TDayName(Weekday.THURSDAY),
    "thu": TDayName(Weekday.THURSDAY),
    "friday": TDayName(Weekday.FRIDAY),
    "fri": TDayName(Weekday.FRIDAY),
    "saturday": TDayName(Weekday.SATURDAY),
    "sat": TDayName(Weekday.SATURDAY),
    "sunday": TDayName(Weekday.SUNDAY),
    "sun": TDayName(Weekday.SUNDAY),
    # Month names
    "january": TMonthName(MonthName.JAN),
    "jan": TMonthName(MonthName.JAN),
    "february": TMonthName(MonthName.FEB),
    "feb": TMonthName(MonthName.FEB),
    "march": TMonthName(MonthName.MAR),
    "mar": TMonthName(MonthName.MAR),
    "april": TMonthName(MonthName.APR),
    "apr": TMonthName(MonthName.APR),
    "may": TMonthName(MonthName.MAY),
    "june": TMonthName(MonthName.JUN),
    "jun": TMonthName(MonthName.JUN),
    "july": TMonthName(MonthName.JUL),
    "jul": TMonthName(MonthName.JUL),
    "august": TMonthName(MonthName.AUG),
    "aug": TMonthName(MonthName.AUG),
    "september": TMonthName(MonthName.SEP),
    "sep": TMonthName(MonthName.SEP),
    "october": TMonthName(MonthName.OCT),
    "oct": TMonthName(MonthName.OCT),
    "november": TMonthName(MonthName.NOV),
    "nov": TMonthName(MonthName.NOV),
    "december": TMonthName(MonthName.DEC),
    "dec": TMonthName(MonthName.DEC),
    # Ordinals
    "first": TOrdinal(OrdinalPosition.FIRST),
    "second": TOrdinal(OrdinalPosition.SECOND),
    "third": TOrdinal(OrdinalPosition.THIRD),
    "fourth": TOrdinal(OrdinalPosition.FOURTH),
    "fifth": TOrdinal(OrdinalPosition.FIFTH),
    # Interval units
    "min": TIntervalUnit(IntervalUnit.MIN),
    "mins": TIntervalUnit(IntervalUnit.MIN),
    "minute": TIntervalUnit(IntervalUnit.MIN),
    "minutes": TIntervalUnit(IntervalUnit.MIN),
    "hour": TIntervalUnit(IntervalUnit.HOURS),
    "hours": TIntervalUnit(IntervalUnit.HOURS),
    "hr": TIntervalUnit(IntervalUnit.HOURS),
    "hrs": TIntervalUnit(IntervalUnit.HOURS),
}


class _Lexer:
    def __init__(self, input_text: str) -> None:
        self._input = input_text
        self._pos = 0
        self._after_in = False

    def tokenize(self) -> list[Token]:
        tokens: list[Token] = []
        while True:
            self._skip_whitespace()
            if self._pos >= len(self._input):
                break

            if self._after_in:
                self._after_in = False
                tokens.append(self._lex_timezone())
                continue

            start = self._pos
            ch = self._input[self._pos]

            if ch == ",":
                self._pos += 1
                tokens.append(Token(TComma(), Span(start, self._pos)))
                continue

            if ch.isdigit():
                tokens.append(self._lex_number_or_time_or_date())
                continue

            if ch.isalpha():
                tokens.append(self._lex_word())
                continue

            raise HronError.lex(
                f"unexpected character '{ch}'",
                Span(start, start + 1),
                self._input,
            )

        return tokens

    def _skip_whitespace(self) -> None:
        while self._pos < len(self._input) and self._input[self._pos] in " \t\n\r":
            self._pos += 1

    def _lex_timezone(self) -> Token:
        self._skip_whitespace()
        start = self._pos
        while self._pos < len(self._input) and self._input[self._pos] not in " \t\n\r":
            self._pos += 1
        tz = self._input[start : self._pos]
        if len(tz) == 0:
            raise HronError.lex(
                "expected timezone after 'in'",
                Span(start, start + 1),
                self._input,
            )
        return Token(TTimezone(tz), Span(start, self._pos))

    def _lex_number_or_time_or_date(self) -> Token:
        start = self._pos
        num_start = self._pos
        while self._pos < len(self._input) and self._input[self._pos].isdigit():
            self._pos += 1
        digits = self._input[num_start : self._pos]

        # Check for ISO date: YYYY-MM-DD
        if len(digits) == 4 and self._pos < len(self._input) and self._input[self._pos] == "-":
            remaining = self._input[start:]
            if (
                len(remaining) >= 10
                and remaining[4] == "-"
                and remaining[5].isdigit()
                and remaining[6].isdigit()
                and remaining[7] == "-"
                and remaining[8].isdigit()
                and remaining[9].isdigit()
            ):
                self._pos = start + 10
                return Token(TIsoDate(self._input[start : self._pos]), Span(start, self._pos))

        # Check for time: HH:MM
        if len(digits) in (1, 2) and self._pos < len(self._input) and self._input[self._pos] == ":":
            self._pos += 1  # skip ':'
            min_start = self._pos
            while self._pos < len(self._input) and self._input[self._pos].isdigit():
                self._pos += 1
            min_digits = self._input[min_start : self._pos]
            if len(min_digits) == 2:
                hour = int(digits)
                minute = int(min_digits)
                if hour > 23 or minute > 59:
                    raise HronError.lex("invalid time", Span(start, self._pos), self._input)
                return Token(TTime(hour, minute), Span(start, self._pos))

        num = int(digits)

        # Check for ordinal suffix: st, nd, rd, th
        if self._pos + 1 < len(self._input):
            suffix = self._input[self._pos : self._pos + 2].lower()
            if suffix in ("st", "nd", "rd", "th"):
                self._pos += 2
                return Token(TOrdinalNumber(num), Span(start, self._pos))

        return Token(TNumber(num), Span(start, self._pos))

    def _lex_word(self) -> Token:
        start = self._pos
        while self._pos < len(self._input) and (
            self._input[self._pos].isalnum() or self._input[self._pos] == "_"
        ):
            self._pos += 1
        word = self._input[start : self._pos].lower()
        span = Span(start, self._pos)

        kind = _KEYWORD_MAP.get(word)
        if kind is None:
            raise HronError.lex(f"unknown keyword '{word}'", span, self._input)

        if isinstance(kind, TIn):
            self._after_in = True

        return Token(kind, span)


def tokenize(input_text: str) -> list[Token]:
    return _Lexer(input_text).tokenize()
