from __future__ import annotations

import json
from datetime import UTC, datetime
from itertools import islice, pairwise
from pathlib import Path
from typing import Any

import pytest

from hron import (
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
    HronError,
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
    Schedule,
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
    YearTarget,
)
from tests.conftest import format_zoned, parse_zoned

_spec_path = Path(__file__).parent.parent.parent / "spec" / "tests.json"
with open(_spec_path) as _f:
    _spec = json.load(_f)
_default_now = parse_zoned(_spec["now"])


_KNOWN_TOP_LEVEL = {
    "$schema",
    "version",
    "description",
    "now",
    "_eval_assertion_types",
    "_behavioral_notes",
    "parse",
    "parse_errors",
    "eval",
    "cron",
    "invariants",
}
_NEXT_EVAL_SECTIONS = [
    "day_repeat",
    "interval_repeat",
    "month_repeat",
    "week_repeat",
    "single_date",
    "year_repeat",
    "except",
    "until",
    "except_and_until",
    "n_occurrences",
    "multi_time",
    "during",
    "day_ranges",
    "leap_year",
    "dst_spring_forward",
    "dst_fall_back",
    "timezone_default",
    "contradictory",
    "edge_cases",
]
_KNOWN_EVAL = {"description", "matches", "occurrences", "between", "previous_from"}
_KNOWN_EVAL.update(_NEXT_EVAL_SECTIONS)
_KNOWN_CRON = {"to_cron", "to_cron_errors", "from_cron", "from_cron_errors", "roundtrip"}


def test_spec_sections_are_known() -> None:
    """A section this runner does not know would otherwise be skipped silently."""
    assert set(_spec) <= _KNOWN_TOP_LEVEL, set(_spec) - _KNOWN_TOP_LEVEL
    assert set(_spec["eval"]) <= _KNOWN_EVAL, set(_spec["eval"]) - _KNOWN_EVAL
    assert set(_spec["cron"]) <= _KNOWN_CRON, set(_spec["cron"]) - _KNOWN_CRON


_LABELS = {"name", "description"}
_NEXT_FIELDS = {"expression", "now", "next", "next_date", "next_n", "next_n_count", "next_n_length"}


def _checked_fields(section: str) -> set[str]:
    if section.startswith("parse/"):
        return {"input", "canonical"}
    return {
        "parse_errors": {"input", "error", "display"},
        "eval/matches": {"expression", "datetime", "expected"},
        "eval/previous_from": {"expression", "now", "expected"},
        "eval/occurrences": {"expression", "from", "take", "expected"},
        "eval/between": {"expression", "from", "to", "expected", "expected_count"},
        "cron/to_cron": {"hron", "cron"},
        "cron/to_cron_errors": {"hron", "error"},
        "cron/from_cron": {"cron", "hron"},
        "cron/from_cron_errors": {"cron", "error"},
        "cron/roundtrip": {"hron"},
        "invariants": {"expression", "now"},
    }.get(section, _NEXT_FIELDS)


def _all_cases() -> list[tuple[str, dict[str, Any]]]:
    groups = {f"parse/{k}": v for k, v in _spec["parse"].items() if k != "description"}
    groups |= {f"eval/{k}": v for k, v in _spec["eval"].items() if k != "description"}
    groups |= {f"cron/{k}": v for k, v in _spec["cron"].items()}
    groups |= {k: _spec[k] for k in ("parse_errors", "invariants")}
    return [(section, tc) for section, group in groups.items() for tc in group["tests"]]


def test_spec_case_fields_are_checked() -> None:
    """A case field this runner does not check would otherwise pass without being asserted."""
    unchecked = [
        f"{section}/{tc.get('name')}: {sorted(extra)}"
        for section, tc in _all_cases()
        if (extra := tc.keys() - _LABELS - _checked_fields(section))
    ]
    assert not unchecked, unchecked


_PARSE_SECTIONS = [section for section in _spec["parse"] if section != "description"]


def _collect_parse_tests() -> list[tuple[str, str, str]]:
    tests: list[tuple[str, str, str]] = []
    for section in _PARSE_SECTIONS:
        for tc in _spec["parse"][section]["tests"]:
            name = tc.get("name", tc["input"])
            tests.append((f"{section}/{name}", tc["input"], tc["canonical"]))
    return tests


_PARSE_TESTS = _collect_parse_tests()
_PARSE_IDS = [t[0] for t in _PARSE_TESTS]


