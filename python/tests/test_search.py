"""The search's footing: a slot in a spring-forward gap sits at the instant its gap ends, so
slot keys never decrease in wall-clock order, and one search finds where they part; and
matches stays within the supported range."""

from __future__ import annotations

from collections.abc import Iterator
from datetime import UTC, date, datetime, timedelta
from zoneinfo import ZoneInfo

import pytest

from hron import Schedule
from hron._eval import _partition_point
from hron._wall_clock import slot_on

# A gap per zone: its first wall time, the first wall time after it, and the instant it
# ends, as the zone's transition data gives them.
_GAPS = [
    pytest.param(
        "America/New_York",
        datetime(2026, 3, 8, 2, 0),
        datetime(2026, 3, 8, 3, 0),
        datetime(2026, 3, 8, 7, 0, tzinfo=UTC),
        id="new-york",
    ),
    pytest.param(
        "Australia/Lord_Howe",
        datetime(2026, 10, 4, 2, 0),
        datetime(2026, 10, 4, 2, 30),
        datetime(2026, 10, 3, 15, 30, tzinfo=UTC),
        id="lord-howe-half-hour",
    ),
    pytest.param(
        "Pacific/Apia",
        datetime(2011, 12, 30, 0, 0),
        datetime(2011, 12, 31, 0, 0),
        datetime(2011, 12, 30, 10, 0, tzinfo=UTC),
        id="apia-whole-day",
    ),
    pytest.param(
        "America/Nuuk",
        datetime(2026, 3, 28, 23, 0),
        datetime(2026, 3, 29, 0, 0),
        datetime(2026, 3, 29, 1, 0, tzinfo=UTC),
        id="nuuk-before-midnight",
    ),
    pytest.param(
        "America/Santiago",
        datetime(2026, 9, 6, 0, 0),
        datetime(2026, 9, 6, 1, 0),
        datetime(2026, 9, 6, 4, 0, tzinfo=UTC),
        id="santiago-at-midnight",
    ),
]


def _minutes(start: datetime, end: datetime) -> Iterator[datetime]:
    while start < end:
        yield start
        start += timedelta(minutes=1)


@pytest.mark.parametrize(("zone", "first_in_gap", "first_after", "ends_at"), _GAPS)
def test_a_slot_in_a_gap_has_no_instant_and_sits_where_the_gap_ends(
    zone: str, first_in_gap: datetime, first_after: datetime, ends_at: datetime
) -> None:
    for wall in _minutes(first_in_gap, first_after):
        slot = slot_on(wall.date(), wall.hour * 60 + wall.minute, ZoneInfo(zone))
        assert slot.instant is None, wall
        assert slot.key == ends_at, wall


@pytest.mark.parametrize(("zone", "first_in_gap", "first_after", "ends_at"), _GAPS)
def test_slot_keys_never_decrease_across_a_gap(
    zone: str, first_in_gap: datetime, first_after: datetime, ends_at: datetime
) -> None:
    around = timedelta(hours=3)
    walls = list(_minutes(first_in_gap - around, first_after + around))
    slots = [slot_on(wall.date(), wall.hour * 60 + wall.minute, ZoneInfo(zone)) for wall in walls]
    keys = [slot.key for slot in slots]
    assert keys == sorted(keys)
    for wall, slot in zip(walls, slots, strict=True):
        if not first_in_gap <= wall < first_after:
            assert slot.instant is not None and slot.key == slot.instant, wall
    assert slots[walls.index(first_after)].key == ends_at


@pytest.mark.parametrize(
    ("zone", "d"),
    [
        pytest.param("Asia/Tokyo", date(1, 1, 1), id="before-year-1"),
        pytest.param("America/New_York", date(9999, 12, 31), id="after-year-9999"),
    ],
)
def test_slots_past_the_years_datetime_holds_keep_keys_in_order(zone: str, d: date) -> None:
    slots = [slot_on(d, minute, ZoneInfo(zone)) for minute in range(0, 24 * 60, 30)]
    keys = [slot.key for slot in slots]
    assert keys == sorted(keys)
    assert any(slot.instant is None for slot in slots)
    assert any(slot.instant is not None for slot in slots)


def test_partition_point_finds_where_the_prefix_ends_from_any_start() -> None:
    for n in range(10):
        for parting in range(n + 1):
            for start in range(n + 1):
                probes: list[int] = []

                def earlier(i: int, parting: int = parting, probes: list[int] = probes) -> bool:
                    probes.append(i)
                    return i < parting

                assert _partition_point(n, earlier, start) == parting, (n, parting, start)
                assert all(0 <= i < n for i in probes), (n, parting, start, probes)
                assert len(probes) == len(set(probes)), (n, parting, start, probes)
                if parting in (start, start + 1):
                    assert len(probes) <= 2, (n, parting, start, probes)


def test_matches_is_false_for_a_minute_that_starts_before_the_supported_range() -> None:
    # Tokyo's offset in year 1 has seconds (+09:18:59), so the wall minute holding the
    # range's first instant starts before it.
    schedule = Schedule.parse("every day at 09:18 in Asia/Tokyo")
    assert not schedule.matches(datetime(1, 1, 2, tzinfo=UTC))


@pytest.mark.parametrize(
    ("expression", "instant"),
    [
        pytest.param(
            "every day at 00:01, 00:02 in Europe/London",
            datetime(1847, 12, 1, 0, 1, 15, tzinfo=UTC),
            id="london-lmt-to-gmt",
        ),
        pytest.param(
            "every day at 00:00, 00:01 in Europe/Amsterdam",
            datetime(1937, 6, 30, 22, 40, 28, tzinfo=UTC),
            id="amsterdam-1937",
        ),
    ],
)
def test_matches_drops_seconds_on_the_timeline_not_into_a_sub_minute_gap(
    expression: str, instant: datetime
) -> None:
    # The wall minute's start falls in a gap of under a minute; dropping seconds from the
    # wall time would land past the gap, on a listed time.
    assert not Schedule.parse(expression).matches(instant)
