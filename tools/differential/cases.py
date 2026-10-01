"""Generates the differential cases. The output depends only on SEED and the
system timezone database, never on the wall clock."""

import random
import re
from collections import Counter
from datetime import UTC, datetime, timedelta
from zoneinfo import ZoneInfo

SEED = 20260930

DST_ZONES = [
    "America/New_York",
    "Europe/London",
    "Europe/Berlin",
    "Australia/Sydney",
    "Australia/Lord_Howe",
    "America/Santiago",
    "America/St_Johns",
    "America/Nuuk",
]
FIXED_ZONES = [None, "UTC", "Etc/GMT+12", "Etc/GMT-14"]
OTHER_ZONES = ["Asia/Kolkata", "Asia/Kathmandu", "Pacific/Kiritimati", "Pacific/Apia"]

TIMES = ["00:00", "09:00", "23:59", "9:30, 17:45", "01:30, 02:30"]
BODIES = [
    "every day at {t}",
    "every weekday at {t}",
    "every weekend at {t}",
    "every mon, wed, fri at {t}",
    "every sunday at {t}",
    "every 1 day at {t}",
    "every 3 days at {t}",
    "every week on monday at {t}",
    "every 2 weeks on tue, sat at {t}",
    "every 5 weeks on sunday at {t}",
    "every month on the 1st at {t}",
    "every month on the 29th, 30th at {t}",
    "every month on the 31st at {t}",
    "every month on the 1st to 3rd, 28th to 31st at {t}",
    "every month on the last day at {t}",
    "every month on the last weekday at {t}",
    "every month on the nearest weekday to 1st at {t}",
    "every month on the nearest weekday to 31st at {t}",
    "every month on the next nearest weekday to 30th at {t}",
    "every month on the previous nearest weekday to 1st at {t}",
    "every month on the first monday at {t}",
    "every month on the fifth friday at {t}",
    "every month on the last sunday at {t}",
    "every 2 months on the 31st at {t}",
    "every 3 months on the nearest weekday to 15th at {t}",
    "every year on dec 31 at {t}",
    "every year on the last friday of march at {t}",
    "every year on the last weekday of december at {t}",
    "on 2026-03-29 at {t}",
    "on dec 31 at {t}",
    "every 30 min from 09:00 to 17:00",
    "every 45 min from 00:00 to 04:00",
    "every 1 min from 23:58 to 23:59",
    "every 7 minutes from 00:00 to 23:59",
    "every 90 min from 01:00 to 03:00 on mon, fri",
    "every 2 hours from 00:00 to 23:59 on weekend",
    "every 1 hour from 09:00 to 09:00",
    "every 5 hrs from 01:30 to 22:00 on weekday",
]
# These can reach past 2037, where the offsets of zones with DST depend on each
# platform's tz data, or before 1936, where zones used local mean time, which is not
# a whole number of minutes (spec/README.md, "Timezone data"). So they run in FIXED_ZONES.
FAR_BODIES = [
    "every 400 days at {t}",
    "every 13 months on the last day at {t}",
    "every year on feb 29 at {t}",
    "on feb 29 at {t}",
    "every 4 years on feb 29 at {t}",
    "every 3 years on the 31st of may at {t}",
    "every 11 years on the fifth sunday of february at {t}",
]
EXCEPTS = ["except dec 25", "except feb 29, 2026-03-01", "except 2026-03-29"]
UNTILS = ["until 2026-12-31", "until 2027-02-28"]
NAMED_UNTILS = ["until mar 1"]
STARTINGS = [
    "starting 2026-02-28",
    "starting 2024-02-29",
    "starting 1969-12-31",
    "starting 2026-03-30",
]
DURINGS = ["during feb", "during mar, oct, nov", "during dec, jan"]

NOWS = [
    datetime(2026, 2, 6, 12, tzinfo=UTC),
    datetime(2026, 2, 28, 23, 59, tzinfo=UTC),
    datetime(2026, 3, 29, 0, 30, tzinfo=UTC),
    datetime(2026, 10, 25, 1, 30, tzinfo=UTC),
    datetime(2024, 2, 29, 12, tzinfo=UTC),
    datetime(2025, 12, 31, 23, 59, 30, tzinfo=UTC),
    datetime(1969, 12, 31, 23, 59, tzinfo=UTC),
    datetime(2030, 7, 1, tzinfo=UTC),
]