@pytest.mark.parametrize("name,input_text,canonical", _PARSE_TESTS, ids=_PARSE_IDS)
def test_parse_roundtrip(name: str, input_text: str, canonical: str) -> None:
    schedule = Schedule.parse(input_text)
    display = str(schedule)
    assert display == canonical

    s2 = Schedule.parse(canonical)
    assert str(s2) == canonical
    _assert_rebuilds(schedule)


def _assert_rebuilds(schedule: Schedule) -> None:
    rebuilt = Schedule(schedule.data)
    assert rebuilt == schedule
    assert str(rebuilt) == str(schedule)


_PARSE_ERROR_TESTS = [(tc.get("name", tc["input"]), tc) for tc in _spec["parse_errors"]["tests"]]
_PARSE_ERROR_IDS = [t[0] for t in _PARSE_ERROR_TESTS]


@pytest.mark.parametrize("name,tc", _PARSE_ERROR_TESTS, ids=_PARSE_ERROR_IDS)
def test_parse_errors(name: str, tc: dict[str, Any]) -> None:
    expected = tc["error"]
    unknown = expected.keys() - {"kind", "message", "span", "suggestion"}
    assert not unknown, f"error fields this runner does not know: {sorted(unknown)}"

    assert not Schedule.validate(tc["input"])
    with pytest.raises(HronError) as raised:
        Schedule.parse(tc["input"])
    error = raised.value
    assert error.kind == expected["kind"]
    assert str(error) == expected["message"]
    assert error.span is not None
    assert [error.span.start, error.span.end] == expected["span"]
    assert error.suggestion == expected.get("suggestion")
    if "display" in tc:
        assert error.display_rich() == tc["display"]


_NEXT_ASSERTIONS = {"next", "next_date", "next_n", "next_n_length"}


def _collect_eval_tests() -> list[tuple[str, dict[str, Any]]]:
    tests: list[tuple[str, dict[str, Any]]] = []
    for section in _NEXT_EVAL_SECTIONS:
        for tc in _spec["eval"][section]["tests"]:
            name = tc.get("name", tc["expression"])
            tests.append((f"{section}/{name}", tc))
    return tests


_EVAL_TESTS = _collect_eval_tests()
_EVAL_IDS = [t[0] for t in _EVAL_TESTS]


@pytest.mark.parametrize("name,tc", _EVAL_TESTS, ids=_EVAL_IDS)
def test_eval(name: str, tc: dict[str, Any]) -> None:
    assert _NEXT_ASSERTIONS & tc.keys(), f"{name}: no assertion field this runner understands"
    schedule = Schedule.parse(tc["expression"])
    now = parse_zoned(tc["now"]) if "now" in tc else _default_now

    if "next" in tc:
        result = schedule.next_from(now)
        if tc["next"] is None:
            assert result is None
        else:
            assert result is not None
            assert format_zoned(result) == tc["next"]

    if "next_date" in tc:
        result = schedule.next_from(now)
        if tc["next_date"] is None:
            assert result is None
        else:
            assert result is not None
            assert result.date().isoformat() == tc["next_date"]

    if "next_n" in tc:
        expected: list[str] = tc["next_n"]
        n_count = tc.get("next_n_count", len(expected))
        results = schedule.next_n_from(now, n_count)
        assert len(results) == len(expected)
        for j, (r, e) in enumerate(zip(results, expected, strict=True)):
            assert format_zoned(r) == e, f"next_n_from[{j}] mismatch"

    if "next_n_length" in tc:
        expected_len: int = tc["next_n_length"]
        n_count_len: int = tc["next_n_count"]
        results = schedule.next_n_from(now, n_count_len)
        assert len(results) == expected_len


_MATCHES_TESTS = [
    (tc.get("name", tc["expression"]), tc) for tc in _spec["eval"]["matches"]["tests"]
]
_MATCHES_IDS = [t[0] for t in _MATCHES_TESTS]


@pytest.mark.parametrize("name,tc", _MATCHES_TESTS, ids=_MATCHES_IDS)
def test_eval_matches(name: str, tc: dict[str, Any]) -> None:
    schedule = Schedule.parse(tc["expression"])
    dt = parse_zoned(tc["datetime"])
    result = schedule.matches(dt)
    assert result == tc["expected"]


_OCCURRENCES_TESTS = [
    (tc.get("name", tc["expression"]), tc) for tc in _spec["eval"]["occurrences"]["tests"]
]
_OCCURRENCES_IDS = [t[0] for t in _OCCURRENCES_TESTS]


