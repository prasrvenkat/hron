"""API conformance test — verifies Python exposes all methods from spec/api.json."""

from __future__ import annotations

import json
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

from hron import HronError, Schedule

_api_spec_path = Path(__file__).parent.parent.parent / "spec" / "api.json"
with open(_api_spec_path) as _f:
    _api_spec = json.load(_f)

_schedule_spec = _api_spec["schedule"]


# ===========================================================================
# Static methods
# ===========================================================================


class TestStaticMethods:
    def test_parse(self) -> None:
        schedule = Schedule.parse("every day at 09:00")
        assert isinstance(schedule, Schedule)

    def test_from_cron(self) -> None:
        schedule = Schedule.from_cron("0 9 * * *")
        assert isinstance(schedule, Schedule)

    def test_validate(self) -> None:
        assert Schedule.validate("every day at 09:00") is True
        assert Schedule.validate("not a schedule") is False


# ===========================================================================
# Instance methods
# ===========================================================================


class TestInstanceMethods:
    _schedule = Schedule.parse("every day at 09:00")
    _now = datetime(2026, 2, 6, 12, 0, 0, tzinfo=ZoneInfo("UTC"))

    def test_next_from(self) -> None:
        result = self._schedule.next_from(self._now)
        assert result is None or isinstance(result, datetime)
        assert result is not None

    def test_next_n_from(self) -> None:
        results = self._schedule.next_n_from(self._now, 3)
        assert isinstance(results, list)
        assert len(results) == 3
        assert all(isinstance(r, datetime) for r in results)

    def test_matches(self) -> None:
        result = self._schedule.matches(self._now)
        assert isinstance(result, bool)

    def test_to_cron(self) -> None:
        cron = self._schedule.to_cron()
        assert isinstance(cron, str)

    def test_to_string(self) -> None:
        display = str(self._schedule)
        assert isinstance(display, str)
        assert display == "every day at 09:00"


# ===========================================================================
# Getters
# ===========================================================================


class TestGetters:
    def test_timezone_none(self) -> None:
        schedule = Schedule.parse("every day at 09:00")
        assert schedule.timezone is None

    def test_timezone_present(self) -> None:
        schedule = Schedule.parse("every day at 09:00 in America/New_York")
        assert schedule.timezone == "America/New_York"


# ===========================================================================
# Spec coverage — verify all api.json methods are tested above
# ===========================================================================


class TestSpecCoverage:
    # Map camelCase spec names to the snake_case Python equivalents
    _STATIC_METHOD_MAP = {
        "parse": "parse",
        "fromCron": "from_cron",
        "validate": "validate",
    }
    _INSTANCE_METHOD_MAP = {
        "nextFrom": "next_from",
        "nextNFrom": "next_n_from",
        "matches": "matches",
        "occurrences": "occurrences",
        "between": "between",
        "toCron": "to_cron",
        "toString": "__str__",
    }
    _GETTER_MAP = {
        "timezone": "timezone",
    }

    def test_all_static_methods_exist(self) -> None:
        for method in _schedule_spec["staticMethods"]:
            py_name = self._STATIC_METHOD_MAP.get(method["name"])
            assert py_name is not None, f"unmapped spec static method: {method['name']}"
            assert hasattr(Schedule, py_name), f"Schedule missing static method: {py_name}"
            assert callable(getattr(Schedule, py_name))

    def test_all_instance_methods_exist(self) -> None:
        instance = Schedule.parse("every day at 09:00")
        for method in _schedule_spec["instanceMethods"]:
            py_name = self._INSTANCE_METHOD_MAP.get(method["name"])
            assert py_name is not None, f"unmapped spec instance method: {method['name']}"
            assert hasattr(instance, py_name), f"Schedule missing instance method: {py_name}"
            assert callable(getattr(instance, py_name))

    def test_all_getters_exist(self) -> None:
        instance = Schedule.parse("every day at 09:00")
        for getter in _schedule_spec["getters"]:
            py_name = self._GETTER_MAP.get(getter["name"])
            assert py_name is not None, f"unmapped spec getter: {getter['name']}"
            assert hasattr(instance, py_name), f"Schedule missing getter: {py_name}"

    def test_error_kinds_match_spec(self) -> None:
        spec_kinds = set(_api_spec["error"]["kinds"])
        assert spec_kinds == {"lex", "parse", "eval", "cron"}

    def test_error_constructors_exist(self) -> None:
        for kind in _api_spec["error"]["constructors"]:
            assert hasattr(HronError, kind), f"HronError missing constructor: {kind}"
            assert callable(getattr(HronError, kind))

    def test_error_display_rich_exists(self) -> None:
        for method in _api_spec["error"]["methods"]:
            # camelCase -> snake_case
            py_name = "display_rich" if method["name"] == "displayRich" else method["name"]
            err = HronError.eval("test message")
            assert hasattr(err, py_name), f"HronError missing method: {py_name}"
            assert callable(getattr(err, py_name))
