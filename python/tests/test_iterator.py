"""Iterator-specific tests for `occurrences()` and `between()` methods.

These tests verify Python-specific iterator behavior beyond conformance tests:
- Laziness (generators don't evaluate eagerly)
- Early termination
- Generator protocol (__iter__ and __next__)
- Integration with itertools
- Memory efficiency patterns
"""

from __future__ import annotations

import itertools
from datetime import datetime
from typing import Iterator
from zoneinfo import ZoneInfo

import pytest

from hron import Schedule


def parse_zoned(s: str) -> datetime:
    """Parse '2026-02-06T12:00:00+00:00[UTC]' into a timezone-aware datetime."""
    import re

    m = re.match(r"^(.+)\[(.+)\]$", s)
    if not m:
        raise ValueError(f"expected format 'ISO[TZ]', got: {s}")
    iso_part, tz_name = m.group(1), m.group(2)
    tz = ZoneInfo(tz_name)
    dt = datetime.fromisoformat(iso_part)
    return dt.astimezone(tz)


# =============================================================================
# Laziness Tests
# =============================================================================


class TestLaziness:
    def test_occurrences_is_lazy(self) -> None:
        """An unbounded schedule should not hang or OOM when creating the iterator."""
        schedule = Schedule.parse("every day at 09:00 in UTC")
        from_dt = parse_zoned("2026-02-01T00:00:00+00:00[UTC]")

        # Creating the iterator should be instant (lazy)
        it = schedule.occurrences(from_dt)

        # Taking just 1 should work without evaluating the rest
        first = list(itertools.islice(it, 1))
        assert len(first) == 1

    def test_between_is_lazy(self) -> None:
        schedule = Schedule.parse("every day at 09:00 in UTC")
        from_dt = parse_zoned("2026-02-01T00:00:00+00:00[UTC]")
        to_dt = parse_zoned("2026-12-31T23:59:00+00:00[UTC]")

        # Creating the iterator should be instant
        it = schedule.between(from_dt, to_dt)

        # Taking just 3 should not evaluate all ~330 days
        first_three = list(itertools.islice(it, 3))
        assert len(first_three) == 3


# =============================================================================
# Early Termination Tests
# =============================================================================


class TestEarlyTermination:
    def test_occurrences_early_termination_with_islice(self) -> None:
        schedule = Schedule.parse("every day at 09:00 in UTC")
        from_dt = parse_zoned("2026-02-01T00:00:00+00:00[UTC]")

        results = list(itertools.islice(schedule.occurrences(from_dt), 5))

        assert len(results) == 5

    def test_occurrences_early_termination_with_takewhile(self) -> None:
        schedule = Schedule.parse("every day at 09:00 in UTC")
        from_dt = parse_zoned("2026-02-01T00:00:00+00:00[UTC]")
        cutoff = parse_zoned("2026-02-05T00:00:00+00:00[UTC]")

        results = list(itertools.takewhile(lambda dt: dt < cutoff, schedule.occurrences(from_dt)))

        # Feb 1, 2, 3, 4 at 09:00 (4 occurrences before Feb 5 00:00)
        assert len(results) == 4

    def test_occurrences_early_termination_with_break(self) -> None:
        schedule = Schedule.parse("every day at 09:00 in UTC")
        from_dt = parse_zoned("2026-02-01T00:00:00+00:00[UTC]")

        results = []
        for dt in schedule.occurrences(from_dt):
            results.append(dt)
            if len(results) >= 5:
                break

        assert len(results) == 5

    def test_occurrences_find_with_next(self) -> None:
        schedule = Schedule.parse("every day at 09:00 in UTC")
        from_dt = parse_zoned("2026-02-01T00:00:00+00:00[UTC]")

        # Find the first Saturday occurrence
        saturday = next(
            (dt for dt in schedule.occurrences(from_dt) if dt.weekday() == 5),
            None,
        )

        # Feb 7, 2026 is a Saturday
        assert saturday is not None
        assert saturday.day == 7


# =============================================================================
# Iterator Protocol Tests
# =============================================================================


