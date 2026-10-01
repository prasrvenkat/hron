from __future__ import annotations

import datetime
import json
import random
import re
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

from hron import HronError, Schedule, Span

INPUTS = 6000
SEED = 0x5EED_4A0E

WHAT = "|".join(
    [
        r"'every' or 'on'",
        r"'day', 'weekday', 'weekend', a day name, 'week', 'month', 'year' or a number",
        r"a unit \('min', 'hours', 'days', 'weeks', 'months' or 'years'\)",
        r"'at'|a time \(HH:MM\)|'from'|'to'",
        r"'day', 'weekday', 'weekend' or a day name",
        r"'on'|a day name|'the'",
        r"a day such as 15th, 'last', an ordinal such as 'first', 'next', 'previous' or 'nearest'",
        r"'day', 'weekday' or a day name",
        r"'nearest'|'weekday'|a day such as 15th",
        r"a month name or 'the'",
        r"a day such as 15th, 'last' or an ordinal such as 'first'",
        r"'weekday' or a day name",
        r"'of'|a month name|a day number",
        r"a date \(YYYY-MM-DD, or a month and day\)|a date \(YYYY-MM-DD\)|a timezone",
    ]
)
MONTH = "jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec"
DAY = r"[0-9]+(?i:st|nd|rd|th)?"
TIME = r"[0-9]{1,2}:[0-9]{2}"

CLAUSE_ORDER = ["except", "until", "starting", "during", "in"]
TOKEN_SEPARATORS = " \t\r\n"
ASCII_DIGITS = "0123456789"
SATURATED = 2**64 - 1


@dataclass(frozen=True)
class Failure:
    input: str
    span: Span
    spanned: str


Check = Callable[[re.Match[str], Failure], str | None]


@dataclass(frozen=True)
class Template:
    kind: str
    regex: re.Pattern[str]
    check: Check


def value(text: str) -> int:
    """Saturates, since a digit run can be thousands of digits long."""
    n = 0
    for c in text:
        if c not in ASCII_DIGITS:
            break
        n = min(n * 10 + ord(c) - ord("0"), SATURATED)
    return n


def ascii_lower(text: str) -> str:
    return "".join(chr(ord(c) + 32) if "A" <= c <= "Z" else c for c in text)


def group(match: re.Match[str], name: str) -> str:
    return match.group(name) or ""


def no_check(_: re.Match[str], __: Failure) -> str | None:
    return None


def unexpected_quoted(_: re.Match[str], f: Failure) -> str | None:
    c = f.spanned[:1] or " "
    if (c.isascii() and c.isalnum()) or c == ",":
        return f"'{c}' starts a token, so it is never unexpected"
    return None


def unexpected_code(m: re.Match[str], f: Failure) -> str | None:
    shown = int(group(m, "code"), 16)
    quotable = 0x21 <= shown <= 0x7E and shown != 0x27
    if len(f.spanned) != 1 or ord(f.spanned) != shown or quotable:
        return f"U+{group(m, 'code')} does not describe {f.spanned!r}"
    return None


def time_shape(m: re.Match[str], _: Failure) -> str | None:
    hour, minute = group(m, "hour"), group(m, "minute")
    if len(hour) in (1, 2) and len(minute) == 2:
        return f"{hour}:{minute} is H:MM or HH:MM"
    return None


def time_range(m: re.Match[str], _: Failure) -> str | None:
    hour, minute = value(group(m, "hour")), value(group(m, "minute"))
    if hour <= 23 and minute <= 59:
        return f"{hour}:{minute} is in range"
    return None


def number_too_large(_: re.Match[str], f: Failure) -> str | None:
    digits = f.spanned != "" and all(c in ASCII_DIGITS for c in f.spanned)
    if not (digits and value(f.spanned) > 2147483647):
        return f"{f.spanned!r} is not digits above 2147483647"
    return None


def empty(_: re.Match[str], f: Failure) -> str | None:
    if f.input.strip(TOKEN_SEPARATORS) or f.span != Span(0, 0):
        return f"empty expression with span {f.span} for {f.input!r}"
    return None


def expected_at_end(m: re.Match[str], f: Failure) -> str | None:
    if m.group("end") is None:
        return None
    end = len(f.input.rstrip(TOKEN_SEPARATORS))
    if f.span != Span(end, end):
        return f"end of input at {f.span}, expected {end}..{end}"
    return None


