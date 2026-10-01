"""Schedules built from ScheduleData directly, which can hold what parse rejects."""

from __future__ import annotations

from datetime import UTC, datetime

import pytest

from hron import (
    DayFilterEvery,
    DayRepeat,
    DaysTarget,
    IntervalRepeat,
    IntervalUnit,
    MonthName,
    MonthRepeat,
    NamedUntil,
    Schedule,
    ScheduleData,
    ScheduleExpr,
    SingleDay,
    TimeOfDay,
    Weekday,
    WeekRepeat,
    YearDateTarget,
    YearRepeat,
)

NOW = datetime(2026, 2, 6, 12, tzinfo=UTC)
NINE = (TimeOfDay(9, 0),)


def _next_three(expr: ScheduleExpr) -> list[datetime]:
    return Schedule(ScheduleData(expr=expr)).next_n_from(NOW, 3)


@pytest.mark.parametrize("interval", [0, -3])
class TestIntervalBelowOneIsOne:
    def test_day_repeat(self, interval: int) -> None:
        expr = DayRepeat(interval, DayFilterEvery(), NINE)
        assert _next_three(expr) == _next_three(DayRepeat(1, DayFilterEvery(), NINE))

    def test_week_repeat(self, interval: int) -> None:
        expr = WeekRepeat(interval, (Weekday.MONDAY,), NINE)
        assert _next_three(expr) == _next_three(WeekRepeat(1, (Weekday.MONDAY,), NINE))

    def test_month_repeat(self, interval: int) -> None:
        target = DaysTarget((SingleDay(15),))
        expr = MonthRepeat(interval, target, NINE)
        assert _next_three(expr) == _next_three(MonthRepeat(1, target, NINE))

    def test_year_repeat(self, interval: int) -> None:
        target = YearDateTarget(MonthName.MAR, 1)
        expr = YearRepeat(interval, target, NINE)
        assert _next_three(expr) == _next_three(YearRepeat(1, target, NINE))

    def test_interval_repeat(self, interval: int) -> None:
        expr = IntervalRepeat(interval, IntervalUnit.MIN, TimeOfDay(13, 0), TimeOfDay(13, 2), None)
        assert _next_three(expr) == [
            datetime(2026, 2, 6, 13, minute, tzinfo=UTC) for minute in range(3)
        ]


def test_named_until_without_starting_resolves_from_the_epoch() -> None:
    data = ScheduleData(
        expr=DayRepeat(1, DayFilterEvery(), NINE),
        until=NamedUntil(MonthName.JAN, 15),
    )
    schedule = Schedule(data)
    assert schedule.previous_from(NOW) == datetime(1970, 1, 15, 9, tzinfo=UTC)
    assert schedule.next_from(datetime(1970, 1, 15, 9, tzinfo=UTC)) is None


def test_changed_data_is_seen() -> None:
    data = ScheduleData(expr=DayRepeat(1, DayFilterEvery(), NINE))
    schedule = Schedule(data)
    assert schedule.next_from(NOW) == datetime(2026, 2, 7, 9, tzinfo=UTC)
    data.timezone = "Asia/Tokyo"
    assert schedule.next_from(NOW) == datetime(2026, 2, 7, 0, tzinfo=UTC)