EDGE_EXPRS = [
    "every day at 00:00",
    "every day at 23:59",
    "every 1 min from 00:00 to 23:59",
    "every 2147483647 min from 00:00 to 23:59",
    "every year on jan 1 at 00:00",
    "every year on dec 29 at 23:59",
    "every month on the last day at 23:59",
    "on 9999-12-29 at 23:59",
    "on 9999-12-30 at 00:00",
    "on 0001-01-02 at 00:00",
    "on 0001-01-01 at 23:59",
    "every 9000 years on jan 1 at 09:00",
    "every 8000 years on jan 1 at 09:00",
    "every 2147483647 days at 00:00",
    "every 2147483647 weeks on monday at 00:00",
    "every 2147483647 months on the 1st at 00:00",
    "every 2147483647 years on jan 1 at 00:00",
    "every 7 days at 12:00 starting 0001-01-01",
    "every day at 12:00 until 9999-12-31",
    "every week on sunday at 12:00 starting 9999-12-25",
]
# Schedules that fire rarely, never, or only near the search horizon or the
# range's ends, where each language's horizon and stop rule are tested.
SPARSE_EXPRS = [
    "every 400 years on jan 1 at 00:00 except 2400-01-01 starting 2000-01-01",
    "every 400 years on jan 1 at 00:00 except 2400-01-01, 2800-01-01 starting 2000-01-01",
    "every 100 years on feb 29 at 09:00 starting 2000-01-01",
    "every 2 years on feb 29 at 09:00 starting 2025-01-01",
    "every 2 years on feb 29 at 09:00 starting 2024-01-01",
    "every year on feb 29 at 09:00 except feb 29",
    "every month on the 31st at 09:00 during feb",
    "every month on the 30th at 09:00 during feb, apr",
    "every 7 years on the fifth sunday of february at 09:00",
    "every 11 years on the fifth sunday of february at 09:00 starting 1900-01-01",
    "every 146097 days at 09:00",
    "every 146096 days at 09:00 starting 2000-01-01",
    "every 2147483647 days at 09:00 starting 2026-01-01",
    "every 4800 months on the 1st at 09:00",
    "every 20871 weeks on monday at 09:00",
    "every day at 09:00 until feb 29 starting 2097-03-01",
    "every day at 09:00 until feb 29 starting 9997-03-01",
    "every day at 09:00 until mar 1 starting 9999-03-02",
]
SPARSE_NOWS = [
    datetime(1, 1, 2, tzinfo=UTC),
    datetime(1999, 12, 31, tzinfo=UTC),
    datetime(2026, 2, 6, 12, tzinfo=UTC),
    datetime(2399, 6, 1, tzinfo=UTC),
    datetime(9990, 1, 1, tzinfo=UTC),
]
SPARSE_MATCHES = [
    datetime(2000, 1, 1, tzinfo=UTC),
    datetime(2096, 2, 29, 9, tzinfo=UTC),
    datetime(2400, 1, 1, tzinfo=UTC),
]
EDGE_ZONES = ["", " in Etc/GMT-14", " in Etc/GMT+12"]
EARLIEST = datetime(1, 1, 1, tzinfo=UTC)
# The latest instant that jiff, and so the Rust runner, can represent.
LATEST = datetime(9999, 12, 30, 22, tzinfo=UTC)
BEFORE_RANGE = datetime(1, 1, 1, 23, 59, tzinfo=UTC)
RANGE_FIRST = datetime(1, 1, 2, tzinfo=UTC)
RANGE_LAST = datetime(9999, 12, 29, 23, 59, tzinfo=UTC)
AFTER_RANGE = datetime(9999, 12, 30, tzinfo=UTC)
RANGE_EDGES = [BEFORE_RANGE, RANGE_FIRST, RANGE_LAST, AFTER_RANGE]
EDGE_NOWS = [BEFORE_RANGE, RANGE_FIRST, datetime(1970, 1, 1, tzinfo=UTC), RANGE_LAST, AFTER_RANGE]

