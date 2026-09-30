from __future__ import annotations

import json
import re
from datetime import datetime
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo

import pytest


def parse_zoned(s: str) -> datetime:
    m = re.match(r"^(.+)\[(.+)\]$", s)
    if not m:
        raise ValueError(f"expected format 'ISO[TZ]', got: {s}")
    iso_part, tz_name = m.group(1), m.group(2)
    tz = ZoneInfo(tz_name)
    dt = datetime.fromisoformat(iso_part)
    return dt.astimezone(tz)


def format_zoned(dt: datetime) -> str:
    tz = dt.tzinfo
    if tz is None:
        raise ValueError("datetime must be timezone-aware")
    tz_name = tz.key if hasattr(tz, "key") else str(tz)
    iso = dt.isoformat()
    return f"{iso}[{tz_name}]"


@pytest.fixture(scope="session")
def spec() -> dict[str, Any]:
    spec_path = Path(__file__).parent.parent.parent / "spec" / "tests.json"
    with open(spec_path) as f:
        data: dict[str, Any] = json.load(f)
    return data


@pytest.fixture(scope="session")
def default_now(spec: dict[str, Any]) -> datetime:
    return parse_zoned(spec["now"])
