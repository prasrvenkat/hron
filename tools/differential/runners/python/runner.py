import json
import re
import sys
from datetime import datetime
from itertools import islice
from typing import Any
from zoneinfo import ZoneInfo

from hron import HronError, Schedule


def parse_zoned(s: str) -> datetime:
    match = re.fullmatch(r"(.+)\[(.+)\]", s)
    assert match, s
    iso, zone = match.groups()
    return datetime.fromisoformat(iso).astimezone(ZoneInfo(zone))


def format_zoned(t: datetime | None) -> str | None:
    if t is None:
        return None
    return f"{t.isoformat()}[{getattr(t.tzinfo, 'key', t.tzinfo)}]"


def evaluate(case: dict[str, Any]) -> object:
    expr = case["expr"]
    if case["op"] == "fromCron":
        return str(Schedule.from_cron(expr))
    schedule = Schedule.parse(expr)
    match case["op"]:
        case "parse":
            return str(schedule)
        case "toCron":
            return schedule.to_cron()
        case "next":
            return format_zoned(schedule.next_from(parse_zoned(case["now"])))
        case "nextN":
            return [
                format_zoned(t) for t in schedule.next_n_from(parse_zoned(case["now"]), case["n"])
            ]
        case "prev":
            return format_zoned(schedule.previous_from(parse_zoned(case["now"])))
        case "matches":
            return schedule.matches(parse_zoned(case["datetime"]))
        case "between":
            times = schedule.between(parse_zoned(case["from"]), parse_zoned(case["to"]))
            return [format_zoned(t) for t in times]
        case "occurrences":
            times = islice(schedule.occurrences(parse_zoned(case["from"])), case["n"])
            return [format_zoned(t) for t in times]
    raise ValueError(f"unknown op {case['op']}")


def details(e: HronError) -> dict[str, Any]:
    return {
        "kind": e.kind,
        "message": str(e),
        "span": [e.span.start, e.span.end] if e.span else None,
        "suggestion": e.suggestion,
    }


def run(case: dict[str, Any]) -> dict[str, Any]:
    try:
        return {"ok": True, "result": evaluate(case)}
    except HronError as e:
        return {"ok": False, "error": details(e)}
    except Exception as e:
        return {"ok": False, "error": {"kind": "crash", "message": repr(e)}}


for line in sys.stdin:
    case = json.loads(line)
    print(json.dumps({"id": case["id"], **run(case)}), flush=True)