INVALID = [
    "",
    "every",
    "every day",
    "every day at 24:00",
    "every day at 23:60",
    "every day at 9:5",
    "every day at 09:00,",
    "every day at 09:00, 09:00",
    " every day at 09:00",
    "every  day at 09:00",
    "every day at 09:00\n",
    "every day at 09:00\tin UTC",
    "every day at \N{ARABIC-INDIC DIGIT NINE}:00",
    "EVERY DAY AT 09:00 IN UTC",
    "every 0 days at 09:00",
    "every 2147483648 days at 09:00",
    "every 0 hours from 09:00 to 17:00",
    "every 25 hours from 00:00 to 23:59",
    "every 1441 min from 00:00 to 23:59",
    "every 1 min from 00:00 to 00:00",
    "every 30 min from 17:00 to 09:00",
    "every mon, mon at 09:00",
    "every 2 weekdays at 09:00",
    "every week on weekday at 09:00",
    "every month on the 0th at 09:00",
    "every month on the 32nd at 09:00",
    "every month on the 31st, 1st at 09:00",
    "every month on the 1st to 1st at 09:00",
    "every month on the 15th to 1st at 09:00",
    "every month on the 1th at 09:00",
    "every month on the sixth monday at 09:00",
    "every month on the last day, 1st at 09:00",
    "every month on the nearest weekday to 32nd at 09:00",
    "every year on feb 30 at 09:00",
    "every year on the 30th of february at 09:00",
    "every year on the fifth monday of feb at 09:00",
    "on 2026-02-29 at 09:00",
    "on 0000-01-01 at 09:00",
    "on 10000-01-01 at 09:00",
    "on 2026-1-1 at 09:00",
    "every day at 09:00 starting 2026-02-29",
    "every day at 09:00 until dec 31",
    "every day at 09:00 until feb 29 starting 2026-01-01",
    "every day at 09:00 until 2026-01-01 starting 2027-01-01",
    "every day at 09:00 except dec 25, dec 25",
    "every day at 09:00 during jan, jan",
    "every day at 09:00 in UTC except dec 25",
    "every day at 09:00 during jan until 2027-12-31",
    "every day at 09:00 in EST",
    "every day at 09:00 in Z",
    "every day at 09:00 in +05:30",
    "every day at 09:00 in GMT0",
    "every day at 09:00 in Etc/GMT+15",
    "every day at 09:00 in Etc/GMT-0",
    "every day at 09:00 in Etc/UTC",
    "every day at 09:00 in us/eastern",
    "every day at 09:00 in AMERICA/NEW_YORK",
    "every day at 09:00 in Asia/Calcutta",
    "every day at 09:00 in Europe/Kyiv",
    "every day at 09:00 in Europe/Kiev",
    "every day at 09:00 in Europe/\N{KELVIN SIGN}yiv",
    "every day at 09:00 in america/argentina/buenos_aires",
    "every day at 09:00 in posix/America/New_York",
    "every day at 09:00 in SystemV/EST5",
    "every day at 99999999999999999999:00",
    "every 99999999999 days at 09:00",
    "every 99999999999999999999 days at 09:00",
]
MUTATION_TOKENS = [
    "0", "1", "31", "32", "2147483647", "2147483648", "24:00", "00:00", "9:5", "feb", "29", "last",
    "first", "to", "on", "at", "the", ",", "every", "in", "UTC", "2026-02-29", "0001-01-01",
    "weekday", "nearest", "next", "except", "until", "starting", "during", "of", "day", "days",
    "min", "hours",
]  # fmt: skip

