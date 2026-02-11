from __future__ import annotations

import json
import re
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

import pytest


def parse_zoned(s: str) -> datetime:
    """Parse '2026-02-06T12:00:00+00:00[UTC]' into a timezone-aware datetime."""
    # Extract the IANA timezone name from brackets
    m = re.match(r"^(.+)\[(.+)\]$", s)
    if not m:
        raise ValueError(f"expected format 'ISO[TZ]', got: {s}")
    iso_part, tz_name = m.group(1), m.group(2)
    tz = ZoneInfo(tz_name)
    # Python 3.11+ fromisoformat handles offset
    dt = datetime.fromisoformat(iso_part)
    # Convert to the named timezone
    return dt.astimezone(tz)


def format_zoned(dt: datetime) -> str:
    """Format a timezone-aware datetime as '2026-02-06T12:00:00+00:00[TZ]'."""
    tz = dt.tzinfo
    if tz is None:
        raise ValueError("datetime must be timezone-aware")
    # Get the IANA key
    tz_name = tz.key if hasattr(tz, "key") else str(tz)
    iso = dt.isoformat()
    return f"{iso}[{tz_name}]"


@pytest.fixture(scope="session")
def spec() -> dict:  # type: ignore[type-arg]
    spec_path = Path(__file__).parent.parent.parent / "spec" / "tests.json"
    with open(spec_path) as f:
        return json.load(f)


@pytest.fixture(scope="session")
def default_now(spec: dict) -> datetime:  # type: ignore[type-arg]
    return parse_zoned(spec["now"])
