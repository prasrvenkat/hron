from __future__ import annotations

import calendar
from collections.abc import Callable, Iterator
from dataclasses import dataclass
from datetime import UTC, date, datetime, timedelta
from itertools import pairwise

import pytest

from hron import (
    HronError,
    Schedule,
)

# Two years around 2044-02-29, a leap day in a February with five Mondays.
WINDOW_START = date(2043, 6, 1)
WINDOW_END = date(2045, 6, 1)
FULL_COMPARE_LIMIT = 20_000

BOTH_DAYS = "not expressible in hron: cron fires on either the day of month or the day of week"
INTERVAL_DAYS = (
    "not expressible in hron: an interval runs only on every day, weekdays, the weekend"
    " or listed days"
)

Time = tuple[int, int]


def cron_message(action: Callable[[], object]) -> str:
    with pytest.raises(HronError) as raised:
        action()
    assert raised.value.kind == "cron"
    return str(raised.value)


def from_cron_error(cron: str) -> str:
    return cron_message(lambda: Schedule.from_cron(cron))


def from_cron(cron: str) -> str:
    return str(Schedule.from_cron(cron))


MONTH_NAMES = [
    "",
    "jan",
    "feb",
    "mar",
    "apr",
    "may",
    "jun",
    "jul",
    "aug",
    "sep",
    "oct",
    "nov",
    "dec",
]
DAY_NAMES = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]


def naive_number(text: str, names: list[str]) -> int:
    return names.index(text) if text in names else int(text)


def naive_set(
    field: str, low_end: int, high_end: int, star_end: int, names: list[str]
) -> list[bool]:
    selected = [False] * (high_end + 1)
    for item in field.split(","):
        base, _, step_text = item.partition("/")
        step = int(step_text) if step_text else None
        if base == "*":
            low, high = low_end, star_end
        elif "-" in base:
            a, b = base.split("-")
            low, high = naive_number(a, names), naive_number(b, names)
        else:
            low = naive_number(base, names)
            high = max(low, star_end) if step is not None else low
        value = low
        while value <= high:
            selected[value] = True
            value += step or 1
    return selected


class NaiveCron:
    """A cron matcher written from the cron rules alone, sharing no code with hron. It
    expects valid syntax."""

    def __init__(self, cron: str) -> None:
        cron = cron.strip().lower()
        cron = {
            "@yearly": "0 0 1 1 *",
            "@annually": "0 0 1 1 *",
            "@monthly": "0 0 1 * *",
            "@weekly": "0 0 * * 0",
            "@daily": "0 0 * * *",
            "@midnight": "0 0 * * *",
            "@hourly": "0 * * * *",
        }.get(cron, cron)
        fields = cron.split()
        assert len(fields) == 5, cron
        self.minutes = naive_set(fields[0], 0, 59, 59, [])
        self.hours = naive_set(fields[1], 0, 23, 23, [])
        self.months = naive_set(fields[3], 1, 12, 12, MONTH_NAMES)

        dom = fields[2]
        self.dom_days: list[bool] = []
        self.dom_nearest = 0
        if dom in ("*", "?"):
            self.dom = "any"
        elif dom in ("l", "lw"):
            self.dom = dom
        elif dom.endswith("w"):
            self.dom = "nearest"
            self.dom_nearest = int(dom[:-1])
        else:
            self.dom = "days"
            self.dom_days = naive_set(dom, 1, 31, 31, [])

        dow = fields[4]
        self.dow_days: list[bool] = []
        self.dow_day = 0
        self.dow_nth = 0
        if dow in ("*", "?"):
            self.dow = "any"
        elif "#" in dow:
            day, nth = dow.split("#")
            self.dow = "nth"
            self.dow_day = naive_number(day, DAY_NAMES) % 7
            self.dow_nth = int(nth)
        elif dow.endswith("l"):
            self.dow = "last"
            self.dow_day = naive_number(dow[:-1], DAY_NAMES) % 7
        else:
            self.dow = "days"
            days = naive_set(dow, 0, 7, 6, DAY_NAMES)
            days[0] |= days[7]
            self.dow_days = days[:7]

    def times(self) -> list[Time]:
        return [
            (hour, minute)
            for hour in range(24)
            for minute in range(60)
            if self.hours[hour] and self.minutes[minute]
        ]

    def fires_on(self, d: date) -> bool:
        day = d.day
        last = calendar.monthrange(d.year, d.month)[1]
        weekday = d.isoweekday() % 7
        weekdays = [n for n in range(1, last + 1) if date(d.year, d.month, n).isoweekday() <= 5]
        dom = None
        if self.dom == "days":
            dom = self.dom_days[day]
        elif self.dom == "l":
            dom = day == last
        elif self.dom == "lw":
            dom = day == weekdays[-1]
        elif self.dom == "nearest":
            nearest = min(weekdays, key=lambda w: abs(w - self.dom_nearest))
            dom = self.dom_nearest <= last and day == nearest
        dow = None
        if self.dow == "days":
            dow = self.dow_days[weekday]
        elif self.dow == "nth":
            dow = weekday == self.dow_day and (day - 1) // 7 + 1 == self.dow_nth
        elif self.dow == "last":
            dow = weekday == self.dow_day and day + 7 > last
        # Cron fires on a day either restricted field matches.
        day_matches = (dom is None and dow is None) or bool(dom) or bool(dow)
        return self.months[d.month] and day_matches

    def both_days_restricted(self) -> bool:
        return self.dom != "any" and self.dow != "any"

    def days_carry_an_interval(self) -> bool:
        if self.dom == "any":
            return self.dow in ("any", "days")
        return self.dom == "days" and self.dow == "any" and all(self.dom_days[1:])