CRONS = [
    "0 9 * * *", "*/15 * * * *", "0 9 * * 1-5", "0 0 1 * *", "0 9 L * *", "0 9 LW * *",
    "0 9 15W * *", "0 17 31W * *", "0 9 1W * *", "0 9 * * 5L", "0 9 * * 1#2", "0 9 * * SUN#1",
    "@yearly", "@annually", "@monthly", "@weekly", "@daily", "@midnight", "@hourly", "@reboot",
    "@every 5m", "0 9 * * 7", "0 9 * * 0-7", "0 9 * * 7-1", "0 9 * * 1-7", "0 9 * * MON-SUN",
    "0 9 * * sun-sat", "0 0 29 2 *", "0 9 31 4 *", "0 9 L 2 *", "0 9 1,L * *", "0 9 L-2 * *",
    "0 9 W * *", "0 9 0W * *", "0 9 32W * *", "0 9 15W,L * *", "0 9 1 * 1", "0 9 */40 * *",
    "*/60 * * * *", "*/59 * * * *", "0 */25 * * *", "5-10 * * * *", "0 9 1-31/31 * *",
    "0 9 * * L", "0 9 LW 2 *", "0 9 * * 5#3,1#1", "0 9 * * 5L,1", "0 9 * * 1#5", "0 24 * * *",
    "59 23 31 12 *", "0  9 * * *", "0\t9 * * *", " 0 9 * * * ", "0 09 * * *", "00 9 * * *",
    "0 9 * * 01", "-1 9 * * *", "0 9 * * 1,", "0 9 * * ,1", "0 9 1-5/0 * *", "0 9 1/2 * *",
    "0 9 * * 1/2", "0 9 * * 5/2", "0 9 * 2-1 *", "0 9 * *", "0 9 * * * *", "0 9 1 13 *",
    "0 9 1 0 *", "0 9 * * 8", "0 9 * * FOO", "0 9 * * 1#0", "0 9 * * 1#6", "*/0 * * * *",
    "0 9 5-1 * *", "0 9 1 JAN,jul *", "0 9 ? * ?", "0 9 15 * ?", "0-30/10 9 * * *",
    "0 9-17/2 * * *", "0 9 1 */3 *", "0 9 * * */2", "0 9 1-31/2 * *", "0 9 5-20/3 * *",
]  # fmt: skip
CRON_FIELDS = [
    ["0", "30", "*/15", "0-30/10", "5,35", "*", "59"],
    ["9", "*", "*/2", "9-17", "9-17/2", "0,12", "23"],
    ["*", "1", "15", "31", "L", "LW", "15W", "1-5", "1-31/10", "?", "29"],
    ["*", "1", "JAN", "1-3", "*/3", "2", "dec"],
    ["*", "1-5", "MON", "0", "7", "5L", "1#2", "SUN#1", "?", "1-5/2", "sat,sun"],
]

WEEKDAYS = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
MONTHS = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
MINUTE = timedelta(minutes=1)
DAY = timedelta(days=1)


class Cases(list):
    """Case objects with ids numbered within each family, so that adding a family
    leaves the ids of the others unchanged."""

    def __init__(self) -> None:
        super().__init__()
        self.counts = Counter()

    def add(self, family: str, op: str, expr: str, args: dict | None = None) -> None:
        self.counts[family] += 1
        case_id = f"{family}-{self.counts[family]}"
        self.append({"id": case_id, "op": op, "expr": expr, **(args or {})})


def meant_to_parse(case: dict) -> bool:
    """Whether the generator meant the case's expression to parse."""
    return case["op"] != "fromCron" and not case["id"].startswith(("invalid-", "mutant-"))


def generate() -> list[dict]:
    rng = random.Random(SEED)
    cases = Cases()
    add_syntax(cases, rng)
    add_eval(cases, rng)
    add_dst(cases)
    add_range(cases)
    add_sparse(cases)
    add_cron(cases, rng)
    return cases


def stamp(instant: datetime, zone: str | None = None) -> str:
    """The spec's canonical form, YYYY-MM-DDTHH:MM:SS+HH:MM[Zone]."""
    zone = zone or "UTC"
    return f"{instant.astimezone(ZoneInfo(zone)).isoformat()}[{zone}]"


def hhmm(wall: datetime) -> str:
    return wall.strftime("%H:%M")


def ordinal(n: int) -> str:
    suffix = "th" if 11 <= n % 100 <= 13 else {1: "st", 2: "nd", 3: "rd"}.get(n % 10, "th")
    return f"{n}{suffix}"


def random_schedule(rng: random.Random) -> tuple[str, str | None]:
    body = rng.choice(BODIES + FAR_BODIES)
    parts = [body.format(t=rng.choice(TIMES))]
    starting = rng.choice(STARTINGS) if rng.random() < 0.3 else None
    if rng.random() < 0.3:
        parts.append(rng.choice(EXCEPTS))
    if rng.random() < 0.3:
        until = rng.choice(UNTILS + NAMED_UNTILS)
        parts.append(until)
        if until in NAMED_UNTILS:
            starting = starting or STARTINGS[0]
    if starting:
        parts.append(starting)
    if rng.random() < 0.3:
        parts.append(rng.choice(DURINGS))
    zone = rng.choice(FIXED_ZONES if body in FAR_BODIES else FIXED_ZONES + OTHER_ZONES + DST_ZONES)
    if zone:
        parts.append(f"in {zone}")
    return " ".join(parts), zone