def zero_interval(_: re.Match[str], f: Failure) -> str | None:
    return None if value(f.spanned) == 0 else f"interval {f.spanned} is valid"


def day_out_of_range(_: re.Match[str], f: Failure) -> str | None:
    day = value(f.spanned)
    return None if day == 0 or day > 31 else f"day {day} is within 1-31"


def day_beyond_month(m: re.Match[str], f: Failure) -> str | None:
    month = group(m, "month")
    length = {"feb": 29, "apr": 30, "jun": 30, "sep": 30, "nov": 30}.get(month, 31)
    maximum, day = value(group(m, "max")), value(f.spanned)
    if maximum == length and maximum < day <= 31:
        return None
    return f"day {day} against 1-{maximum} for {month}"


def backwards_days(m: re.Match[str], f: Failure) -> str | None:
    a, b = group(m, "a"), group(m, "b")
    spans_both = f.spanned.startswith(a) and f.spanned.endswith(b)
    if spans_both and value(a) > value(b):
        return None
    return f"{a} to {b} against the span {f.spanned!r}"


def backwards_window(m: re.Match[str], f: Failure) -> str | None:
    start, end = group(m, "from"), group(m, "to")

    def minutes(time: str) -> int:
        hour, minute = time.split(":")
        return value(hour) * 60 + value(minute)

    spans_both = f.spanned.startswith(start) and f.spanned.endswith(end)
    if spans_both and minutes(start) > minutes(end):
        return None
    return f"{start} to {end} against the span {f.spanned!r}"


def not_a_calendar_date(_: re.Match[str], f: Failure) -> str | None:
    try:
        datetime.date.fromisoformat(f.spanned)
    except ValueError:
        return None
    return f"{f.spanned} is a calendar date"


def duplicate_clause(m: re.Match[str], f: Failure) -> str | None:
    if group(m, "keyword") == ascii_lower(f.spanned):
        return None
    return f"duplicate '{group(m, 'keyword')}' but the span holds {f.spanned!r}"


def clause_order(m: re.Match[str], f: Failure) -> str | None:
    keyword, last = group(m, "keyword"), group(m, "last")
    earlier = (
        keyword in CLAUSE_ORDER
        and last in CLAUSE_ORDER
        and CLAUSE_ORDER.index(keyword) < CLAUSE_ORDER.index(last)
    )
    if earlier and keyword == ascii_lower(f.spanned):
        return None
    return f"'{keyword}' before '{last}' with the span {f.spanned!r}"


def named_until(m: re.Match[str], f: Failure) -> str | None:
    words = [w for w in re.split(r"[ \t\r\n]", f.spanned) if w]
    ends_at_day = not f.spanned.endswith(tuple(TOKEN_SEPARATORS))
    matches_message = (
        ends_at_day
        and len(words) == 3
        and ascii_lower(words[0]) == "until"
        and ascii_lower(words[1]).startswith(group(m, "month"))
        and words[2][:1] in tuple(ASCII_DIGITS)
        and str(value(words[2])) == group(m, "day")
    )
    if matches_message:
        return None
    return f"the span {f.spanned!r} is not 'until {group(m, 'month')} {group(m, 'day')}'"


def template(kind: str, pattern: str, check: Check) -> Template:
    # re.ASCII keeps (?i:...) from folding the long s into "s", which would let the ordinal
    # suffix pattern accept "\u017ft".
    return Template(kind, re.compile(pattern, re.ASCII), check)


