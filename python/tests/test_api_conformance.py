from __future__ import annotations

import copy
import inspect
import json
import re
from collections.abc import Callable
from pathlib import Path
from typing import Any, get_args

import pytest

from hron import (
    HronError,
    HronErrorKind,
    IsoException,
    IsoUntil,
    MonthName,
    NamedException,
    Schedule,
    Span,
    TimeOfDay,
    Weekday,
    WeekRepeat,
)

_API: dict[str, Any] = json.loads(
    (Path(__file__).parent.parent.parent / "spec" / "api.json").read_text()
)

# spec/api.json, notes.python: snake_case, except these.
_NAMES: dict[str, tuple[str, ...]] = {
    "toString": ("__str__",),
    "equals": ("__eq__", "__hash__"),
    "except": ("except_",),
}


def _python_names(name: str) -> tuple[str, ...]:
    return _NAMES.get(name) or (re.sub(r"(?<!^)([A-Z])", r"_\1", name).lower(),)


def _real_error() -> HronError:
    """A parse error, which carries every optional property: span, input and suggestion."""
    with pytest.raises(HronError) as raised:
        Schedule.parse("every day at 09:00 until dec 31")
    assert raised.value.suggestion is not None
    return raised.value


def _constructed(kind: str) -> object:
    build = getattr(HronError, kind)
    args = {"message": "m", "span": Span(0, 1), "input": "x"}
    return build(**{p: args[p] for p in inspect.signature(build).parameters if p in args})


def _api_gaps(api: dict[str, Any]) -> list[str]:
    schedule, error = api["schedule"], api["error"]
    gaps: list[str] = []
    for member in schedule["staticMethods"]:
        for name in _python_names(member["name"]):
            if not isinstance(vars(Schedule).get(name), classmethod | staticmethod):
                gaps.append(f"static method {name}")
    for member in schedule["instanceMethods"]:
        for name in _python_names(member["name"]):
            if not inspect.isfunction(vars(Schedule).get(name)):
                gaps.append(f"instance method {name}")
    for member in schedule["getters"]:
        for name in _python_names(member["name"]):
            getter = vars(Schedule).get(name)
            if not isinstance(getter, property) or getter.fset or getter.fdel:
                gaps.append(f"read-only property {name}")
    real = _real_error()
    for member in error["properties"]:
        for name in _python_names(member["name"]):
            if getattr(real, name, None) is None:
                gaps.append(f"error property {name}")
    for member in error["methods"]:
        for name in _python_names(member["name"]):
            if not callable(getattr(real, name, None)):
                gaps.append(f"error method {name}")
    for kind in error["constructors"]:
        built = _constructed(kind) if isinstance(vars(HronError).get(kind), classmethod) else None
        if not isinstance(built, HronError) or built.kind != kind:
            gaps.append(f"error constructor {kind}")
    if set(error["kinds"]) != set(get_args(HronErrorKind)):
        gaps.append(f"error kinds {sorted(get_args(HronErrorKind))}, api.json {error['kinds']}")
    return gaps


def test_python_has_every_member_of_api_json() -> None:
    assert _api_gaps(_API) == []


@pytest.mark.parametrize(
    "path,added,gap",
    [
        (("schedule", "staticMethods"), {"name": "fromJson"}, "static method from_json"),
        (("schedule", "instanceMethods"), {"name": "lastFrom"}, "instance method last_from"),
        (("schedule", "getters"), {"name": "weekStart"}, "read-only property week_start"),
        (("error", "properties"), {"name": "hint"}, "error property hint"),
        (("error", "methods"), {"name": "displayPlain"}, "error method display_plain"),
        (("error", "constructors"), "range", "error constructor range"),
    ],
)
def test_a_member_python_lacks_is_a_gap(path: tuple[str, str], added: object, gap: str) -> None:
    api = copy.deepcopy(_API)
    api[path[0]][path[1]].append(added)
    assert _api_gaps(api) == [gap]


