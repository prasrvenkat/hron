from __future__ import annotations

from ._ast import (
    DayFilter,
    DayFilterDays,
    DayFilterEvery,
    DayFilterWeekday,
    DayFilterWeekend,
    DayRange,
    DayRepeat,
    DaysTarget,
    IntervalRepeat,
    IntervalUnit,
    LastDayTarget,
    MonthRepeat,
    OrdinalRepeat,
    ScheduleData,
    ScheduleExpr,
    SingleDateExpr,
    SingleDay,
    TimeOfDay,
    Weekday,
    WeekRepeat,
    YearRepeat,
    new_schedule_data,
)
from ._error import HronError


def to_cron(schedule: ScheduleData) -> str:
    if schedule.except_:
        raise HronError.cron("not expressible as cron (except clauses not supported)")
    if schedule.until:
        raise HronError.cron("not expressible as cron (until clauses not supported)")
    if schedule.during:
        raise HronError.cron("not expressible as cron (during clauses not supported)")

    expr = schedule.expr

    match expr:
        case DayRepeat(interval=interval, days=days, times=times):
            if interval > 1:
                raise HronError.cron("not expressible as cron (multi-day intervals not supported)")
            if len(times) != 1:
                raise HronError.cron("not expressible as cron (multiple times not supported)")
            time = times[0]
            dow = _day_filter_to_cron_dow(days)
            return f"{time.minute} {time.hour} * * {dow}"

        case IntervalRepeat(
            interval=interval,
            unit=unit,
            from_time=ft,
            to_time=tt,
            day_filter=df,
        ):
            full_day = ft.hour == 0 and ft.minute == 0 and tt.hour == 23 and tt.minute == 59
            if not full_day:
                raise HronError.cron(
                    "not expressible as cron (partial-day interval windows not supported)"
                )
            if df is not None:
                raise HronError.cron(
                    "not expressible as cron (interval with day filter not supported)"
                )
            if unit == IntervalUnit.MIN:
                if 60 % interval != 0:
                    raise HronError.cron(
                        f"not expressible as cron (*/{interval} breaks at hour boundaries)"
                    )
                return f"*/{interval} * * * *"
            # hours
            return f"0 */{interval} * * *"

        case WeekRepeat():
            raise HronError.cron("not expressible as cron (multi-week intervals not supported)")

        case MonthRepeat(interval=interval, target=target, times=times):
            if interval > 1:
                raise HronError.cron(
                    "not expressible as cron (multi-month intervals not supported)"
                )
            if len(times) != 1:
                raise HronError.cron("not expressible as cron (multiple times not supported)")
            time = times[0]
            match target:
                case DaysTarget(specs=specs):
                    expanded: list[int] = []
                    for s in specs:
                        match s:
                            case SingleDay(day=d):
                                expanded.append(d)
                            case DayRange(start=start, end=end):
                                for d in range(start, end + 1):
                                    expanded.append(d)
                    dom = ",".join(str(d) for d in expanded)
                    return f"{time.minute} {time.hour} {dom} * *"
                case LastDayTarget():
                    raise HronError.cron(
                        "not expressible as cron (last day of month not supported)"
                    )
                case _:
                    raise HronError.cron(
                        "not expressible as cron (last weekday of month not supported)"
                    )

        case OrdinalRepeat():
            raise HronError.cron("not expressible as cron (ordinal weekday of month not supported)")

        case SingleDateExpr():
            raise HronError.cron("not expressible as cron (single dates are not repeating)")

        case YearRepeat():
            raise HronError.cron(
                "not expressible as cron (yearly schedules not supported in 5-field cron)"
            )

    raise HronError.cron(f"unknown expression type: {type(expr)}")  # pragma: no cover


def _day_filter_to_cron_dow(f: DayFilter) -> str:
    match f:
        case DayFilterEvery():
            return "*"
        case DayFilterWeekday():
            return "1-5"
        case DayFilterWeekend():
            return "0,6"
        case DayFilterDays(days=days):
            nums = sorted(d.cron_dow for d in days)
            return ",".join(str(n) for n in nums)