# From spec/README.md, "Lex errors" and "Parse errors". A `span` group must equal the spanned
# text; every other group is read by its template's check.
TEMPLATES = [
    template("lex", r"unexpected character '(?P<span>[!-&(-~])'", unexpected_quoted),
    template("lex", r"unexpected character U\+(?P<code>[0-9A-F]{4,})", unexpected_code),
    template("lex", r"unknown keyword '(?P<span>[A-Za-z][A-Za-z0-9_]*)'", no_check),
    template(
        "lex",
        r"time must be H:MM or HH:MM, got (?P<span>(?P<hour>[0-9]+):(?P<minute>[0-9]*))",
        time_shape,
    ),
    template(
        "lex",
        r"time must be 00:00-23:59, got (?P<span>(?P<hour>[0-9]{1,2}):(?P<minute>[0-9]{2}))",
        time_range,
    ),
    template("lex", r"number must be at most 2147483647", number_too_large),
    template("parse", r"empty expression", empty),
    template(
        "parse",
        rf"expected (?:{WHAT}), got (?:'(?P<span>.+)'|(?P<end>end of input))",
        expected_at_end,
    ),
    template("parse", r"interval must be 1-2147483647, got (?P<span>[0-9]+)", zero_interval),
    template("parse", rf"day must be 1-31, got (?P<span>{DAY})", day_out_of_range),
    template(
        "parse",
        rf"day must be 1-(?P<max>[0-9]+) for (?P<month>{MONTH}), got (?P<span>{DAY})",
        day_beyond_month,
    ),
    template(
        "parse",
        rf"day range must not run backwards: (?P<a>{DAY}) to (?P<b>{DAY})",
        backwards_days,
    ),
    template(
        "parse",
        rf"time window must not run backwards: (?P<from>{TIME}) to (?P<to>{TIME})"
        r" \(a window cannot cross midnight\)",
        backwards_window,
    ),
    template(
        "parse",
        r"date must be a calendar date from 0001-01-01 to 9999-12-31,"
        r" got (?P<span>[0-9]{4}-[0-9]{2}-[0-9]{2})",
        not_a_calendar_date,
    ),
    template(
        "parse",
        r"timezone must be UTC or an Area/Location name such as America/New_York,"
        r" got (?P<span>.+)",
        no_check,
    ),
    template(
        "parse",
        r"duplicate '(?P<keyword>except|until|starting|during|in)' clause",
        duplicate_clause,
    ),
    template("parse", r"'(?P<keyword>[a-z]+)' must come before '(?P<last>[a-z]+)'", clause_order),
    template("parse", r"unexpected '(?P<span>.+)' after the schedule", no_check),
    template(
        "parse",
        rf"until (?P<month>{MONTH}) (?P<day>[1-9][0-9]?) has no year:"
        r" add a starting date, or use an ISO date",
        named_until,
    ),
]

FRAGMENTS = [
    "every",
    "on",
    "at",
    "from",
    "to",
    "in",
    "IN",
    "of",
    "the",
    "last",
    "except",
    "until",
    "starting",
    "during",
    "nearest",
    "next",
    "previous",
    "day",
    "Days",
    "weekdays",
    "weekend",
    "week",
    "month",
    "years",
    "min",
    "hrs",
    "monday",
    "FRI",
    "jan",
    "february",
    "first",
    "fifth",
    "0",
    "1",
    "00",
    "15th",
    "31ST",
    "2nd",
    "2147483647",
    "2147483648",
    "99999999999999999999",
    "09:00",
    "9:5",
    "24:00",
    "9:",
    "17:30",
    "2026-02-28",
    "2026-02-30",
    "0000-01-01",
    "12026-03-15",
    ",",
    ":",
    "-",
    "/",
    "'",
    '"',
    "#",
    "~",
    "_",
    "UTC",
    "America/New_York",
    "Nope/Zone",
    "Europe/\u0130stanbul",
    "\u00e9",
    "e\u0301",
    "\u212a",
    "\u017ft",
    "\u00a0",
    "\u2028",
    "\ufeff",
    "\uff10",
    "\u0669",
    "\u00b2",
    "\U0001f600",
    "\U0010ffff",
    "\U0001d7d8",
    "\ud800",
    "\0",
    "\x0b",
    "\x0c",
    "\x7f",
    "\x1b",
]
SEPARATORS = ["", " ", " ", " ", "  ", "\t", "\r\n", "\n"]
CLAUSES = [
    "except dec 25",
    "except 2026-12-25, jan 1",
    "until 2027-12-31",
    "until dec 31",
    "starting 2026-01-01",
    "during jan, jul",
    "in UTC",
    "IN America/New_York",
]


def corpus() -> list[str]:
    spec = json.loads((Path(__file__).parents[2] / "spec" / "tests.json").read_text())
    parse_cases = [
        case
        for name, section in spec["parse"].items()
        if name != "description"
        for case in section["tests"]
    ]
    return [case["input"] for case in parse_cases + spec["parse_errors"]["tests"]]