def window_days() -> Iterator[date]:
    d = WINDOW_START
    while d < WINDOW_END:
        yield d
        d += timedelta(days=1)


def utc(d: date, hour: int = 0, minute: int = 0) -> datetime:
    return datetime(d.year, d.month, d.day, hour, minute, tzinfo=UTC)


def wall(t: datetime) -> tuple[date, Time]:
    return t.date(), (t.hour, t.minute)


SECOND = timedelta(seconds=1)


def assert_fires_as(schedule: Schedule, cron: NaiveCron, label: str) -> None:
    times = cron.times()
    days = [d for d in window_days() if cron.fires_on(d)]
    if len(days) * len(times) <= FULL_COMPARE_LIMIT:
        assert_each_occurrence(schedule, days, times, WINDOW_END, label)
        return
    early_end = days[1] + timedelta(days=1)
    assert_each_occurrence(schedule, days[:2], times, early_end, label)
    # Too many to compare one by one. In UTC an hron schedule fires at the same times on
    # every day it fires, so the two days compared in full stand for the times of the rest;
    # on each day the first and the last time, searched from the day before, show that it
    # fires that day and on no day between.
    cursor = utc(WINDOW_START) - SECOND
    for d in days:
        found = schedule.next_from(cursor)
        assert found is not None and wall(found) == (d, times[0]), f"{label}: first on {d}"
        end_of_day = utc(d + timedelta(days=1))
        found = schedule.previous_from(end_of_day)
        assert found is not None and wall(found) == (d, times[-1]), f"{label}: last on {d}"
        cursor = end_of_day - SECOND
    after = schedule.next_from(cursor)
    assert after is None or after.date() >= WINDOW_END, f"{label}: fires on {after}"


def assert_each_occurrence(
    schedule: Schedule, days: list[date], times: list[Time], end: date, label: str
) -> None:
    expected = [(d, t) for d in days for t in times]
    actual = [wall(t) for t in schedule.between(utc(WINDOW_START) - SECOND, utc(end) - SECOND)]
    assert actual == expected, label


def has_equal_gaps(times: list[Time]) -> bool:
    minutes = [h * 60 + m for h, m in times]
    return len(minutes) >= 3 and all(b - a == minutes[1] - minutes[0] for a, b in pairwise(minutes))


def expected_from_cron_failure(naive: NaiveCron, times: list[Time]) -> str | None:
    interval = naive.days_carry_an_interval() and has_equal_gaps(times)
    if len(times) <= 24 or interval:
        return None
    if has_equal_gaps(times):
        return INTERVAL_DAYS
    return f"not expressible in hron: {len(times)} times a day are too many to list"


MASK = (1 << 64) - 1


class Rng:
    """xorshift64*, so the generated cases are the same on every run."""

    def __init__(self, seed: int) -> None:
        self.state = seed

    def pick_index(self, length: int) -> int:
        x = self.state
        x ^= x >> 12
        x ^= (x << 25) & MASK
        x ^= x >> 27
        self.state = x
        return (((x * 0x2545F4914F6CDD1D) & MASK) >> 32) % length

    def pick(self, items: list[str]) -> str:
        return items[self.pick_index(len(items))]