def mutate(expr: str, rng: random.Random) -> str:
    tokens = expr.split(" ")
    i = rng.randrange(len(tokens))
    match rng.randrange(6):
        case 0:
            del tokens[i]
        case 1:
            tokens.insert(i, tokens[i])
        case 2:
            tokens[i : i + 2] = reversed(tokens[i : i + 2])
        case 3:
            tokens[i] = rng.choice(MUTATION_TOKENS)
        case 4:
            tokens.insert(i, rng.choice(MUTATION_TOKENS))
        case 5:
            tokens = tokens[:i]
    return " ".join(tokens)


def add_syntax(cases: Cases, rng: random.Random) -> None:
    for expr in INVALID:
        cases.add("invalid", "parse", expr)
    mutants = {mutate(random_schedule(rng)[0], rng) for _ in range(1500)}
    for expr in sorted(mutants):
        cases.add("mutant", "parse", expr)
        cases.add("mutant", "next", expr, {"now": stamp(NOWS[0])})


def add_eval(cases: Cases, rng: random.Random) -> None:
    for _ in range(1500):
        expr, zone = random_schedule(rng)
        cases.add("eval", "parse", expr)
        cases.add("eval", "toCron", expr)
        add_evaluations(cases, rng, expr, zone)


def add_evaluations(cases: Cases, rng: random.Random, expr: str, zone: str | None) -> None:
    """Evaluations of `expr` around NOWS, with times written in its zone or in UTC.
    A zoneless schedule runs in UTC, so it gets times written in another zone
    instead, which must not change its answers."""
    written_in = rng.choice([zone or rng.choice(DST_ZONES + OTHER_ZONES), None])

    def at(instant: datetime) -> str:
        return stamp(instant, written_in)

    for now in rng.sample(NOWS, 2):
        cases.add("eval", "next", expr, {"now": at(now)})
    for now in rng.sample(NOWS, 2):
        cases.add("eval", "prev", expr, {"now": at(now)})
    cases.add("eval", "nextN", expr, {"now": at(rng.choice(NOWS)), "n": 5})
    cases.add("eval", "occurrences", expr, {"from": at(rng.choice(NOWS)), "n": 5})
    start = rng.choice(NOWS)
    end = start + (2 * DAY if " from " in expr else 40 * DAY)
    cases.add("eval", "between", expr, {"from": at(start), "to": at(end)})
    for _ in range(2):
        day = (rng.choice(NOWS) + rng.randrange(-3, 30) * DAY).date()
        hour, minute = map(int, rng.choice(re.findall(r"(\d+):(\d\d)", expr)))
        wall = datetime(day.year, day.month, day.day, hour, minute, rng.choice([0, 30]))
        instant = wall.replace(tzinfo=ZoneInfo(zone or "UTC")).astimezone(UTC)
        cases.add("eval", "matches", expr, {"datetime": at(instant)})


def offset(instant: datetime, tz: ZoneInfo) -> timedelta:
    utcoffset = instant.astimezone(tz).utcoffset()
    assert utcoffset is not None
    return utcoffset


def transitions(zone: str, year: int) -> list[datetime]:
    """The instants in `year` at which the zone's UTC offset changes."""
    tz = ZoneInfo(zone)
    found = []
    hour = datetime(year, 1, 1, tzinfo=UTC)
    while hour.year == year:
        later = hour + timedelta(hours=1)
        if offset(hour, tz) != offset(later, tz):
            minute = hour
            while offset(minute, tz) == offset(hour, tz):
                minute += MINUTE
            found.append(minute)
        hour = later
    return found


def add_dst(cases: Cases) -> None:
    for zone, year in [(zone, 2026) for zone in DST_ZONES] + [("Pacific/Apia", 2011)]:
        tz = ZoneInfo(zone)
        for change in transitions(zone, year):
            before, after = offset(change - MINUTE, tz), offset(change, tz)
            naive = change.replace(tzinfo=None)
            start, end = sorted([naive + before, naive + after])
            for expr, wall in dst_schedules(start, end):
                # The wall time read with each offset: in a gap the shifted
                # occurrence, in an overlap the first and the second pass.
                readings = [
                    (wall - utc_offset).replace(tzinfo=UTC) for utc_offset in (before, after)
                ]
                add_dst_evaluations(cases, f"{expr} in {zone}", zone, change, readings)


