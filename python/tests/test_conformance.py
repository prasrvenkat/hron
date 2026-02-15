"""Conformance test runner — drives all tests from spec/tests.json."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from hron import HronError, Schedule
from tests.conftest import format_zoned, parse_zoned

# Load spec at module level for parametrize
_spec_path = Path(__file__).parent.parent.parent / "spec" / "tests.json"
with open(_spec_path) as _f:
    _spec = json.load(_f)
_default_now = parse_zoned(_spec["now"])


# ===========================================================================
# Parse conformance
# ===========================================================================

_PARSE_SECTIONS = [
    "day_repeat",
    "interval_repeat",
    "week_repeat",
    "month_repeat",
    "ordinal_repeat",
    "single_date",
    "year_repeat",
    "except_clause",
    "until_clause",
    "starting_clause",
    "during_clause",
    "timezone_clause",
    "combined_clauses",
    "case_insensitivity",
]


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

    # Idempotency: parse(canonical).to_string() == canonical
    s2 = Schedule.parse(canonical)
    assert str(s2) == canonical


_PARSE_ERROR_TESTS = [
    (tc.get("name", tc["input"]), tc["input"]) for tc in _spec["parse_errors"]["tests"]
]
_PARSE_ERROR_IDS = [t[0] for t in _PARSE_ERROR_TESTS]


@pytest.mark.parametrize("name,input_text", _PARSE_ERROR_TESTS, ids=_PARSE_ERROR_IDS)
def test_parse_errors(name: str, input_text: str) -> None:
    with pytest.raises(HronError):
        Schedule.parse(input_text)


# ===========================================================================
# Eval conformance
# ===========================================================================

# Dynamically discover eval sections (skip non-test entries)
_SKIP_EVAL_SECTIONS = {"description", "matches", "occurrences", "between", "previous_from"}
_EVAL_SECTIONS = [s for s in _spec["eval"] if s not in _SKIP_EVAL_SECTIONS]


def _collect_eval_tests() -> list[tuple[str, dict]]:  # type: ignore[type-arg]
    tests: list[tuple[str, dict]] = []  # type: ignore[type-arg]
    for section in _EVAL_SECTIONS:
        for tc in _spec["eval"][section]["tests"]:
            name = tc.get("name", tc["expression"])
            tests.append((f"{section}/{name}", tc))
    return tests


_EVAL_TESTS = _collect_eval_tests()
_EVAL_IDS = [t[0] for t in _EVAL_TESTS]


@pytest.mark.parametrize("name,tc", _EVAL_TESTS, ids=_EVAL_IDS)
def test_eval(name: str, tc: dict) -> None:  # type: ignore[type-arg]
    schedule = Schedule.parse(tc["expression"])
    now = parse_zoned(tc["now"]) if "now" in tc else _default_now

    # next (full timestamp)
    if "next" in tc:
        result = schedule.next_from(now)
        if tc["next"] is None:
            assert result is None
        else:
            assert result is not None
            assert format_zoned(result) == tc["next"]

    # next_date (date-only check)
    if "next_date" in tc:
        result = schedule.next_from(now)
        assert result is not None
        assert result.date().isoformat() == tc["next_date"]

    # next_n (list of timestamps)
    if "next_n" in tc:
        expected: list[str] = tc["next_n"]
        n_count = tc.get("next_n_count", len(expected))
        results = schedule.next_n_from(now, n_count)
        assert len(results) == len(expected)
        for j, (r, e) in enumerate(zip(results, expected, strict=True)):
            assert format_zoned(r) == e, f"next_n_from[{j}] mismatch"

    # next_n_length (just check count)
    if "next_n_length" in tc:
        expected_len: int = tc["next_n_length"]
        n_count_len: int = tc["next_n_count"]
        results = schedule.next_n_from(now, n_count_len)
        assert len(results) == expected_len


# ===========================================================================
# Eval matches conformance
# ===========================================================================

_MATCHES_TESTS = [
    (tc.get("name", tc["expression"]), tc) for tc in _spec["eval"]["matches"]["tests"]
]
_MATCHES_IDS = [t[0] for t in _MATCHES_TESTS]


@pytest.mark.parametrize("name,tc", _MATCHES_TESTS, ids=_MATCHES_IDS)
def test_eval_matches(name: str, tc: dict) -> None:  # type: ignore[type-arg]
    schedule = Schedule.parse(tc["expression"])
    dt = parse_zoned(tc["datetime"])
    result = schedule.matches(dt)
    assert result == tc["expected"]


# ===========================================================================
# Eval occurrences conformance
# ===========================================================================

_OCCURRENCES_TESTS = [
    (tc.get("name", tc["expression"]), tc) for tc in _spec["eval"]["occurrences"]["tests"]
]
_OCCURRENCES_IDS = [t[0] for t in _OCCURRENCES_TESTS]


@pytest.mark.parametrize("name,tc", _OCCURRENCES_TESTS, ids=_OCCURRENCES_IDS)
def test_eval_occurrences(name: str, tc: dict) -> None:  # type: ignore[type-arg]
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


# ===========================================================================
# Eval between conformance
# ===========================================================================

_BETWEEN_TESTS = [
    (tc.get("name", tc["expression"]), tc) for tc in _spec["eval"]["between"]["tests"]
]
_BETWEEN_IDS = [t[0] for t in _BETWEEN_TESTS]


@pytest.mark.parametrize("name,tc", _BETWEEN_TESTS, ids=_BETWEEN_IDS)
def test_eval_between(name: str, tc: dict) -> None:  # type: ignore[type-arg]
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


# ===========================================================================
# Eval previous_from conformance
# ===========================================================================

_PREVIOUS_FROM_TESTS = [
    (tc.get("name", tc["expression"]), tc) for tc in _spec["eval"]["previous_from"]["tests"]
]
_PREVIOUS_FROM_IDS = [t[0] for t in _PREVIOUS_FROM_TESTS]


@pytest.mark.parametrize("name,tc", _PREVIOUS_FROM_TESTS, ids=_PREVIOUS_FROM_IDS)
def test_eval_previous_from(name: str, tc: dict) -> None:  # type: ignore[type-arg]
    schedule = Schedule.parse(tc["expression"])
    now = parse_zoned(tc["now"])
    result = schedule.previous_from(now)

    if tc["expected"] is None:
        assert result is None
    else:
        assert result is not None
        assert format_zoned(result) == tc["expected"]


# ===========================================================================
# Cron conformance
# ===========================================================================

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