@pytest.mark.parametrize("name,tc", _OCCURRENCES_TESTS, ids=_OCCURRENCES_IDS)
def test_eval_occurrences(name: str, tc: dict[str, Any]) -> None:
    schedule = Schedule.parse(tc["expression"])
    from_ = parse_zoned(tc["from"])
    take = tc["take"]
    expected: list[str] = tc["expected"]

    results = []
    for i, dt in enumerate(schedule.occurrences(from_)):
        if i >= take:
            break
        results.append(dt)

    assert len(results) == len(expected)
    for j, (r, e) in enumerate(zip(results, expected, strict=True)):
        assert format_zoned(r) == e, f"occurrences[{j}] mismatch"


_BETWEEN_TESTS = [
    (tc.get("name", tc["expression"]), tc) for tc in _spec["eval"]["between"]["tests"]
]
_BETWEEN_IDS = [t[0] for t in _BETWEEN_TESTS]


@pytest.mark.parametrize("name,tc", _BETWEEN_TESTS, ids=_BETWEEN_IDS)
def test_eval_between(name: str, tc: dict[str, Any]) -> None:
    schedule = Schedule.parse(tc["expression"])
    from_ = parse_zoned(tc["from"])
    to = parse_zoned(tc["to"])

    results = list(schedule.between(from_, to))

    if "expected" in tc:
        expected: list[str] = tc["expected"]
        assert len(results) == len(expected)
        for j, (r, e) in enumerate(zip(results, expected, strict=True)):
            assert format_zoned(r) == e, f"between[{j}] mismatch"
    elif "expected_count" in tc:
        assert len(results) == tc["expected_count"]
    else:
        pytest.fail(f"{name}: no assertion field this runner understands")


_PREVIOUS_FROM_TESTS = [
    (tc.get("name", tc["expression"]), tc) for tc in _spec["eval"]["previous_from"]["tests"]
]
_PREVIOUS_FROM_IDS = [t[0] for t in _PREVIOUS_FROM_TESTS]


@pytest.mark.parametrize("name,tc", _PREVIOUS_FROM_TESTS, ids=_PREVIOUS_FROM_IDS)
def test_eval_previous_from(name: str, tc: dict[str, Any]) -> None:
    schedule = Schedule.parse(tc["expression"])
    now = parse_zoned(tc["now"])
    result = schedule.previous_from(now)

    if tc["expected"] is None:
        assert result is None
    else:
        assert result is not None
        assert format_zoned(result) == tc["expected"]


_TO_CRON_TESTS = [
    (tc.get("name", tc["hron"]), tc["hron"], tc["cron"]) for tc in _spec["cron"]["to_cron"]["tests"]
]
_TO_CRON_IDS = [t[0] for t in _TO_CRON_TESTS]


@pytest.mark.parametrize("name,hron,cron", _TO_CRON_TESTS, ids=_TO_CRON_IDS)
def test_to_cron(name: str, hron: str, cron: str) -> None:
    schedule = Schedule.parse(hron)
    assert schedule.to_cron() == cron


_TO_CRON_ERROR_TESTS = [
    (tc.get("name", tc["hron"]), tc["hron"], tc["error"])
    for tc in _spec["cron"]["to_cron_errors"]["tests"]
]
_TO_CRON_ERROR_IDS = [t[0] for t in _TO_CRON_ERROR_TESTS]


@pytest.mark.parametrize("name,hron,error", _TO_CRON_ERROR_TESTS, ids=_TO_CRON_ERROR_IDS)
def test_to_cron_errors(name: str, hron: str, error: str) -> None:
    schedule = Schedule.parse(hron)
    with pytest.raises(HronError) as raised:
        schedule.to_cron()
    assert raised.value.kind == "cron"
    assert str(raised.value) == error


_FROM_CRON_TESTS = [
    (tc.get("name", tc["cron"]), tc["cron"], tc["hron"])
    for tc in _spec["cron"]["from_cron"]["tests"]
]
_FROM_CRON_IDS = [t[0] for t in _FROM_CRON_TESTS]


@pytest.mark.parametrize("name,cron,hron", _FROM_CRON_TESTS, ids=_FROM_CRON_IDS)
def test_from_cron(name: str, cron: str, hron: str) -> None:
    schedule = Schedule.from_cron(cron)
    assert str(schedule) == hron
    _assert_rebuilds(schedule)


