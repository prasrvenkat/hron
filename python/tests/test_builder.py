"""Building a schedule from ScheduleData (spec/README.md, "Schedules built in code"): what
spec/build.json leaves to each implementation."""

from __future__ import annotations

import dataclasses
import random
from collections.abc import Callable
from datetime import UTC, date, datetime
from typing import Any, TypeVar

import pytest

import hron
from hron import (
    DateSpec,
    DayFilter,
    DayFilterDays,
    DayFilterEvery,
    DayFilterWeekday,
    DayOfMonthSpec,
    DayRange,
    DayRepeat,
    DaysTarget,
    ExceptionSpec,
    HronError,
    IntervalRepeat,
    IntervalUnit,
    IsoDate,
    IsoException,
    IsoUntil,
    LastDayTarget,
    LastWeekdayTarget,
    MonthName,
    MonthRepeat,
    MonthTarget,
    NamedDate,
    NamedException,
    NamedUntil,
    NearestDirection,
    NearestWeekdayTarget,
    OrdinalPosition,
    OrdinalWeekdayTarget,
    Schedule,
    ScheduleData,
    ScheduleExpr,
    SingleDateExpr,
    SingleDay,
    TimeOfDay,
    UntilSpec,
    Weekday,
    WeekRepeat,
    YearDateTarget,
    YearDayOfMonthTarget,
    YearLastWeekdayTarget,
    YearOrdinalWeekdayTarget,
    YearRepeat,
    YearTarget,
)

NOW = datetime(2026, 2, 6, 12, tzinfo=UTC)
NINE = TimeOfDay(9, 0)
DAILY = DayRepeat(1, DayFilterEvery(), (NINE,))


def build_error(data: ScheduleData) -> str:
    with pytest.raises(HronError) as raised:
        Schedule(data)
    assert raised.value.kind == "eval"
    return str(raised.value)


def untyped(value: object) -> Any:  # noqa: ANN401
    return value


def daily(interval: object = 1, times: object = (NINE,)) -> ScheduleData:
    return ScheduleData(DayRepeat(untyped(interval), DayFilterEvery(), untyped(times)))


def at(time: TimeOfDay) -> ScheduleData:
    return ScheduleData(DayRepeat(1, DayFilterEvery(), (time,)))


def on_the(target: object) -> ScheduleData:
    return ScheduleData(MonthRepeat(1, untyped(target), (NINE,)))


def on(day: object) -> ScheduleData:
    return ScheduleData(SingleDateExpr(untyped(day), (NINE,)))


@pytest.mark.parametrize(
    "data",
    [
        pytest.param(lambda: untyped(DAILY), id="an expression for ScheduleData"),
        pytest.param(lambda: daily(interval="1"), id="str interval"),
        pytest.param(lambda: daily(interval=1.0), id="float interval"),
        pytest.param(lambda: daily(interval=True), id="bool interval"),
        pytest.param(lambda: daily(times=None), id="None for times"),
        pytest.param(lambda: daily(times="09:00"), id="str for times"),
        pytest.param(lambda: daily(times={NINE}), id="set for times"),
        pytest.param(lambda: daily(times=("09:00",)), id="str time"),
        pytest.param(lambda: at(TimeOfDay(untyped(9.0), 0)), id="float hour"),
        pytest.param(lambda: at(TimeOfDay(9, untyped(False))), id="bool minute"),
        pytest.param(lambda: ScheduleData(WeekRepeat(1, untyped(None), (NINE,))), id="None days"),
        pytest.param(lambda: on_the(DaysTarget(untyped(None))), id="None for day specs"),
        pytest.param(lambda: on_the(DaysTarget((SingleDay(untyped("1")),))), id="str day"),
        pytest.param(lambda: on_the(DaysTarget((DayRange(1, untyped(2.0)),))), id="float day"),
        pytest.param(lambda: on(IsoDate(untyped(None))), id="None for an ISO date"),
        pytest.param(lambda: on(NamedDate(MonthName.JAN, untyped(True))), id="bool named day"),
        pytest.param(lambda: ScheduleData(DAILY, except_=untyped(None)), id="None for except_"),
        pytest.param(lambda: ScheduleData(DAILY, during=untyped(None)), id="None for during"),
        pytest.param(lambda: ScheduleData(DAILY, starting=untyped(date(2026, 2, 6))), id="date"),
        pytest.param(lambda: ScheduleData(DAILY, timezone=untyped(0)), id="int for timezone"),
    ],
)
def test_a_value_of_the_wrong_type_is_a_type_error(data: Callable[[], ScheduleData]) -> None:
    with pytest.raises(TypeError):
        Schedule(data())


