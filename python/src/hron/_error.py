from __future__ import annotations

from dataclasses import dataclass
from typing import Literal


@dataclass(frozen=True, slots=True)
class Span:
    """The part of the input an error points at: `[start, end)` counted in code points, which
    is how Python indexes a `str`, so `error.input[span.start:span.end]` is the spanned text."""

    start: int
    end: int


HronErrorKind = Literal["lex", "parse", "eval", "cron"]

_LINE_BREAKING = str.maketrans("\t\r\n", "   ")


class HronError(Exception):
    kind: HronErrorKind
    message: str
    span: Span | None
    """None unless this is a lex or parse error."""
    input: str | None
    """None unless this is a lex or parse error."""
    suggestion: str | None
    """None unless the parser has a fix to suggest."""

    def __init__(
        self,
        kind: HronErrorKind,
        message: str,
        span: Span | None = None,
        input: str | None = None,
        suggestion: str | None = None,
    ) -> None:
        """Raises TypeError if `message` is not a str, `span` is neither a Span nor None, or
        `input` or `suggestion` is neither a str nor None."""
        if not isinstance(message, str):
            raise TypeError(f"message must be a str, got {type(message).__name__}")
        if not isinstance(span, Span | None):
            raise TypeError(f"span must be a Span or None, got {type(span).__name__}")
        if not isinstance(input, str | None):
            raise TypeError(f"input must be a str or None, got {type(input).__name__}")
        if not isinstance(suggestion, str | None):
            raise TypeError(f"suggestion must be a str or None, got {type(suggestion).__name__}")
        super().__init__(message)
        self.kind = kind
        self.message = message
        self.span = span
        self.input = input
        self.suggestion = suggestion

    @classmethod
    def lex(cls, message: str, span: Span, input: str) -> HronError:
        """Raises TypeError if `message` or `input` is not a str, or `span` is not a Span."""
        if not isinstance(span, Span):
            raise TypeError(f"span must be a Span, got {type(span).__name__}")
        if not isinstance(input, str):
            raise TypeError(f"input must be a str, got {type(input).__name__}")
        return cls("lex", message, span, input)

    @classmethod
    def parse(
        cls,
        message: str,
        span: Span,
        input: str,
        suggestion: str | None = None,
    ) -> HronError:
        """Raises TypeError if `message` or `input` is not a str, `span` is not a Span, or
        `suggestion` is neither a str nor None."""
        if not isinstance(span, Span):
            raise TypeError(f"span must be a Span, got {type(span).__name__}")
        if not isinstance(input, str):
            raise TypeError(f"input must be a str, got {type(input).__name__}")
        return cls("parse", message, span, input, suggestion)

    @classmethod
    def eval(cls, message: str) -> HronError:
        """Raises TypeError if `message` is not a str."""
        return cls("eval", message)

    @classmethod
    def cron(cls, message: str) -> HronError:
        """Raises TypeError if `message` is not a str."""
        return cls("cron", message)

    def display_rich(self) -> str:
        """The message, then for lex and parse errors the input and a line of carets under the
        span, and any suggestion as ` try: "..."`. No trailing newline."""
        if self.span is None or self.input is None:
            return f"error: {self}"
        # A tab, CR or LF would move the input off the line the carets are aligned to.
        shown = self.input.translate(_LINE_BREAKING)
        spaces = " " * self.span.start
        carets = "^" * max(self.span.end - self.span.start, 1)
        out = f"error: {self}\n  {shown}\n  {spaces}{carets}"
        if self.suggestion is not None:
            out += f' try: "{self.suggestion}"'
        return out