class TestIteratorProtocol:
    def test_occurrences_is_iterator(self) -> None:
        schedule = Schedule.parse("every day at 09:00 in UTC")
        from_dt = parse_zoned("2026-02-01T00:00:00+00:00[UTC]")

        it = schedule.occurrences(from_dt)

        # Check it's an iterator
        assert hasattr(it, "__iter__")
        assert hasattr(it, "__next__")

    def test_between_is_iterator(self) -> None:
        schedule = Schedule.parse("every day at 09:00 in UTC")
        from_dt = parse_zoned("2026-02-01T00:00:00+00:00[UTC]")
        to_dt = parse_zoned("2026-02-05T00:00:00+00:00[UTC]")

        it = schedule.between(from_dt, to_dt)

        assert hasattr(it, "__iter__")
        assert hasattr(it, "__next__")

    def test_manual_next_calls(self) -> None:
        schedule = Schedule.parse("every day at 09:00 in UTC")
        from_dt = parse_zoned("2026-02-01T00:00:00+00:00[UTC]")

        it = schedule.occurrences(from_dt)

        first = next(it)
        assert first.day == 1

        second = next(it)
        assert second.day == 2

        third = next(it)
        assert third.day == 3

    def test_stopiteration_on_exhaustion(self) -> None:
        schedule = Schedule.parse("on 2026-02-14 at 14:00 in UTC")
        from_dt = parse_zoned("2026-02-01T00:00:00+00:00[UTC]")

        it = schedule.occurrences(from_dt)

        # Should yield one occurrence
        first = next(it)
        assert first.day == 14

        # Then raise StopIteration
        with pytest.raises(StopIteration):
            next(it)


# =============================================================================
# Itertools Integration Tests
# =============================================================================


class TestItertoolsIntegration:
    def test_works_with_filter(self) -> None:
        schedule = Schedule.parse("every day at 09:00 in UTC")
        from_dt = parse_zoned("2026-02-01T00:00:00+00:00[UTC]")

        # Filter to only weekends
        two_weeks = itertools.islice(schedule.occurrences(from_dt), 14)
        weekends = filter(lambda dt: dt.weekday() >= 5, two_weeks)
        results = list(weekends)

        # 2 weekends in 2 weeks = 4 days
        assert len(results) == 4

    def test_works_with_map(self) -> None:
        schedule = Schedule.parse("every day at 09:00 in UTC")
        from_dt = parse_zoned("2026-02-01T00:00:00+00:00[UTC]")

        # Map to just the day number
        days = list(map(lambda dt: dt.day, itertools.islice(schedule.occurrences(from_dt), 5)))

        assert days == [1, 2, 3, 4, 5]

    def test_works_with_enumerate(self) -> None:
        schedule = Schedule.parse("every day at 09:00 in UTC")
        from_dt = parse_zoned("2026-02-01T00:00:00+00:00[UTC]")

        enumerated = list(enumerate(itertools.islice(schedule.occurrences(from_dt), 3)))

        assert len(enumerated) == 3
        assert enumerated[0][0] == 0
        assert enumerated[1][0] == 1
        assert enumerated[2][0] == 2

    def test_works_with_dropwhile(self) -> None:
        schedule = Schedule.parse("every day at 09:00 in UTC")
        from_dt = parse_zoned("2026-02-01T00:00:00+00:00[UTC]")

        # Skip until Feb 5, then take 3
        after_feb5 = itertools.dropwhile(lambda dt: dt.day < 5, schedule.occurrences(from_dt))
        results = list(itertools.islice(after_feb5, 3))

        assert len(results) == 3
        assert results[0].day == 5
        assert results[1].day == 6
        assert results[2].day == 7


# =============================================================================
# Collect Patterns
# =============================================================================


class TestCollectPatterns:
    def test_occurrences_collect_to_list(self) -> None:
        schedule = Schedule.parse("every day at 09:00 until 2026-02-05 in UTC")
        from_dt = parse_zoned("2026-02-01T00:00:00+00:00[UTC]")

        results = list(schedule.occurrences(from_dt))

        assert len(results) == 5  # Feb 1-5

    def test_between_collect_to_list(self) -> None:
        schedule = Schedule.parse("every day at 09:00 in UTC")
        from_dt = parse_zoned("2026-02-01T00:00:00+00:00[UTC]")
        to_dt = parse_zoned("2026-02-07T23:59:00+00:00[UTC]")

        results = list(schedule.between(from_dt, to_dt))

        assert len(results) == 7

    def test_between_works_with_len_via_list(self) -> None:
        schedule = Schedule.parse("every day at 09:00 in UTC")
        from_dt = parse_zoned("2026-02-01T00:00:00+00:00[UTC]")
        to_dt = parse_zoned("2026-02-10T23:59:00+00:00[UTC]")

        # Count occurrences in range
        count = len(list(schedule.between(from_dt, to_dt)))

        # Feb 1-10 inclusive = 10 days
        assert count == 10


# =============================================================================
# For Loop Patterns
# =============================================================================