_FROM_CRON_ERROR_TESTS = [
    (tc.get("name", tc["cron"]), tc["cron"], tc["error"])
    for tc in _spec["cron"]["from_cron_errors"]["tests"]
]
_FROM_CRON_ERROR_IDS = [t[0] for t in _FROM_CRON_ERROR_TESTS]


@pytest.mark.parametrize("name,cron,error", _FROM_CRON_ERROR_TESTS, ids=_FROM_CRON_ERROR_IDS)
def test_from_cron_errors(name: str, cron: str, error: str) -> None:
    with pytest.raises(HronError) as raised:
        Schedule.from_cron(cron)
    assert raised.value.kind == "cron"
    assert str(raised.value) == error


_ROUNDTRIP_TESTS = [
    (tc.get("name", tc["hron"]), tc["hron"]) for tc in _spec["cron"]["roundtrip"]["tests"]
]
_ROUNDTRIP_IDS = [t[0] for t in _ROUNDTRIP_TESTS]


@pytest.mark.parametrize("name,hron", _ROUNDTRIP_TESTS, ids=_ROUNDTRIP_IDS)
def test_cron_roundtrip(name: str, hron: str) -> None:
    schedule = Schedule.parse(hron)
    cron1 = schedule.to_cron()
    back = Schedule.from_cron(cron1)
    cron2 = back.to_cron()
    assert cron1 == cron2


_INVARIANT_COUNT: int = _spec["invariants"]["count"]


def _utc(dt: datetime) -> datetime:
    """Datetimes sharing one ZoneInfo compare by wall clock, so compare instants in UTC."""
    return dt.astimezone(UTC)


def _utc_list(dts: list[datetime]) -> list[datetime]:
    return [_utc(dt) for dt in dts]


def _next_n(schedule: Schedule, now: datetime) -> list[datetime]:
    return schedule.next_n_from(now, _INVARIANT_COUNT)


def _rule_next_matches(name: str, schedule: Schedule, now: datetime) -> None:
    t = schedule.next_from(now)
    if t is not None:
        assert schedule.matches(t), f"{name}: next_matches: matches({t}) is false"


def _rule_next_after_now(name: str, schedule: Schedule, now: datetime) -> None:
    t = schedule.next_from(now)
    if t is not None:
        assert _utc(t) > _utc(now), f"{name}: next_after_now: {t} is not after {now}"


def _rule_next_n_chain(name: str, schedule: Schedule, now: datetime) -> None:
    results = _next_n(schedule, now)
    first = schedule.next_from(now)
    if first is None:
        assert results == [], f"{name}: next_n_chain: nextFrom is null but nextNFrom is not empty"
        return
    assert results, f"{name}: next_n_chain: nextNFrom is empty but nextFrom is {first}"
    assert _utc(results[0]) == _utc(first), f"{name}: next_n_chain: first element is not nextFrom"
    for a, b in pairwise(results):
        assert _utc(a) < _utc(b), f"{name}: next_n_chain: {b} does not follow {a}"
        after_a = schedule.next_from(a)
        assert after_a is not None and _utc(after_a) == _utc(b), (
            f"{name}: next_n_chain: nextFrom({a}) is {after_a}, not {b}"
        )


def _rule_occurrences_prefix(name: str, schedule: Schedule, now: datetime) -> None:
    taken = list(islice(schedule.occurrences(now), _INVARIANT_COUNT))
    assert _utc_list(taken) == _utc_list(_next_n(schedule, now)), f"{name}: occurrences_prefix"


def _rule_between_window(name: str, schedule: Schedule, now: datetime) -> None:
    results = _next_n(schedule, now)
    if results:
        window = list(schedule.between(now, results[-1]))
        assert _utc_list(window) == _utc_list(results), f"{name}: between_window"


def _rule_prev_inverse(name: str, schedule: Schedule, now: datetime) -> None:
    for a, b in pairwise(_next_n(schedule, now)):
        prev = schedule.previous_from(b)
        assert prev is not None and _utc(prev) == _utc(a), (
            f"{name}: prev_inverse: previousFrom({b}) is {prev}, not {a}"
        )


def _rule_prev_before_now(name: str, schedule: Schedule, now: datetime) -> None:
    p = schedule.previous_from(now)
    if p is None:
        return
    assert _utc(p) < _utc(now), f"{name}: prev_before_now: {p} is not before {now}"
    assert schedule.matches(p), f"{name}: prev_before_now: matches({p}) is false"
    after = schedule.next_from(p)
    assert after is None or _utc(after) >= _utc(now), (
        f"{name}: prev_before_now: nextFrom({p}) is {after}, earlier than {now}"
    )