MINUTE_FIELDS = ["0", "30", "*/15", "0-30/10", "5,35", "*", "59", "*/7", "00", "10-50/20"]
MINUTE_FIELDS += ["45/5", "0/20", "1-3", "*/99999999999999999999", "0,15,30,45", "5-10/5"]
MINUTE_FIELDS += ["0-59/30", "*/20"]
HOUR_FIELDS = ["9", "*", "*/2", "9-17", "9-17/2", "0,12", "23", "0-20/4", "*/5", "22,0,2"]
HOUR_FIELDS += ["1-23", "7/30", "009", "0-11", "*/1", "12-12/250", "0-16/4", "1-21/4"]
DOM_FIELDS = ["*", "1", "15", "31", "L", "LW", "15W", "1-5", "1-31/10", "?", "29", "30", "lw"]
DOM_FIELDS += ["1W", "31W", "*/2", "1-31", "5-20/3", "15,1", "02", "l", "28-31", "30W", "29w"]
DOM_FIELDS += ["1-30", "2-31"]
MONTH_FIELDS = ["*", "1", "JAN", "1-3", "*/3", "2", "dec", "4", "feb", "1,7", "jun-aug", "12,1"]
MONTH_FIELDS += ["*/12", "2/5", "12-12/250", "Sep", "2", "2"]
DOW_FIELDS = ["*", "1-5", "MON", "0", "7", "5L", "1#2", "SUN#1", "?", "1-5/2", "sat,sun", "0-7"]
DOW_FIELDS += ["7/2", "5-7", "fri#5", "1#5", "0l", "mon-fri/2", "6,7", "7,1", "0-6", "5/1"]
DOW_FIELDS += ["*/3", "tue-thu", "1,1,3", "1-4", "mon-thu", "1-6", "0-5", "0,6,1", "sun,sat"]


def generated_crons(shard: int) -> list[str]:
    # Two crons in three keep one day field `*`, so most convert; the third draws both, so
    # some are rejected for restricting both.
    rng = Rng(0x9E3779B97F4A7C15 ^ shard)
    crons = []
    for i in range(150):
        dom, dow = [(DOM_FIELDS, ["*"]), (["*"], DOW_FIELDS), (DOM_FIELDS, DOW_FIELDS)][i % 3]
        fields = [MINUTE_FIELDS, HOUR_FIELDS, dom, MONTH_FIELDS, dow]
        crons.append(" ".join(rng.pick(field) for field in fields))
    return crons


@pytest.mark.parametrize("shard", [0, 1, 2, 3])
def test_from_cron_is_exact(shard: int) -> None:
    accepted = 0
    for cron in generated_crons(shard):
        naive = NaiveCron(cron)
        times = naive.times()
        if naive.both_days_restricted():
            assert from_cron_error(cron) == BOTH_DAYS, cron
            continue
        failure = expected_from_cron_failure(naive, times)
        if failure is not None:
            assert from_cron_error(cron) == failure, cron
            continue
        schedule = Schedule.from_cron(cron)
        assert_fires_as(schedule, naive, cron)

        back = schedule.to_cron()
        again = Schedule.from_cron(back)
        label = f"{cron} -> {schedule} -> {back}"
        if str(again) != str(schedule):
            assert_fires_as(again, naive, label)
        naive_back = NaiveCron(back)
        assert naive_back.times() == times, label
        for d in window_days():
            assert naive_back.fires_on(d) == naive.fires_on(d), f"{label} on {d}"
        accepted += 1
    assert accepted >= 60, f"only {accepted} generated crons were accepted"