@pytest.mark.parametrize(
    "data,message",
    [
        (
            lambda: ScheduleData(untyped(NamedDate(MonthName.JAN, 1))),
            "unknown expression NamedDate(month=<MonthName.JAN: 'jan'>, day=1)",
        ),
        (lambda: ScheduleData(untyped(None)), "unknown expression None"),
        (lambda: ScheduleData(DayRepeat(1, untyped(None), (NINE,))), "unknown day filter None"),
        (lambda: on_the(DaysTarget(untyped((1,)))), "unknown day spec 1"),
        (lambda: on_the(DaysTarget(untyped((None,)))), "unknown day spec None"),
        (lambda: on_the(LastDayTarget), "unknown month target <class 'hron._ast.LastDayTarget'>"),
        (lambda: on_the(None), "unknown month target None"),
        (
            lambda: ScheduleData(YearRepeat(1, untyped(LastWeekdayTarget()), (NINE,))),
            "unknown year target LastWeekdayTarget()",
        ),
        (lambda: on("2026-02-06"), "unknown date '2026-02-06'"),
        (lambda: on(None), "unknown date None"),
        (
            lambda: ScheduleData(DAILY, except_=untyped((IsoDate("2026-02-06"),))),
            "unknown exception IsoDate(date='2026-02-06')",
        ),
        (lambda: ScheduleData(DAILY, except_=untyped((None,))), "unknown exception None"),
        (
            lambda: ScheduleData(DAILY, until=untyped(IsoDate("2026-02-06"))),
            "unknown until IsoDate(date='2026-02-06')",
        ),
    ],
)
def test_a_value_outside_a_union_names_the_kind_and_its_repr(
    data: Callable[[], ScheduleData], message: str
) -> None:
    assert build_error(data()) == message


NAMES: list[tuple[str, Callable[[object], ScheduleData]]] = [
    ("Weekday", lambda v: ScheduleData(WeekRepeat(1, untyped((v,)), (NINE,)))),
    ("Weekday", lambda v: ScheduleData(DayRepeat(1, DayFilterDays(untyped((v,))), (NINE,)))),
    ("Weekday", lambda v: on_the(OrdinalWeekdayTarget(OrdinalPosition.LAST, untyped(v)))),
    ("MonthName", lambda v: ScheduleData(DAILY, during=untyped((v,)))),
    ("MonthName", lambda v: on(NamedDate(untyped(v), 1))),
    (
        "MonthName",
        lambda v: ScheduleData(YearRepeat(1, YearLastWeekdayTarget(untyped(v)), (NINE,))),
    ),
    ("OrdinalPosition", lambda v: on_the(OrdinalWeekdayTarget(untyped(v), Weekday.MONDAY))),
    ("IntervalUnit", lambda v: ScheduleData(IntervalRepeat(1, untyped(v), NINE, NINE, None))),
]


@pytest.mark.parametrize("kind,data", NAMES)
@pytest.mark.parametrize(
    "value", [None, "monday", "jan", "min", 1, -1, True, NearestDirection.NEXT]
)
def test_a_value_that_is_not_a_member_where_a_name_goes_is_a_type_error(
    kind: str, data: Callable[[object], ScheduleData], value: object
) -> None:
    with pytest.raises(TypeError, match=f"must be a {kind}, got {type(value).__name__}$"):
        Schedule(data(value))


@pytest.mark.parametrize("value", ["monday", "next", 1, True, MonthName.JAN])
def test_a_direction_other_than_a_member_or_none_is_a_type_error(value: object) -> None:
    with pytest.raises(
        TypeError, match=f"direction must be a NearestDirection, got {type(value).__name__}$"
    ):
        Schedule(on_the(NearestWeekdayTarget(1, untyped(value))))