def _rule_display_roundtrip(name: str, schedule: Schedule, now: datetime) -> None:
    first = str(schedule)
    assert str(Schedule.parse(first)) == first, f"{name}: display_roundtrip"


_INVARIANT_RULES = {
    "next_matches": _rule_next_matches,
    "next_after_now": _rule_next_after_now,
    "next_n_chain": _rule_next_n_chain,
    "occurrences_prefix": _rule_occurrences_prefix,
    "between_window": _rule_between_window,
    "prev_inverse": _rule_prev_inverse,
    "prev_before_now": _rule_prev_before_now,
    "display_roundtrip": _rule_display_roundtrip,
}
_INVARIANT_TESTS = [
    (rule, tc["name"], tc)
    for rule in _spec["invariants"]["rules"]
    for tc in _spec["invariants"]["tests"]
]
_INVARIANT_IDS = [f"{rule}/{name}" for rule, name, _ in _INVARIANT_TESTS]


@pytest.mark.parametrize("rule,name,tc", _INVARIANT_TESTS, ids=_INVARIANT_IDS)
def test_invariant(rule: str, name: str, tc: dict[str, Any]) -> None:
    check = _INVARIANT_RULES.get(rule)
    assert check is not None, f"invariant rule {rule!r} is not implemented by this runner"
    check(name, Schedule.parse(tc["expression"]), parse_zoned(tc["now"]))


_build = json.loads((_spec_path.parent / "build.json").read_text())


def test_build_groups_are_known() -> None:
    assert set(_build) == {"description", "rules", "order", "canonical"}, set(_build)
    for group in ("rules", "order", "canonical"):
        assert set(_build[group]) == {"description", "tests"}, group


_BUILD_TESTS = [
    (f"{group}/{tc['name']}", tc)
    for group in ("rules", "order", "canonical")
    for tc in _build[group]["tests"]
]


@pytest.mark.parametrize("name,tc", _BUILD_TESTS, ids=[t[0] for t in _BUILD_TESTS])
def test_build(name: str, tc: dict[str, Any]) -> None:
    assert tc.keys() - _LABELS in ({"parts", "error"}, {"parts", "canonical"}), sorted(tc)
    data = _parts(tc["parts"])
    if "error" in tc:
        expected = tc["error"]
        assert set(expected) == {"kind", "message"}, sorted(expected)
        assert expected["kind"] == "eval"
        with pytest.raises(HronError) as raised:
            Schedule(data)
        error = raised.value
        assert error.kind == "eval"
        assert str(error) == expected["message"]
        assert (error.span, error.input_text, error.suggestion) == (None, None, None)
        assert error.display_rich() == f"error: {expected['message']}"
    else:
        schedule = Schedule(data)
        assert str(schedule) == tc["canonical"]
        assert Schedule.parse(tc["canonical"]) == schedule


def _fields(
    value: object, required: set[str], optional: frozenset[str] = frozenset()
) -> dict[str, Any]:
    assert isinstance(value, dict), value
    assert required <= value.keys() <= required | optional, f"fields {sorted(value)}"
    return value


def _parts(value: object) -> ScheduleData:
    clauses = frozenset({"except", "until", "starting", "during", "timezone"})
    parts = _fields(value, {"expression"}, clauses)
    until = parts.get("until")
    return ScheduleData(
        expr=_expression(parts["expression"]),
        timezone=parts.get("timezone"),
        except_=tuple(_exception(d) for d in parts.get("except", [])),
        until=None if until is None else _until(until),
        anchor=parts.get("starting"),
        during=tuple(_month(m) for m in parts.get("during", [])),
    )