class TestForLoopPatterns:
    def test_occurrences_for_loop_with_break(self) -> None:
        schedule = Schedule.parse("every day at 09:00 in UTC")
        from_dt = parse_zoned("2026-02-01T00:00:00+00:00[UTC]")

        count = 0
        for dt in schedule.occurrences(from_dt):
            count += 1
            if dt.day >= 5:
                break

        assert count == 5

    def test_between_for_loop(self) -> None:
        schedule = Schedule.parse("every day at 09:00 in UTC")
        from_dt = parse_zoned("2026-02-01T00:00:00+00:00[UTC]")
        to_dt = parse_zoned("2026-02-03T23:59:00+00:00[UTC]")

        days = []
        for dt in schedule.between(from_dt, to_dt):
            days.append(dt.day)

        assert days == [1, 2, 3]


# =============================================================================
# Edge Cases
# =============================================================================


class TestEdgeCases:
    def test_occurrences_empty_when_past_until(self) -> None:
        schedule = Schedule.parse("every day at 09:00 until 2026-01-01 in UTC")
        from_dt = parse_zoned("2026-02-01T00:00:00+00:00[UTC]")

        results = list(itertools.islice(schedule.occurrences(from_dt), 10))

        assert len(results) == 0

    def test_between_empty_range(self) -> None:
        schedule = Schedule.parse("every day at 09:00 in UTC")
        from_dt = parse_zoned("2026-02-01T12:00:00+00:00[UTC]")
        to_dt = parse_zoned("2026-02-01T13:00:00+00:00[UTC]")

        results = list(schedule.between(from_dt, to_dt))

        assert len(results) == 0

    def test_occurrences_single_date_terminates(self) -> None:
        schedule = Schedule.parse("on 2026-02-14 at 14:00 in UTC")
        from_dt = parse_zoned("2026-02-01T00:00:00+00:00[UTC]")

        results = list(itertools.islice(schedule.occurrences(from_dt), 100))

        assert len(results) == 1


# =============================================================================
# Timezone Handling
# =============================================================================


class TestTimezoneHandling:
    def test_occurrences_preserves_timezone(self) -> None:
        schedule = Schedule.parse("every day at 09:00 in America/New_York")
        from_dt = parse_zoned("2026-02-01T00:00:00-05:00[America/New_York]")

        results = list(itertools.islice(schedule.occurrences(from_dt), 3))

        for dt in results:
            assert dt.tzinfo is not None
            # Check the IANA key
            assert hasattr(dt.tzinfo, "key")
            assert dt.tzinfo.key == "America/New_York"

    def test_between_handles_dst_transition(self) -> None:
        # March 8, 2026 is DST spring forward in America/New_York
        # 2:00 AM springs forward to 3:00 AM, so 02:30 shifts to 03:30
        schedule = Schedule.parse("every day at 02:30 in America/New_York")
        from_dt = parse_zoned("2026-03-07T00:00:00-05:00[America/New_York]")
        to_dt = parse_zoned("2026-03-10T00:00:00-04:00[America/New_York]")

        results = list(schedule.between(from_dt, to_dt))

        # Mar 7 at 02:30, Mar 8 at 03:30 (shifted), Mar 9 at 02:30
        assert len(results) == 3
        assert results[0].hour == 2  # Mar 7 02:30
        assert results[1].hour == 3  # Mar 8 03:30 (shifted due to DST)
        assert results[2].hour == 2  # Mar 9 02:30


# =============================================================================
# Multiple Times Per Day
# =============================================================================


class TestMultipleTimesPerDay:
    def test_occurrences_multiple_times_per_day(self) -> None:
        schedule = Schedule.parse("every day at 09:00, 12:00, 17:00 in UTC")
        from_dt = parse_zoned("2026-02-01T00:00:00+00:00[UTC]")

        results = list(itertools.islice(schedule.occurrences(from_dt), 9))  # 3 days worth

        assert len(results) == 9
        # First day: 09:00, 12:00, 17:00
        assert results[0].hour == 9
        assert results[1].hour == 12
        assert results[2].hour == 17


# =============================================================================
# Complex Iterator Chains
# =============================================================================


class TestComplexIteratorChains:
    def test_complex_chain(self) -> None:
        schedule = Schedule.parse("every day at 09:00 in UTC")
        from_dt = parse_zoned("2026-02-01T00:00:00+00:00[UTC]")

        # Complex chain: skip weekends, take first 5 weekdays, get their day numbers
        two_weeks = itertools.islice(schedule.occurrences(from_dt), 14)
        weekdays = filter(lambda dt: dt.weekday() < 5, two_weeks)
        first_5 = itertools.islice(weekdays, 5)
        days = [dt.day for dt in first_5]

        # Feb 2026: 2,3,4,5,6 are Mon-Fri
        assert days == [2, 3, 4, 5, 6]
