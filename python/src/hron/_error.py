from __future__ import annotations

from dataclasses import dataclass
from typing import Literal


@dataclass(frozen=True, slots=True)
class Span:
    start: int
    end: int


HronErrorKind = Literal["lex", "parse", "eval", "cron"]


class HronError(Exception):
    kind: HronErrorKind
    span: Span | None
    input_text: str | None
    suggestion: str | None

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
        if self.kind in ("lex", "parse") and self.span and self.input_text:
            out = f"error: {self}\n"
            out += f"  {self.input_text}\n"
            padding = " " * (self.span.start + 2)
            underline = "^" * max(self.span.end - self.span.start, 1)
            out += padding + underline
            if self.suggestion:
                out += f' try: "{self.suggestion}"'
            return out
        return f"error: {self}"