def from_cron(cron: str) -> ScheduleData:
    fields = cron.strip().split()
    if len(fields) != 5:
        raise HronError.cron(f"expected 5 cron fields, got {len(fields)}")

    minute_field, hour_field, dom_field, _month_field, dow_field = fields

    # Minute interval: */N
    if minute_field.startswith("*/"):
        interval_str = minute_field[2:]
        try:
            interval = int(interval_str)
        except ValueError:
            raise HronError.cron("invalid minute interval") from None

        from_hour = 0
        to_hour = 23

        if hour_field == "*":
            pass  # full day
        elif "-" in hour_field:
            parts = hour_field.split("-")
            try:
                from_hour = int(parts[0])
                to_hour = int(parts[1])
            except (ValueError, IndexError):
                raise HronError.cron("invalid hour range") from None
        else:
            try:
                h = int(hour_field)
            except ValueError:
                raise HronError.cron("invalid hour") from None
            from_hour = h
            to_hour = h

        day_filter = None if dow_field == "*" else _parse_cron_dow(dow_field)

        if dom_field == "*":
            return new_schedule_data(
                IntervalRepeat(
                    interval=interval,
                    unit=IntervalUnit.MIN,
                    from_time=TimeOfDay(from_hour, 0),
                    to_time=TimeOfDay(to_hour, 59 if to_hour == 23 else 0),
                    day_filter=day_filter,
                )
            )

    # Hour interval: 0 */N
    if hour_field.startswith("*/") and minute_field == "0":
        interval_str = hour_field[2:]
        try:
            interval = int(interval_str)
        except ValueError:
            raise HronError.cron("invalid hour interval") from None
        if dom_field == "*" and dow_field == "*":
            return new_schedule_data(
                IntervalRepeat(
                    interval=interval,
                    unit=IntervalUnit.HOURS,
                    from_time=TimeOfDay(0, 0),
                    to_time=TimeOfDay(23, 59),
                    day_filter=None,
                )
            )

    # Standard time-based cron
    try:
        minute = int(minute_field)
    except ValueError:
        raise HronError.cron(f"invalid minute field: {minute_field}") from None
    try:
        hour = int(hour_field)
    except ValueError:
        raise HronError.cron(f"invalid hour field: {hour_field}") from None
    t = TimeOfDay(hour, minute)

    # DOM-based (monthly)
    if dom_field != "*" and dow_field == "*":
        if "-" in dom_field:
            raise HronError.cron(f"DOM ranges not supported: {dom_field}")
        day_nums: list[int] = []
        for s in dom_field.split(","):
            try:
                n = int(s)
            except ValueError:
                raise HronError.cron(f"invalid DOM field: {dom_field}") from None
            day_nums.append(n)
        specs = tuple(SingleDay(d) for d in day_nums)
        return new_schedule_data(MonthRepeat(interval=1, target=DaysTarget(specs), times=(t,)))

    # DOW-based (day repeat)
    days = _parse_cron_dow(dow_field)
    expr: ScheduleExpr = DayRepeat(interval=1, days=days, times=(t,))
    return new_schedule_data(expr)


def _parse_cron_dow(field: str) -> DayFilter:
    if field == "*":
        return DayFilterEvery()
    if field == "1-5":
        return DayFilterWeekday()
    if field in ("0,6", "6,0"):
        return DayFilterWeekend()

    if "-" in field:
        raise HronError.cron(f"DOW ranges not supported: {field}")

    nums: list[int] = []
    for s in field.split(","):
        try:
            n = int(s)
        except ValueError:
            raise HronError.cron(f"invalid DOW field: {field}") from None
        nums.append(n)

    days = tuple(_cron_dow_to_weekday(n) for n in nums)
    return DayFilterDays(days)


_CRON_DOW_MAP: dict[int, Weekday] = {
    0: Weekday.SUNDAY,
    1: Weekday.MONDAY,
    2: Weekday.TUESDAY,
    3: Weekday.WEDNESDAY,
    4: Weekday.THURSDAY,
    5: Weekday.FRIDAY,
    6: Weekday.SATURDAY,
    7: Weekday.SUNDAY,
}


def _cron_dow_to_weekday(n: int) -> Weekday:
    result = _CRON_DOW_MAP.get(n)
    if result is None:
        raise HronError.cron(f"invalid DOW number: {n}")
    return result