def random_text(rng: random.Random) -> str:
    return "".join(
        rng.choice(SEPARATORS) + rng.choice(FRAGMENTS) for _ in range(rng.randrange(12) + 1)
    )


def mutate(rng: random.Random, text: str) -> str:
    words = text.split(" ")
    i = rng.randrange(len(words))
    match rng.randrange(7):
        case 0:
            del words[i]
        case 1:
            j = rng.randrange(len(words))
            words[i], words[j] = words[j], words[i]
        case 2:
            words.insert(rng.randrange(len(words) + 1), words[i])
        case 3:
            return text[: rng.randrange(len(text) + 1)]
        case 4:
            words[i] = "".join(chr(ord(c) - 32) if "a" <= c <= "z" else c for c in words[i])
        case 5:
            words[i] = rng.choice(FRAGMENTS)
        case _:
            at = rng.randrange(len(words[i]) + 1)
            words[i] = words[i][:at] + rng.choice(FRAGMENTS) + words[i][at:]
    return " ".join(words)


def with_clauses(rng: random.Random, text: str) -> str:
    return text + "".join(" " + rng.choice(CLAUSES) for _ in range(rng.randrange(4) + 1))


def generate(rng: random.Random, inputs: list[str]) -> str:
    match rng.randrange(4):
        case 0:
            return random_text(rng)
        case 1:
            return with_clauses(rng, rng.choice(inputs))
        case _:
            text = rng.choice(inputs)
            for _ in range(rng.randrange(4)):
                text = mutate(rng, text)
            return text


def matching_template_index(text: str, error: HronError) -> int:
    message = str(error)
    assert error.kind in ("lex", "parse"), f"neither lex nor parse: {error.kind}"
    assert not Schedule.validate(text), "validate is true"
    assert error.input_text == text, f"error input is {error.input_text!r}"
    span = error.span
    assert span is not None, "no span"
    assert 0 <= span.start <= span.end <= len(text), f"span {span} outside 0..={len(text)}"
    failure = Failure(text, span, text[span.start : span.end])

    found = next(
        (
            (i, m)
            for i, t in enumerate(TEMPLATES)
            if t.kind == error.kind and (m := t.regex.fullmatch(message))
        ),
        None,
    )
    assert found is not None, f"{error.kind} message {message!r} matches no template"
    index, m = found
    if "span" in m.re.groupindex and m.group("span") is not None:
        echoed = m.group("span")
        assert echoed == failure.spanned, (
            f"message echoes {echoed!r} but the span holds {failure.spanned!r}"
        )
    problem = TEMPLATES[index].check(m, failure)
    assert problem is None, problem

    expected_suggestion = (
        f"until {group(m, 'month')} {group(m, 'day')} starting YYYY-MM-DD"
        if message.startswith("until ")
        else None
    )
    assert error.suggestion == expected_suggestion, (
        f"suggestion {error.suggestion!r}, expected {expected_suggestion!r}"
    )

    rich = error.display_rich()
    assert len(rich.split("\n")) == 3 and rich.startswith(f"error: {message}\n"), (
        f"displayRich is not three lines: {rich!r}"
    )
    return index


def test_generated_inputs_fail_only_with_spec_errors() -> None:
    inputs = corpus()
    rng = random.Random(SEED)
    hits = [0] * len(TEMPLATES)
    parsed = 0
    failures: list[str] = []

    for _ in range(INPUTS):
        text = generate(rng, inputs)
        try:
            Schedule.parse(text)
            parsed += 1
        except HronError as error:
            try:
                hits[matching_template_index(text, error)] += 1
            except AssertionError as problem:
                failures.append(f"{text!r}: {problem}")
        except Exception as error:
            failures.append(f"{text!r}: parse raised {error!r}")

    assert not failures, f"{len(failures)} failures, first ones:\n" + "\n".join(failures[:20])
    assert parsed > INPUTS // 20, f"only {parsed} inputs parsed; the generator has drifted"
    unused = [t.regex.pattern for t, count in zip(TEMPLATES, hits, strict=True) if count == 0]
    assert not unused, f"templates no input produced: {unused}"
