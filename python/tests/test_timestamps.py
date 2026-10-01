from __future__ import annotations

import os
import sys
import time
from collections.abc import Callable, Iterator
from datetime import UTC, date, datetime, timedelta, timezone
from itertools import islice
from typing import Any, cast
from zoneinfo import ZoneInfo

import pytest

from hron import Schedule

_NOW = datetime(2026, 2, 6, 12, 0, tzinfo=UTC)
_NEW_YORK = Schedule.parse("every day at 09:00 in America/New_York")
_ZONELESS = Schedule.parse("every day at 09:00")

_CALLS: dict[str, Callable[[Schedule, Any], object]] = {
    "next_from": lambda s, t: s.next_from(t),
    "previous_from": lambda s, t: s.previous_from(t),
    "matches": lambda s, t: s.matches(t),
    "next_n_from": lambda s, t: s.next_n_from(t, 2),
    "occurrences": lambda s, t: s.occurrences(t),
    "between_from": lambda s, t: s.between(t, _NOW),
    "between_to": lambda s, t: s.between(_NOW, t),
}


@pytest.mark.parametrize("call", _CALLS.values(), ids=_CALLS.keys())
@pytest.mark.parametrize(
    "value", ["2026-02-06T12:00:00Z", date(2026, 2, 6), None, 0], ids=["str", "date", "None", "int"]
)
def test_a_timestamp_that_is_not_a_datetime_raises_type_error_at_the_call(
    call: Callable[[Schedule, Any], object], value: object
) -> None:
    # occurrences and between are lazy, so the call alone must raise, before any next().
    with pytest.raises(TypeError, match="must be a datetime, not"):
        call(_NEW_YORK, value)


def _results(schedule: Schedule, t: datetime) -> dict[str, object]:
    return {
        "next_from": schedule.next_from(t),
        "previous_from": schedule.previous_from(t),
        "matches": schedule.matches(t),
        "next_n_from": schedule.next_n_from(t, 2),
        "occurrences": list(islice(schedule.occurrences(t), 2)),
        "between_from": list(schedule.between(t, _NOW)),
        "between_to": list(schedule.between(_NOW, t)),
    }


_NOTHING = {
    "next_from": None,
    "previous_from": None,
    "matches": False,
    "next_n_from": [],
    "occurrences": [],
    "between_from": [],
    "between_to": [],
}


@pytest.fixture(params=["UTC", "Asia/Tokyo", "America/Los_Angeles"])
def host_zone(request: pytest.FixtureRequest) -> Iterator[str]:
    """Converting a naive datetime.max to UTC raises ValueError east of UTC and
    OverflowError west of it."""
    if not hasattr(time, "tzset"):
        pytest.skip("time.tzset is Unix only")
    saved = os.environ.get("TZ")
    os.environ["TZ"] = request.param
    time.tzset()
    yield request.param
    if saved is None:
        del os.environ["TZ"]
    else:
        os.environ["TZ"] = saved
    time.tzset()


@pytest.mark.parametrize("limit", [datetime.min, datetime.max], ids=["min", "max"])
def test_naive_datetime_limits_are_outside_the_supported_range(
    host_zone: str, limit: datetime
) -> None:
    assert _results(_NEW_YORK, limit) == _NOTHING


_PLUS_23_59 = timezone(timedelta(hours=23, minutes=59))
_MINUS_23_59 = timezone(-timedelta(hours=23, minutes=59))


@pytest.mark.parametrize(
    "limit",
    [
        datetime.min.replace(tzinfo=UTC),
        datetime.max.replace(tzinfo=UTC),
        datetime.min.replace(tzinfo=_PLUS_23_59),
        datetime.min.replace(tzinfo=_MINUS_23_59),
        datetime.max.replace(tzinfo=_PLUS_23_59),
        datetime.max.replace(tzinfo=_MINUS_23_59),
    ],
    ids=["min-utc", "max-utc", "min+23:59", "min-23:59", "max+23:59", "max-23:59"],
)
def test_aware_datetime_limits_are_outside_the_supported_range(limit: datetime) -> None:
    assert _results(_NEW_YORK, limit) == _NOTHING


def test_naive_datetime_is_read_as_host_local_time(host_zone: str) -> None:
    # 23:00 in Tokyo is 09:00 in New York; 23:00 in UTC or Los Angeles is not.
    assert _NEW_YORK.matches(datetime(2026, 2, 6, 23, 0)) == (host_zone == "Asia/Tokyo")


@pytest.mark.parametrize("n", [2.0, 2.5, "2", None], ids=["2.0", "2.5", "str", "None"])
def test_next_n_from_rejects_a_count_that_is_not_an_integer(n: object) -> None:
    with pytest.raises(TypeError):
        _NEW_YORK.next_n_from(_NOW, cast(int, n))


@pytest.mark.parametrize("n", [0, -1, -(10**30)])
def test_next_n_from_is_empty_for_a_count_of_zero_or_less(n: int) -> None:
    assert _NEW_YORK.next_n_from(_NOW, n) == []


@pytest.mark.parametrize("n", [sys.maxsize, sys.maxsize + 1, 10**30])
def test_next_n_from_with_a_huge_count_returns_every_occurrence(n: int) -> None:
    schedule = Schedule.parse("every 1000 years on jan 1 at 00:00")
    years = [t.year for t in schedule.next_n_from(_NOW, n)]
    assert years == [2970, 3970, 4970, 5970, 6970, 7970, 8970, 9970]


_TOKYO_NOW = datetime(2026, 2, 6, 21, 0, tzinfo=ZoneInfo("Asia/Tokyo"))
_FIXED_OFFSET_NOW = datetime(2026, 2, 6, 21, 0, tzinfo=timezone(timedelta(hours=9)))


@pytest.mark.parametrize(
    ("schedule", "zone"),
    [(_NEW_YORK, ZoneInfo("America/New_York")), (_ZONELESS, ZoneInfo("UTC"))],
    ids=["new-york", "zoneless"],
)
@pytest.mark.parametrize("now", [_TOKYO_NOW, _FIXED_OFFSET_NOW], ids=["tokyo", "+09:00"])
def test_results_are_in_the_schedule_zone_whatever_zone_now_is_in(
    schedule: Schedule, zone: ZoneInfo, now: datetime
) -> None:
    later = now + timedelta(days=3)
    results = [
        schedule.next_from(now),
        schedule.previous_from(now),
        *schedule.next_n_from(now, 2),
        *islice(schedule.occurrences(now), 2),
        *schedule.between(now, later),
    ]
    assert results
    for result in results:
        assert isinstance(result, datetime)
        assert result.tzinfo is zone