TIME_LISTS = [
    "09:00",
    "00:00",
    "23:59",
    "09:00, 17:00",
    "17:00, 09:00, 09:00",
    "00:00, 12:00",
    "09:00, 13:00, 17:00",
    "09:00, 17:30",
    "00:05, 00:35",
    "00:00, 00:01, 00:02, 00:30",
    ", ".join(f"{h:02d}:{m:02d}" for h in range(13) for m in (0, 10)),
    ", ".join(f"{h:02d}:00" for h in range(24)) + ", 23:59",
    ", ".join(f"{h:02d}:00" for h in range(24)),
    ", ".join(f"{h:02d}:{m:02d}" for h in range(9, 16) for m in (0, 30)),
    ", ".join(f"09:{m:02d}" for m in range(25)),
]
# Each with the month it names, which a `during` must include.
DAY_EXPRESSIONS: list[tuple[str, str | None]] = [
    ("every day", None),
    ("every weekday", None),
    ("every weekend", None),
    ("every monday", None),
    ("every sunday, saturday", None),
    ("every friday, saturday, sunday", None),
    ("every week on tuesday, friday", None),
    ("every 1 day", None),
    ("every month on the 1st", None),
    ("every month on the 1st to 5th, 20th", None),
    ("every month on the 31st", None),
    ("every month on the 15th, 1st", None),
    ("every month on the 1st to 31st", None),
    ("every month on the last day", None),
    ("every month on the last weekday", None),
    ("every month on the nearest weekday to 1st", None),
    ("every month on the nearest weekday to 31st", None),
    ("every month on the nearest weekday to 15th", None),
    ("every month on the first monday", None),
    ("every month on the fifth friday", None),
    ("every month on the last sunday", None),
    ("every year on feb 29", "feb"),
    ("every year on dec 25", "dec"),
    ("every year on the 15th of march", "mar"),
    ("every year on the first monday of mar", "mar"),
    ("every year on the fifth monday of feb", "feb"),
    ("every year on the last friday of feb", "feb"),
    ("every year on the last weekday of dec", "dec"),
    ("on feb 14", "feb"),
    ("on feb 29", "feb"),
]
INTERVALS = [
    "every 30 min from 09:00 to 17:30",
    "every 15 min from 00:00 to 23:59",
    "every 2 hours from 00:00 to 23:59",
    "every 7 hours from 00:00 to 23:59",
    "every 45 min from 09:00 to 17:00",
    "every 20 min from 09:00 to 17:40",
    "every 1 minute from 00:00 to 23:59",
    "every 120 min from 01:00 to 23:00",
    "every 2147483647 hours from 00:00 to 23:59",
    "every 5 min from 10:00 to 10:30",
    "every 4 hours from 00:00 to 20:00",
    "every 1 hour from 09:05 to 17:05",
    "every 30 min from 09:00 to 17:00",
]
INTERVAL_DAY_FILTERS = ["", " on weekday", " on weekend", " on monday, friday"]
DURING = [
    "",
    "",
    " during feb",
    " during dec",
    " during jan, jul",
    " during dec, jan, feb",
    " during jan, feb, mar, apr, may, jun, jul, aug, sep, oct, nov, dec",
]


@dataclass
class GeneratedSchedule:
    hron: str
    times: list[int]
    own_month: str | None
    during: str


def generated_schedules() -> list[GeneratedSchedule]:
    rng = Rng(0x2545F4914F6CDD1D)
    schedules = []
    for i in range(240):
        during = rng.pick(DURING)
        if i % 3 == 0:
            day_filter = rng.pick(INTERVAL_DAY_FILTERS)
            interval = rng.pick(INTERVALS)
            hron = f"{interval}{day_filter}{during}"
            schedules.append(GeneratedSchedule(hron, naive_interval_times(interval), None, during))
        else:
            days, own_month = DAY_EXPRESSIONS[rng.pick_index(len(DAY_EXPRESSIONS))]
            times = rng.pick(TIME_LISTS)
            minutes = [naive_minute_of_day(t) for t in times.split(", ")]
            schedules.append(
                GeneratedSchedule(f"{days} at {times}{during}", minutes, own_month, during)
            )
    return schedules


def naive_minute_of_day(time: str) -> int:
    hour, minute = time.split(":")
    return int(hour) * 60 + int(minute)


def naive_interval_times(interval: str) -> list[int]:
    words = interval.split(" ")
    step = int(words[1]) * (60 if words[2].startswith("hour") else 1)
    start, end = naive_minute_of_day(words[4]), naive_minute_of_day(words[6])
    return [t for t in range(start, end + 1) if (t - start) % step == 0]