@pytest.mark.parametrize(
    "data",
    [
        lambda: ScheduleData(YearRepeat(1, YearDayOfMonthTarget(32, untyped(13)), (NINE,))),
        lambda: ScheduleData(YearRepeat(1, YearDateTarget(untyped("feb"), 32), (NINE,))),
        lambda: on_the(NearestWeekdayTarget(32, untyped("next"))),
    ],
)
def test_a_name_of_another_type_comes_before_the_other_rules_of_its_part(
    data: Callable[[], ScheduleData],
) -> None:
    with pytest.raises(TypeError):
        Schedule(data())


def test_the_every_day_rule_comes_before_the_day_filter() -> None:
    days = ScheduleData(DayRepeat(2, untyped("weekday"), (NINE,)))
    assert build_error(days) == "days must be every day when the interval is above 1"


@pytest.mark.parametrize("text", ["20260206", "2026-W06-5", "2026W065"])
def test_a_date_other_than_yyyy_mm_dd_is_not_a_calendar_date(text: str) -> None:
    expected = f"date must be a calendar date from 0001-01-01 to 9999-12-31, got {text}"
    assert build_error(on(IsoDate(text))) == expected


def test_negative_values_are_written_as_display_writes_them() -> None:
    hour = DayRepeat(1, DayFilterEvery(), (TimeOfDay(-1, 0),))
    assert build_error(ScheduleData(hour)) == "time must be 00:00-23:59, got -1:00"


@pytest.mark.parametrize("day", [-1, -7, -8, -9, -11, -21, 0])
def test_a_day_below_1_is_written_with_th(day: int) -> None:
    single = on_the(DaysTarget((SingleDay(day),)))
    assert build_error(single) == f"day must be 1-31, got {day}th"
    nearest = on_the(NearestWeekdayTarget(day, None))
    assert build_error(nearest) == f"day must be 1-31, got {day}th"
    year = ScheduleData(YearRepeat(1, YearDayOfMonthTarget(day, MonthName.MAR), (NINE,)))
    assert build_error(year) == f"day must be 1-31, got {day}th"
    backwards = on_the(DaysTarget((DayRange(5, day),)))
    assert build_error(backwards) == f"day must be 1-31, got {day}th"


def test_lists_build_as_tuples_do() -> None:
    data = ScheduleData(
        WeekRepeat(1, untyped([Weekday.MONDAY]), untyped([NINE])),
        except_=untyped([IsoException("2026-02-09")]),
        during=untyped([MonthName.FEB]),
    )
    parsed = Schedule.parse("every week on monday at 09:00 except 2026-02-09 during feb")
    assert Schedule(data) == parsed


def test_later_changes_to_the_callers_lists_are_not_seen() -> None:
    days = [Weekday.MONDAY]
    filter_days = [Weekday.MONDAY]
    times = [NINE]
    specs: list[DayOfMonthSpec] = [SingleDay(1)]
    exceptions: list[ExceptionSpec] = [IsoException("2026-02-09")]
    during = [MonthName.FEB]
    week_repeat = WeekRepeat(1, untyped(days), untyped(times))
    week = Schedule(ScheduleData(week_repeat, except_=untyped(exceptions), during=untyped(during)))
    day = Schedule(ScheduleData(DayRepeat(1, DayFilterDays(untyped(filter_days)), untyped(times))))
    month = Schedule(ScheduleData(MonthRepeat(1, DaysTarget(untyped(specs)), untyped(times))))
    before = [str(week), str(day), str(month)]

    days.append(Weekday.TUESDAY)
    filter_days.clear()
    times[0] = TimeOfDay(10, 0)
    specs.append(SingleDay(2))
    exceptions.clear()
    during.append(MonthName.MAR)

    assert [str(week), str(day), str(month)] == before
    assert week.next_from(NOW) == datetime(2026, 2, 16, 9, tzinfo=UTC)


def test_what_the_getters_return_cannot_change_the_schedule() -> None:
    schedule = Schedule.parse("every week on monday at 09:00 except 2026-02-09 in UTC")
    data = schedule.data
    with pytest.raises(dataclasses.FrozenInstanceError):
        data.timezone = "Asia/Tokyo"  # ty: ignore[invalid-assignment]
    with pytest.raises(dataclasses.FrozenInstanceError):
        schedule.expression.interval = 2  # ty: ignore[invalid-assignment]
    expr = schedule.expression
    assert isinstance(expr, WeekRepeat)
    for value in (expr.days, expr.times, data.except_, data.during):
        assert isinstance(value, tuple)
    assert schedule.next_from(NOW) == datetime(2026, 2, 16, 9, tzinfo=UTC)


