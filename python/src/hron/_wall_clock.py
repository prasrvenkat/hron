"""A wall time a fall-back repeats takes its first pass (spec/README.md, "DST fall-back
(ambiguous times)").

Instants are UTC datetimes (spec/README.md, "Comparisons use instants"): datetimes sharing
one ZoneInfo compare by wall clock, which misorders the two passes of a fall-back overlap.
"""

from __future__ import annotations

from datetime import MINYEAR, UTC, date, datetime, time, timedelta
from typing import NamedTuple
from zoneinfo import ZoneInfo

from ._ast import TimeOfDay

MINUTES_PER_HOUR = 60

_SECOND = timedelta(seconds=1)

_EPOCH = datetime(1970, 1, 1, tzinfo=UTC)

_START_OF_TIME = datetime.min.replace(tzinfo=UTC)
_END_OF_TIME = datetime.max.replace(tzinfo=UTC)


def resolve_zone(name: str | None) -> ZoneInfo:
    return ZoneInfo(name) if name else ZoneInfo("UTC")


def fixed_time_on(d: date, t: time, zone: ZoneInfo) -> datetime | None:
    """spec/README.md, "DST spring-forward (gaps)". None beyond the years `datetime` can
    hold, which is outside the supported range."""
    # With fold=0 a wall time in a gap takes the offset from before the gap, which lands
    # it the gap's length later, and one a fall-back repeats takes its first pass.
    try:
        return datetime.combine(d, t, tzinfo=zone).astimezone(UTC)
    except OverflowError:
        return None


class Slot(NamedTuple):
    """`instant` is None when a spring-forward gap skips the slot (spec/README.md,
    "Interval slots in a spring-forward gap")."""

    wall: datetime
    instant: datetime | None

    @property
    def key(self) -> datetime:
        """The instant, or the instant its gap ends, so keys never decrease in wall-clock
        order. Found on demand: only a search's probes need it, and a gap's end costs a
        bisection."""
        if self.instant is not None:
            return self.instant
        try:
            return _gap_end(self.wall)
        except OverflowError:
            return _START_OF_TIME if self.wall.year == MINYEAR else _END_OF_TIME


def slot_on(d: date, minute: int, zone: ZoneInfo) -> Slot:
    wall = datetime.combine(d, time(*divmod(minute, MINUTES_PER_HOUR)), tzinfo=zone)
    try:
        # With fold=0 a wall time takes its first pass, and one in a gap the offset from
        # before the gap, which lands it past the gap, where the offset differs.
        instant = wall.astimezone(UTC)
        if instant.astimezone(zone).utcoffset() == wall.utcoffset():
            return Slot(wall, instant)
    except OverflowError:
        pass
    return Slot(wall, None)


def _gap_end(wall: datetime) -> datetime:
    """zoneinfo exposes no transitions, so the gap's end is found by bisection over whole
    seconds, on which transitions fall."""
    zone = wall.tzinfo
    before, after = wall.utcoffset(), wall.replace(fold=1).utcoffset()
    assert before is not None and after is not None
    seconds = (wall.replace(tzinfo=UTC) - _EPOCH) // _SECOND
    behind = seconds - after // _SECOND
    ended = seconds - before // _SECOND
    while ended - behind > 1:
        middle = (behind + ended) // 2
        # Not datetime.fromtimestamp, which fails before 1970 on some platforms.
        if (_EPOCH + middle * _SECOND).astimezone(zone).utcoffset() == after:
            ended = middle
        else:
            behind = middle
    return _EPOCH + ended * _SECOND


def civil_time(t: TimeOfDay) -> time:
    return time(t.hour, t.minute)


def minute_of_day(t: time) -> int:
    return t.hour * MINUTES_PER_HOUR + t.minute
