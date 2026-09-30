from __future__ import annotations

import json
from datetime import UTC, datetime
from itertools import islice, pairwise
from pathlib import Path
from typing import Any

import pytest

from hron import HronError, Schedule
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
    """The case fields this runner reads or asserts, per section."""
    if section.startswith("parse/"):
        return {"input", "canonical"}
    return {
        "parse_errors": {"input", "error_contains"},
        "eval/matches": {"expression", "datetime", "expected"},
        "eval/previous_from": {"expression", "now", "expected"},
        "eval/occurrences": {"expression", "from", "take", "expected"},
        "eval/between": {"expression", "from", "to", "expected", "expected_count"},
        "cron/to_cron": {"hron", "cron"},
        "cron/to_cron_errors": {"hron"},
        "cron/from_cron": {"cron", "hron"},
        "cron/from_cron_errors": {"cron"},
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


_PARSE_ERROR_TESTS = [(tc.get("name", tc["input"]), tc) for tc in _spec["parse_errors"]["tests"]]
_PARSE_ERROR_IDS = [t[0] for t in _PARSE_ERROR_TESTS]


@pytest.mark.parametrize("name,tc", _PARSE_ERROR_TESTS, ids=_PARSE_ERROR_IDS)
def test_parse_errors(name: str, tc: dict[str, Any]) -> None:
    with pytest.raises(HronError) as error:
        Schedule.parse(tc["input"])
    assert not Schedule.validate(tc["input"])
    if "error_contains" in tc:
        assert tc["error_contains"] in str(error.value)


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
    (tc.get("name", tc["hron"]), tc["hron"]) for tc in _spec["cron"]["to_cron_errors"]["tests"]
]
_TO_CRON_ERROR_IDS = [t[0] for t in _TO_CRON_ERROR_TESTS]


@pytest.mark.parametrize("name,hron", _TO_CRON_ERROR_TESTS, ids=_TO_CRON_ERROR_IDS)
def test_to_cron_errors(name: str, hron: str) -> None:
    schedule = Schedule.parse(hron)
    with pytest.raises(HronError):
        schedule.to_cron()


_FROM_CRON_TESTS = [
    (tc.get("name", tc["cron"]), tc["cron"], tc["hron"])
    for tc in _spec["cron"]["from_cron"]["tests"]
]
_FROM_CRON_IDS = [t[0] for t in _FROM_CRON_TESTS]


@pytest.mark.parametrize("name,cron,hron", _FROM_CRON_TESTS, ids=_FROM_CRON_IDS)
def test_from_cron(name: str, cron: str, hron: str) -> None:
    schedule = Schedule.from_cron(cron)
    assert str(schedule) == hron


_FROM_CRON_ERROR_TESTS = [
    (tc.get("name", tc["cron"]), tc["cron"]) for tc in _spec["cron"]["from_cron_errors"]["tests"]
]
_FROM_CRON_ERROR_IDS = [t[0] for t in _FROM_CRON_ERROR_TESTS]


@pytest.mark.parametrize("name,cron", _FROM_CRON_ERROR_TESTS, ids=_FROM_CRON_ERROR_IDS)
def test_from_cron_errors(name: str, cron: str) -> None:
    with pytest.raises(HronError):
        Schedule.from_cron(cron)


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