def test_a_built_schedule_keeps_no_list_it_was_given() -> None:
    schedule = Schedule(
        ScheduleData(
            MonthRepeat(1, DaysTarget(untyped([SingleDay(1), DayRange(3, 4)])), untyped([NINE])),
            except_=untyped([NamedException(MonthName.DEC, 25)]),
            during=untyped([MonthName.JAN]),
        )
    )
    data = schedule.data
    expr = data.expression
    assert isinstance(expr, MonthRepeat) and isinstance(expr.target, DaysTarget)
    for value in (expr.times, expr.target.specs, data.except_, data.during):
        assert isinstance(value, tuple)


def test_a_part_of_a_subclass_is_copied_as_its_own_class() -> None:
    class Moment(TimeOfDay):
        pass

    schedule = Schedule(ScheduleData(DayRepeat(1, DayFilterEvery(), (Moment(9, 0),))))
    assert schedule == Schedule.parse("every day at 09:00")
    expr = schedule.expression
    assert isinstance(expr, DayRepeat) and type(expr.times[0]) is TimeOfDay


def test_dataclasses_replace_changes_a_part_and_builds_again() -> None:
    schedule = Schedule.parse("every weekday at 09:00 in America/New_York")
    moved = Schedule(dataclasses.replace(schedule.data, timezone="europe/london"))
    assert str(moved) == "every weekday at 09:00 in Europe/London"
    with pytest.raises(HronError) as raised:
        Schedule(dataclasses.replace(schedule.data, timezone="EST"))
    assert raised.value.display_rich() == (
        "error: timezone must be UTC or an Area/Location name such as America/New_York, got EST"
    )


def test_schedules_from_equal_parts_are_equal_and_hash_alike() -> None:
    built = Schedule(ScheduleData(DayRepeat(1, DayFilterWeekday(), (NINE,)), timezone="utc"))
    parsed = Schedule.parse("every weekday at 9:00 in UTC")
    assert built == parsed
    assert hash(built) == hash(parsed)
    assert built != Schedule.parse("every weekday at 9:00")
    assert built != str(built)


@pytest.mark.parametrize(
    "ordinal,n",
    [
        (OrdinalPosition.FIRST, 1),
        (OrdinalPosition.SECOND, 2),
        (OrdinalPosition.THIRD, 3),
        (OrdinalPosition.FOURTH, 4),
        (OrdinalPosition.FIFTH, 5),
        (OrdinalPosition.LAST, -1),
    ],
)
def test_ordinal_position_numbers(ordinal: OrdinalPosition, n: int) -> None:
    assert ordinal.to_n() == n


def test_internals_that_take_unchecked_parts_are_private() -> None:
    public = {name for name in vars(hron) if not name.startswith("_")}
    assert public - set(hron.__all__) == {"annotations", "datetime", "Iterator"}
    assert set(hron.__all__) <= public


def test_every_month_target_can_be_built_from_the_package() -> None:
    target = NearestWeekdayTarget(15, NearestDirection.PREVIOUS)
    schedule = Schedule(ScheduleData(MonthRepeat(1, target, (NINE,))))
    assert str(schedule) == "every month on the previous nearest weekday to 15th at 09:00"


# Mostly values that keep the rules, with values just past each limit mixed in, so that many
# parts build and many fail.

T = TypeVar("T")


def _pick(rng: random.Random, common: list[T], rare: list[T]) -> T:
    return rng.choice(rare) if rng.random() < 0.05 else rng.choice(common)


def _random_time(rng: random.Random) -> TimeOfDay:
    return TimeOfDay(_pick(rng, list(range(24)), [24]), _pick(rng, [0, 30, 59], [60]))


def _random_times(rng: random.Random) -> tuple[TimeOfDay, ...]:
    times = tuple(_random_time(rng) for _ in range(rng.randint(1, 2)))
    return _pick(rng, [times], [()])


def _random_interval(rng: random.Random) -> int:
    return _pick(rng, [1, 1, 1, 2, 2147483647], [0, 2147483648])


def _random_day(rng: random.Random) -> int:
    return _pick(rng, list(range(1, 32)), [0, 32])