def dst_schedules(start: datetime, end: datetime) -> list[tuple[str, datetime]]:
    """Schedules, each with the wall time it fires at, in, just before and just
    after the wall-clock range [start, end) that a transition skips or repeats."""
    middle = start + (end - start) // 2
    schedules = []
    for wall in [start - MINUTE, start, middle, end - MINUTE, end]:
        schedules.append((f"every day at {hhmm(wall)}", wall))
        schedules.append((f"on {wall.date()} at {hhmm(wall)}", wall))
    day, t = middle.date(), hhmm(middle)
    month = MONTHS[day.month - 1]
    schedules += [
        (f"every day at {hhmm(start - MINUTE)}, {t}, {hhmm(end)}", middle),
        (f"every {WEEKDAYS[day.weekday()]} at {t}", middle),
        (f"every month on the {ordinal(day.day)} at {t}", middle),
        (f"every year on {month} {day.day} at {t}", middle),
        (f"every day at {t} except {month} {day.day}", middle),
        (f"every day at {t} until {day}", middle),
        (f"every day at {t} starting {day + DAY}", middle),
    ]
    window_start = max(start - timedelta(hours=1), start.replace(hour=0, minute=0))
    window_end = min(end + timedelta(hours=1), start.replace(hour=23, minute=59))
    for interval in [
        f"15 min from {hhmm(window_start)} to {hhmm(window_end)}",
        "30 min from 00:00 to 23:59",
        "1 hour from 00:00 to 23:59",
    ]:
        schedules.append((f"every {interval}", middle))
    return schedules


def add_dst_evaluations(
    cases: Cases, expr: str, zone: str, change: datetime, readings: list[datetime]
) -> None:
    for now in [change - DAY, change - MINUTE, change + MINUTE]:
        cases.add("dst", "next", expr, {"now": stamp(now, zone)})
    for now in [change + DAY, change + MINUTE, change - MINUTE]:
        cases.add("dst", "prev", expr, {"now": stamp(now, zone)})
    cases.add("dst", "nextN", expr, {"now": stamp(change - DAY, zone), "n": 4})
    window = {"from": stamp(change - DAY, zone), "to": stamp(change + DAY, zone)}
    cases.add("dst", "between", expr, window)
    for instant in [*readings, readings[0] + timedelta(seconds=30)]:
        cases.add("dst", "matches", expr, {"datetime": stamp(instant, zone)})


def add_range(cases: Cases) -> None:
    early = {"from": stamp(EARLIEST), "to": stamp(EARLIEST + 3 * DAY)}
    late = {"from": stamp(LATEST - 4 * DAY), "to": stamp(LATEST)}
    for body in EDGE_EXPRS:
        for zone in EDGE_ZONES:
            expr = body + zone
            for now in EDGE_NOWS:
                cases.add("range", "next", expr, {"now": stamp(now)})
                cases.add("range", "prev", expr, {"now": stamp(now)})
            for instant in RANGE_EDGES:
                cases.add("range", "matches", expr, {"datetime": stamp(instant)})
            cases.add("range", "nextN", expr, {"now": stamp(EARLIEST), "n": 3})
            cases.add("range", "occurrences", expr, {"from": stamp(RANGE_LAST - DAY), "n": 3})
            cases.add("range", "between", expr, early)
            cases.add("range", "between", expr, late)


def add_sparse(cases: Cases) -> None:
    for expr in SPARSE_EXPRS:
        for now in SPARSE_NOWS:
            cases.add("sparse", "next", expr, {"now": stamp(now)})
            cases.add("sparse", "prev", expr, {"now": stamp(now)})
            cases.add("sparse", "nextN", expr, {"now": stamp(now), "n": 3})
        for instant in SPARSE_MATCHES:
            cases.add("sparse", "matches", expr, {"datetime": stamp(instant)})


def add_cron(cases: Cases, rng: random.Random) -> None:
    generated = {" ".join(rng.choice(field) for field in CRON_FIELDS) for _ in range(300)}
    for cron in CRONS + sorted(generated - set(CRONS)):
        cases.add("cron", "fromCron", cron)
