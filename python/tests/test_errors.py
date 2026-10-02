from __future__ import annotations

from collections.abc import Callable

import pytest

from hron import HronError, Schedule, Span


def parse_error(text: str) -> HronError:
    with pytest.raises(HronError) as raised:
        Schedule.parse(text)
    return raised.value


def test_lone_surrogate_is_one_code_point_reported_by_its_own_value() -> None:
    error = parse_error("every \ud800 day")
    assert (error.kind, str(error), error.span) == (
        "lex",
        "unexpected character U+D800",
        Span(6, 7),
    )


def test_span_after_a_lone_surrogate_counts_it_as_one_code_point() -> None:
    error = parse_error("every day at 09:00 in \ud800 junk")
    assert (str(error), error.span) == ("unknown keyword 'junk'", Span(24, 28))


@pytest.mark.parametrize(
    "text,message,span",
    [
        ("every \u0669 days at 09:00", "unexpected character U+0669", Span(6, 7)),
        ("every \u00b2 days at 09:00", "unexpected character U+00B2", Span(6, 7)),
        ("every 1\uff19 days at 09:00", "unexpected character U+FF19", Span(7, 8)),
        ("every day at 09:\u0669\u0669", "time must be H:MM or HH:MM, got 09:", Span(13, 16)),
    ],
    ids=["arabic_indic_nine", "superscript_two", "fullwidth_nine_after_a_digit", "in_a_time"],
)
def test_unicode_digit_is_never_read_as_a_digit(text: str, message: str, span: Span) -> None:
    error = parse_error(text)
    assert (error.kind, str(error), error.span) == ("lex", message, span)


def test_eval_and_cron_errors_render_their_message_alone() -> None:
    assert HronError.eval("no zone").display_rich() == "error: no zone"
    assert HronError.cron("bad cron").display_rich() == "error: bad cron"


_SPAN = Span(0, 5)
_BAD_ARGUMENTS: dict[str, tuple[Callable[..., HronError], tuple[object, ...], str]] = {
    "lex_message": (HronError.lex, (None, _SPAN, "every"), "message must be a str, got NoneType"),
    "lex_input": (HronError.lex, ("m", _SPAN, None), "input must be a str, got NoneType"),
    "lex_span": (HronError.lex, ("m", None, "every"), "span must be a Span, got NoneType"),
    "parse_message": (HronError.parse, (b"m", _SPAN, "every"), "message must be a str, got bytes"),
    "parse_input": (HronError.parse, ("m", _SPAN, 0), "input must be a str, got int"),
    "parse_span": (HronError.parse, ("m", None, "every"), "span must be a Span, got NoneType"),
    "parse_suggestion": (
        HronError.parse,
        ("m", _SPAN, "every", 0),
        "suggestion must be a str or None, got int",
    ),
    "eval_message": (HronError.eval, (None,), "message must be a str, got NoneType"),
    "cron_message": (HronError.cron, (0,), "message must be a str, got int"),
    "init_message": (HronError, ("eval", None), "message must be a str, got NoneType"),
    "init_span": (
        HronError,
        ("lex", "m", (0, 5), "every"),
        "span must be a Span or None, got tuple",
    ),
    "init_input": (
        HronError,
        ("lex", "m", _SPAN, b"every"),
        "input must be a str or None, got bytes",
    ),
    "init_suggestion": (
        HronError,
        ("parse", "m", _SPAN, "every", b"day"),
        "suggestion must be a str or None, got bytes",
    ),
}


@pytest.mark.parametrize(
    "build,arguments,message", _BAD_ARGUMENTS.values(), ids=_BAD_ARGUMENTS.keys()
)
def test_an_error_built_with_an_argument_of_the_wrong_type_is_a_type_error(
    build: Callable[..., HronError], arguments: tuple[object, ...], message: str
) -> None:
    with pytest.raises(TypeError, match=f"^{message}$"):
        build(*arguments)
