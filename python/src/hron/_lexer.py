from __future__ import annotations

import string
from dataclasses import dataclass

from ._ast import IntervalUnit, MonthName, OrdinalPosition, Weekday
from ._error import HronError, Span


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
    pass


@dataclass(frozen=True, slots=True)
class TComma:
    pass


@dataclass(frozen=True, slots=True)
class TTimezone:
    pass


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
    "first": TOrdinal(OrdinalPosition.FIRST),
    "second": TOrdinal(OrdinalPosition.SECOND),
    "third": TOrdinal(OrdinalPosition.THIRD),
    "fourth": TOrdinal(OrdinalPosition.FOURTH),
    "fifth": TOrdinal(OrdinalPosition.FIFTH),
    "min": TIntervalUnit(IntervalUnit.MIN),
    "mins": TIntervalUnit(IntervalUnit.MIN),
    "minute": TIntervalUnit(IntervalUnit.MIN),
    "minutes": TIntervalUnit(IntervalUnit.MIN),
    "hour": TIntervalUnit(IntervalUnit.HOURS),
    "hours": TIntervalUnit(IntervalUnit.HOURS),
    "hr": TIntervalUnit(IntervalUnit.HOURS),
    "hrs": TIntervalUnit(IntervalUnit.HOURS),
}


_MAX_NUMBER = 2147483647
_ASCII_DIGITS = frozenset(string.digits)
_ASCII_LETTERS = frozenset(string.ascii_letters)
_WORD_CHARS = _ASCII_LETTERS | _ASCII_DIGITS | {"_"}
# Only these four separate tokens; any other whitespace is an unexpected character.
_WHITESPACE = frozenset(" \t\r\n")
_ORDINAL_SUFFIXES = frozenset({"st", "nd", "rd", "th"})


def _ascii_lower(text: str) -> str:
    # str.lower() would also fold non-ASCII letters, such as the Kelvin sign into "k".
    return "".join(chr(ord(c) + 32) if "A" <= c <= "Z" else c for c in text)


def _number_value(digits: str) -> int | None:
    # A digit loop, because int() refuses a run of more than 4300 digits.
    value = 0
    for d in digits:
        value = value * 10 + ord(d) - ord("0")
        if value > _MAX_NUMBER:
            return None
    return value


class _Lexer:
    def __init__(self, input_text: str) -> None:
        self._input = input_text
        self._pos = 0

    def tokenize(self) -> list[Token]:
        tokens: list[Token] = []
        while True:
            self._advance_while(_WHITESPACE)
            if self._pos >= len(self._input):
                return tokens
            start = self._pos
            c = self._input[start]
            if tokens and isinstance(tokens[-1].kind, TIn):
                self._advance_until(_WHITESPACE)
                kind: TokenKind = TTimezone()
            elif c == ",":
                self._pos += 1
                kind = TComma()
            elif c in _ASCII_LETTERS:
                kind = self._word(start)
            elif c in _ASCII_DIGITS:
                kind = self._digits(start)
            else:
                raise self._unexpected_character(c, start)
            tokens.append(Token(kind, Span(start, self._pos)))

    def _advance_while(self, chars: frozenset[str]) -> None:
        while self._pos < len(self._input) and self._input[self._pos] in chars:
            self._pos += 1

    def _advance_until(self, chars: frozenset[str]) -> None:
        while self._pos < len(self._input) and self._input[self._pos] not in chars:
            self._pos += 1

    def _error(self, message: str, start: int) -> HronError:
        return HronError.lex(message, Span(start, self._pos), self._input)

    def _word(self, start: int) -> TokenKind:
        self._advance_while(_WORD_CHARS)
        text = self._input[start : self._pos]
        kind = _KEYWORD_MAP.get(_ascii_lower(text))
        if kind is None:
            raise self._error(f"unknown keyword '{text}'", start)
        return kind

    def _digits(self, start: int) -> TokenKind:
        self._advance_while(_ASCII_DIGITS)
        digits = self._input[start : self._pos]
        if len(digits) == 4 and self._at_iso_date_tail():
            self._pos += len("-MM-DD")
            return TIsoDate()
        if self._input.startswith(":", self._pos):
            return self._time(start)
        value = _number_value(digits)
        if value is None:
            raise self._error("number must be at most 2147483647", start)
        if _ascii_lower(self._input[self._pos : self._pos + 2]) in _ORDINAL_SUFFIXES:
            self._pos += 2
            return TOrdinalNumber(value)
        return TNumber(value)

    def _at_iso_date_tail(self) -> bool:
        tail = self._input[self._pos : self._pos + 6]
        return (
            len(tail) == 6
            and tail[0] == "-"
            and tail[3] == "-"
            and all(c in _ASCII_DIGITS for c in tail[1:3] + tail[4:6])
        )

    def _time(self, start: int) -> TokenKind:
        colon = self._pos
        self._pos += 1
        self._advance_while(_ASCII_DIGITS)
        hour, minute = self._input[start:colon], self._input[colon + 1 : self._pos]
        text = self._input[start : self._pos]
        if len(hour) not in (1, 2) or len(minute) != 2:
            raise self._error(f"time must be H:MM or HH:MM, got {text}", start)
        if int(hour) > 23 or int(minute) > 59:
            raise self._error(f"time must be 00:00-23:59, got {text}", start)
        return TTime(int(hour), int(minute))

    def _unexpected_character(self, c: str, start: int) -> HronError:
        # `'` is excluded because `'''` would not read as a quoted character.
        shown = f"'{c}'" if "!" <= c <= "~" and c != "'" else f"U+{ord(c):04X}"
        return HronError.lex(f"unexpected character {shown}", Span(start, start + 1), self._input)


def tokenize(input_text: str) -> list[Token]:
    return _Lexer(input_text).tokenize()