def expected_to_cron_failure(generated: GeneratedSchedule) -> str | None:
    """The reason toCron must give, decided from the generated parts alone."""
    month = generated.own_month
    if month is not None and generated.during and month not in generated.during:
        return "during excludes the schedule's month"
    times = set(generated.times)
    minutes = {t % 60 for t in times}
    hours = {t // 60 for t in times}
    if len(minutes) * len(hours) != len(times):
        return "times are not every combination of their minutes and hours"
    return None


def test_to_cron_is_exact() -> None:
    accepted = 0
    rejected = 0
    for generated in generated_schedules():
        hron = generated.hron
        schedule = Schedule.parse(hron)
        reason = expected_to_cron_failure(generated)
        if reason is not None:
            assert cron_message(schedule.to_cron) == f"not expressible as cron: {reason}", hron
            rejected += 1
            continue
        cron = schedule.to_cron()
        naive = NaiveCron(cron)
        assert_fires_as(schedule, naive, f"{hron} -> {cron}")
        accepted += 1

        times = naive.times()
        label = f"{hron} -> {cron} -> from_cron"
        failure = expected_from_cron_failure(naive, times)
        if failure is not None:
            assert from_cron_error(cron) == failure, label
            continue
        assert_fires_as(Schedule.from_cron(cron), naive, label)
    assert accepted >= 60 and rejected >= 20, f"{accepted} converted, {rejected} rejected"


def test_values_of_any_length_never_overflow() -> None:
    long_zeros = "0" * 10_000
    huge = "9" * 10_000
    assert from_cron(f"{long_zeros}9 {long_zeros}9 * * *") == "every day at 09:09"
    assert from_cron_error(f"0 9 * * 1#{huge}") == f"day of week ordinal must be 1-5, got {huge}"
    assert from_cron_error(f"0 9 {huge}W * *") == f"day of month must be 1-31, got {huge}"
    assert from_cron_error(f"0 {huge}-1 * * *") == f"hour must be 0-23, got {huge}"
    assert from_cron(f"0 9 * * 1-5/{huge}") == "every monday at 09:00"
    assert from_cron_error(f"0 9 * * */{long_zeros}") == "day of week step must be at least 1"
    assert from_cron(f"0 9 * * 0-7/{long_zeros}7") == "every sunday at 09:00"


def test_a_long_field_is_parsed_in_linear_time() -> None:
    items = ",".join(["1"] * 200_000)
    assert from_cron(f"0 9 {items} * *") == "every month on the 1st at 09:00"
    ranges = ",".join(["0-59/1"] * 50_000)
    assert from_cron(f"{ranges} 9 * * *") == "every 1 minute from 09:00 to 09:59"


@pytest.mark.parametrize(
    "cron",
    [
        "٩ 9 * * *",
        "1_0 9 * * *",
        "+1 9 * * *",
        "-1 9 * * *",
        " 0 9 * * *",
        "0 9 * * ſun",
        "0 9 * * mon#٣",
        "0 9 1K * *",
    ],
)
def test_only_ascii_digits_names_and_whitespace_are_cron(cron: str) -> None:
    message = from_cron_error(cron)
    assert message.startswith(("invalid ", "expected 5 cron fields")), message


def test_whitespace_other_than_space_tab_cr_lf_is_not_trimmed() -> None:
    assert from_cron_error("\u000b0 9 * * *") == "invalid minute: \u000b0"
    assert from_cron(" \t\r\n0\t9  * *\t*\r\n") == "every day at 09:00"


def test_interval_slots_of_a_huge_interval_are_computed_quickly() -> None:
    schedule = Schedule.parse("every 2147483647 hours from 00:00 to 23:59")
    assert schedule.to_cron() == "0 0 * * *"


def test_every_seventh_minute_over_a_whole_day_is_too_many_to_list() -> None:
    assert from_cron("*/7 9 * * *") == "every 7 min from 09:00 to 09:56"
    assert (
        from_cron_error("*/7 * * * *")
        == "not expressible in hron: 216 times a day are too many to list"
    )


def test_naive_matcher_agrees_with_known_dates() -> None:
    def fires(cron: str, d: date) -> bool:
        return NaiveCron(cron).fires_on(d)

    assert fires("0 9 * 2 1#5", date(2044, 2, 29))
    assert fires("0 9 1W * *", date(2043, 8, 3)), "Saturday the 1st moves to Monday"
    assert fires("0 9 31W * *", date(2043, 8, 31)), "Monday the 31st"
    assert fires("0 9 30W * *", date(2044, 4, 29)), "Saturday the 30th moves to Friday"
    assert fires("0 9 31W * *", date(2044, 7, 29)), "Sunday the 31st moves to Friday"
    assert not fires("0 9 31W * *", date(2044, 4, 30)), "April has no 31st"
    assert fires("0 9 LW * *", date(2044, 4, 29))
    assert fires("0 9 * * 5L", date(2044, 4, 29))
    assert not fires("0 9 * * 5L", date(2044, 4, 22))
