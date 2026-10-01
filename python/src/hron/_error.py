from __future__ import annotations

from dataclasses import dataclass
from typing import Literal


@dataclass(frozen=True, slots=True)
class Span:
    """The part of the input an error points at: `[start, end)` counted in code points, which
    is how Python indexes a `str`, so `input_text[span.start:span.end]` is the spanned text."""

    start: int
    end: int


HronErrorKind = Literal["lex", "parse", "eval", "cron"]

_LINE_BREAKING = str.maketrans("\t\r\n", "   ")


class HronError(Exception):
    kind: HronErrorKind
    span: Span | None
    """None unless this is a lex or parse error."""
    input_text: str | None
    """None unless this is a lex or parse error."""
    suggestion: str | None
    """None unless the parser has a fix to suggest."""

    def __init__(
        self,
        kind: HronErrorKind,
        message: str,
        span: Span | None = None,
        input_text: str | None = None,
        suggestion: str | None = None,
    ) -> None:
        super().__init__(message)
        self.kind = kind
        self.span = span
        self.input_text = input_text
        self.suggestion = suggestion

    @classmethod
    def lex(cls, message: str, span: Span, input_text: str) -> HronError:
        return cls("lex", message, span, input_text)

    @classmethod
    def parse(
        cls,
        message: str,
        span: Span,
        input_text: str,
        suggestion: str | None = None,
    ) -> HronError:
        return cls("parse", message, span, input_text, suggestion)

    @classmethod
    def eval(cls, message: str) -> HronError:
        return cls("eval", message)

    @classmethod
    def cron(cls, message: str) -> HronError:
        return cls("cron", message)

    def display_rich(self) -> str:
        """The message, then for lex and parse errors the input and a line of carets under the
        span, and any suggestion as ` try: "..."`. No trailing newline."""
        if self.span is None or self.input_text is None:
            return f"error: {self}"
        # A tab, CR or LF would move the input off the line the carets are aligned to.
        shown = self.input_text.translate(_LINE_BREAKING)
        spaces = " " * self.span.start
        carets = "^" * max(self.span.end - self.span.start, 1)
        out = f"error: {self}\n  {shown}\n  {spaces}{carets}"
        if self.suggestion is not None:
            out += f' try: "{self.suggestion}"'
        return out