def test_an_error_kind_python_lacks_is_a_gap() -> None:
    api = copy.deepcopy(_API)
    api["error"]["kinds"].append("range")
    assert _api_gaps(api) == [
        "error kinds ['cron', 'eval', 'lex', 'parse'], api.json "
        "['lex', 'parse', 'eval', 'cron', 'range']"
    ]


def test_the_getters_return_the_parts() -> None:
    schedule = Schedule.parse(
        "every 2 weeks on monday at 09:00 except dec 25, 2026-03-02 until 2026-12-31"
        " starting 2026-02-02 during jan, mar in america/new_york"
    )
    assert schedule.expression == WeekRepeat(2, (Weekday.MONDAY,), (TimeOfDay(9, 0),))
    assert schedule.except_ == (NamedException(MonthName.DEC, 25), IsoException("2026-03-02"))
    assert schedule.until == IsoUntil("2026-12-31")
    assert schedule.starting == "2026-02-02"
    assert schedule.during == (MonthName.JAN, MonthName.MAR)
    assert schedule.timezone == "America/New_York"


def test_the_getters_of_a_schedule_without_clauses_are_empty() -> None:
    schedule = Schedule.parse("every day at 09:00")
    assert (schedule.except_, schedule.until, schedule.starting, schedule.during) == (
        (),
        None,
        None,
        (),
    )
    assert schedule.timezone is None


@pytest.mark.parametrize(
    "getter", ["timezone", "expression", "except_", "until", "starting", "during"]
)
def test_a_getter_cannot_be_assigned(getter: str) -> None:
    schedule = Schedule.parse("every day at 09:00")
    with pytest.raises(AttributeError):
        setattr(schedule, getter, None)
    assert str(schedule) == "every day at 09:00"


def test_spellings_of_one_time_are_equal_and_hash_alike() -> None:
    padded, short = Schedule.parse("every day at 09:00"), Schedule.parse("every day at 9:00")
    assert padded == short
    assert hash(padded) == hash(short)


@pytest.mark.parametrize(
    "a,b",
    [
        ("every day at 09:00, 10:00", "every day at 10:00, 09:00"),
        ("every day at 09:00, 09:00", "every day at 09:00"),
        ("every day at 09:00 except dec 25, dec 25", "every day at 09:00 except dec 25"),
    ],
    ids=["order", "duplicate_time", "duplicate_exception"],
)
def test_lists_compare_in_order_with_duplicates(a: str, b: str) -> None:
    assert Schedule.parse(a) != Schedule.parse(b)


@pytest.mark.parametrize(
    "clause",
    [
        " until 2026-12-31",
        " starting 2026-01-05",
        " during jan",
        " in UTC",
        " except dec 25",
    ],
    ids=["until", "starting", "during", "timezone", "except"],
)
def test_schedules_that_differ_in_one_clause_are_not_equal(clause: str) -> None:
    assert Schedule.parse("every day at 09:00" + clause) != Schedule.parse("every day at 09:00")


@pytest.mark.parametrize("other", [None, "every day at 09:00", 0, object()])
def test_a_schedule_never_equals_anything_but_a_schedule(other: object) -> None:
    schedule = Schedule.parse("every day at 09:00")
    assert schedule != other
    assert (schedule == other) is False


_CALLS = {
    "parse": Schedule.parse,
    "validate": Schedule.validate,
    "from_cron": Schedule.from_cron,
}


@pytest.mark.parametrize("call", _CALLS.values(), ids=_CALLS.keys())
@pytest.mark.parametrize("value", [None, ["0 9 * * *"], b"0 9 * * *", 0], ids=repr)
def test_an_input_that_is_not_a_str_is_a_type_error(
    call: Callable[[Any], object], value: object
) -> None:
    with pytest.raises(TypeError, match="must be a str, got"):
        call(value)


def test_error_message_is_the_message_alone() -> None:
    error = _real_error()
    assert error.message == str(error)
    assert error.message == "until dec 31 has no year: add a starting date, or use an ISO date"
    assert error.input == "every day at 09:00 until dec 31"
