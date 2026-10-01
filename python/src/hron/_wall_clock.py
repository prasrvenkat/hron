"""Wall-clock times on dates in a time zone. A wall time a fall-back repeats takes its
first pass (spec/README.md, "DST fall-back (ambiguous times)").

Instants are UTC datetimes (spec/README.md, "Comparisons use instants"): datetimes sharing
one ZoneInfo compare by wall clock, which misorders the two passes of a fall-back overlap.
"""

from __future__ import annotations

from datetime import UTC, date, datetime, time
from zoneinfo import ZoneInfo

from ._ast import TimeOfDay

MINUTES_PER_HOUR = 60


def resolve_zone(name: str | None) -> ZoneInfo:
    return ZoneInfo(name) if name else ZoneInfo("UTC")


def fixed_time_on(d: date, t: time, zone: ZoneInfo) -> datetime | None:
    """The instant `t` names on `d`, shifted forward by the gap's length when it falls in a
    spring-forward gap (spec/README.md, "DST spring-forward (gaps)"). None beyond the
    years `datetime` can hold, which is outside the supported range."""
    # With fold=0 a wall time in a gap takes the offset from before the gap, which lands
    # it the gap's length later, and one a fall-back repeats takes its first pass.
    try:
        return datetime.combine(d, t, tzinfo=zone).astimezone(UTC)
    except OverflowError:
        return None


def slot_on(d: date, minute: int, zone: ZoneInfo) -> datetime | None:
    """The instant of the interval slot `minute` minutes after midnight on `d`, or None
    when that wall time falls in a spring-forward gap (spec/README.md, "Interval slots
    in a spring-forward gap")."""
    wall = datetime.combine(d, time(*divmod(minute, MINUTES_PER_HOUR)))
    try:
        instant = wall.replace(tzinfo=zone).astimezone(UTC)
        # A wall time in a gap comes back shifted by the gap's length.
        exists = instant.astimezone(zone).replace(tzinfo=None) == wall
    except OverflowError:
        return None
    return instant if exists else None


def first_pass_wall_time(t: datetime) -> datetime:
    """`t`'s wall time read on the clock of a fall-back's first pass: later than its own
    by the overlap's length when `t` is in the second pass. A wall time's first pass is
    before `t` only when the wall time is before this."""
    first_pass = t.replace(fold=0).astimezone(UTC)
    return t.replace(tzinfo=None) + (t.astimezone(UTC) - first_pass)


def civil_time(t: TimeOfDay) -> time:
    return time(t.hour, t.minute)


def minute_of_day(t: time) -> int:
    return t.hour * MINUTES_PER_HOUR + t.minute