def _expression(value: object) -> ScheduleExpr:
    assert isinstance(value, dict) and len(value) == 1, value
    [(kind, fields)] = value.items()
    match kind:
        case "interval_repeat":
            f = _fields(fields, {"interval", "unit", "from", "to"}, frozenset({"day_filter"}))
            day_filter = f.get("day_filter")
            return IntervalRepeat(
                f["interval"],
                {"minutes": IntervalUnit.MIN, "hours": IntervalUnit.HOURS}[f["unit"]],
                _time(f["from"]),
                _time(f["to"]),
                None if day_filter is None else _day_filter(day_filter),
            )
        case "day_repeat":
            f = _fields(fields, {"interval", "days", "times"})
            return DayRepeat(f["interval"], _day_filter(f["days"]), _times(f["times"]))
        case "week_repeat":
            f = _fields(fields, {"interval", "days", "times"})
            return WeekRepeat(f["interval"], tuple(map(Weekday, f["days"])), _times(f["times"]))
        case "month_repeat":
            f = _fields(fields, {"interval", "target", "times"})
            return MonthRepeat(f["interval"], _month_target(f["target"]), _times(f["times"]))
        case "single_date":
            f = _fields(fields, {"date", "times"})
            return SingleDateExpr(_date(f["date"]), _times(f["times"]))
        case "year_repeat":
            f = _fields(fields, {"interval", "target", "times"})
            return YearRepeat(f["interval"], _year_target(f["target"]), _times(f["times"]))
    raise AssertionError(f"expression kind {kind!r} is not known to this runner")


def _time(value: str) -> TimeOfDay:
    hour, minute = value.split(":")
    return TimeOfDay(int(hour), int(minute))


def _times(values: list[str]) -> tuple[TimeOfDay, ...]:
    return tuple(_time(t) for t in values)


def _month(name: str) -> MonthName:
    month = MonthName.try_parse(name)
    assert month is not None, name
    return month


def _day_filter(value: object) -> DayFilter:
    match value:
        case "every":
            return DayFilterEvery()
        case "weekday":
            return DayFilterWeekday()
        case "weekend":
            return DayFilterWeekend()
    days = _fields(value, {"days"})["days"]
    return DayFilterDays(tuple(map(Weekday, days)))


def _date_parts(value: object) -> str | tuple[MonthName, int]:
    assert isinstance(value, dict) and len(value) == 1, value
    if "iso" in value:
        return value["iso"]
    f = _fields(value["named"], {"month", "day"})
    return _month(f["month"]), f["day"]


def _exception(value: object) -> ExceptionSpec:
    match _date_parts(value):
        case str(iso):
            return IsoException(iso)
        case (month, day):
            return NamedException(month, day)


def _until(value: object) -> UntilSpec:
    match _date_parts(value):
        case str(iso):
            return IsoUntil(iso)
        case (month, day):
            return NamedUntil(month, day)


def _date(value: object) -> DateSpec:
    match _date_parts(value):
        case str(iso):
            return IsoDate(iso)
        case (month, day):
            return NamedDate(month, day)


def _day_spec(value: object) -> DayOfMonthSpec:
    assert isinstance(value, dict) and len(value) == 1, value
    if "single" in value:
        return SingleDay(value["single"])
    start, end = value["range"]
    return DayRange(start, end)


def _month_target(value: object) -> MonthTarget:
    match value:
        case "last_day":
            return LastDayTarget()
        case "last_weekday":
            return LastWeekdayTarget()
    assert isinstance(value, dict) and len(value) == 1, value
    [(kind, fields)] = value.items()
    match kind:
        case "days":
            return DaysTarget(tuple(_day_spec(s) for s in fields))
        case "nearest_weekday":
            f = _fields(fields, {"day", "direction"})
            direction = f["direction"]
            return NearestWeekdayTarget(
                f["day"], None if direction is None else NearestDirection(direction)
            )
        case "ordinal_weekday":
            f = _fields(fields, {"ordinal", "weekday"})
            return OrdinalWeekdayTarget(OrdinalPosition(f["ordinal"]), Weekday(f["weekday"]))
    raise AssertionError(f"month target {kind!r} is not known to this runner")


def _year_target(value: object) -> YearTarget:
    assert isinstance(value, dict) and len(value) == 1, value
    [(kind, fields)] = value.items()
    match kind:
        case "date":
            f = _fields(fields, {"month", "day"})
            return YearDateTarget(_month(f["month"]), f["day"])
        case "ordinal_weekday":
            f = _fields(fields, {"ordinal", "weekday", "month"})
            return YearOrdinalWeekdayTarget(
                OrdinalPosition(f["ordinal"]), Weekday(f["weekday"]), _month(f["month"])
            )
        case "day_of_month":
            f = _fields(fields, {"day", "month"})
            return YearDayOfMonthTarget(f["day"], _month(f["month"]))
        case "last_weekday":
            return YearLastWeekdayTarget(_month(_fields(fields, {"month"})["month"]))
    raise AssertionError(f"year target {kind!r} is not known to this runner")