def _random_weekdays(rng: random.Random) -> tuple[Weekday, ...]:
    return _pick(rng, [tuple(rng.sample(list(Weekday), rng.randint(1, 2)))], [()])


def _random_month(rng: random.Random) -> MonthName:
    return rng.choice([MonthName.JAN, MonthName.FEB, MonthName.APR])


def _random_iso(rng: random.Random) -> str:
    return _pick(rng, ["2026-02-28", "2028-02-29"], ["2026-02-29", "0000-01-01", "20260206"])


def _random_day_filter(rng: random.Random) -> DayFilter:
    days = DayFilterDays(_random_weekdays(rng))
    return rng.choice([DayFilterEvery(), DayFilterWeekday(), days])


def _random_day_spec(rng: random.Random) -> DayOfMonthSpec:
    a, b = _random_day(rng), _random_day(rng)
    return rng.choice([SingleDay(a), DayRange(min(a, b), max(a, b)), DayRange(a, b)])


def _random_month_target(rng: random.Random) -> MonthTarget:
    specs = tuple(_random_day_spec(rng) for _ in range(rng.randint(1, 2)))
    targets: list[MonthTarget] = [
        DaysTarget(_pick(rng, [specs], [()])),
        LastDayTarget(),
        NearestWeekdayTarget(_random_day(rng), rng.choice([None, NearestDirection.NEXT])),
        OrdinalWeekdayTarget(OrdinalPosition.LAST, rng.choice(list(Weekday))),
    ]
    return rng.choice(targets)


def _random_year_target(rng: random.Random) -> YearTarget:
    month, day = _random_month(rng), _random_day(rng)
    targets: list[YearTarget] = [
        YearDateTarget(month, day),
        YearDayOfMonthTarget(day, month),
        YearOrdinalWeekdayTarget(OrdinalPosition.FIFTH, rng.choice(list(Weekday)), month),
        YearLastWeekdayTarget(month),
    ]
    return rng.choice(targets)


def _random_expression(rng: random.Random) -> ScheduleExpr:
    interval, times = _random_interval(rng), _random_times(rng)
    single: list[DateSpec] = [
        NamedDate(_random_month(rng), _random_day(rng)),
        IsoDate(_random_iso(rng)),
    ]
    window = IntervalRepeat(
        interval,
        rng.choice(list(IntervalUnit)),
        _random_time(rng),
        _random_time(rng),
        rng.choice([None, _random_day_filter(rng)]),
    )
    expressions: list[ScheduleExpr] = [
        window,
        DayRepeat(interval, _random_day_filter(rng), times),
        WeekRepeat(interval, _random_weekdays(rng), times),
        MonthRepeat(interval, _random_month_target(rng), times),
        SingleDateExpr(rng.choice(single), times),
        YearRepeat(interval, _random_year_target(rng), times),
    ]
    return rng.choice(expressions)


def _random_parts(rng: random.Random) -> ScheduleData:
    month, day = _random_month(rng), _random_day(rng)
    exceptions: list[tuple[ExceptionSpec, ...]] = [
        (),
        (NamedException(month, day),),
        (IsoException(_random_iso(rng)),),
    ]
    until: list[UntilSpec | None] = [None, NamedUntil(month, day), IsoUntil(_random_iso(rng))]
    return ScheduleData(
        _random_expression(rng),
        timezone=rng.choice([None, _pick(rng, ["utc", "america/new_york"], ["EST"])]),
        except_=rng.choice(exceptions),
        until=rng.choice(until),
        starting=rng.choice([None, _pick(rng, ["2026-02-06"], ["0000-01-01"])]),
        during=rng.choice([(), (_random_month(rng),)]),
    )


def test_built_schedules_keep_the_promises_of_parsed_ones() -> None:
    rng = random.Random(2026)
    built = 0
    for _ in range(2000):
        try:
            schedule = Schedule(_random_parts(rng))
        except HronError as error:
            assert error.kind == "eval" and error.span is None
            continue
        built += 1
        text = str(schedule)
        assert Schedule.parse(text) == schedule, text
        try:
            schedule.to_cron()
        except HronError as error:
            assert error.kind == "cron", text
        after = schedule.next_from(NOW)
        if after is not None:
            assert schedule.matches(after), text
        schedule.previous_from(NOW)
    assert built > 500
