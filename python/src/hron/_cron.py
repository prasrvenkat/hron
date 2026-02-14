from __future__ import annotations

from ._ast import (
    ALL_WEEKDAYS,
    ALL_WEEKEND,
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
    LastWeekdayTarget,
    MonthName,
    MonthRepeat,
    OrdinalPosition,
    OrdinalRepeat,
    ScheduleData,
    SingleDateExpr,
    SingleDay,
    TimeOfDay,
    Weekday,
    WeekRepeat,
    YearDateTarget,
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


# ============================================================================
# from_cron: Parse 5-field cron expressions (and @ shortcuts)
# ============================================================================


def from_cron(cron: str) -> ScheduleData:
    """Parse a 5-field cron expression into a ScheduleData."""
    trimmed = cron.strip()

    # Handle @ shortcuts first
    if trimmed.startswith("@"):
        return _parse_cron_shortcut(trimmed)

    fields = trimmed.split()
    if len(fields) != 5:
        raise HronError.cron(f"expected 5 cron fields, got {len(fields)}")

    minute_field, hour_field, dom_field_raw, month_field, dow_field_raw = fields

    # Normalize ? to * (semantically equivalent for our purposes)
    dom_field = "*" if dom_field_raw == "?" else dom_field_raw
    dow_field = "*" if dow_field_raw == "?" else dow_field_raw

    # Parse month field into during clause
    during = _parse_month_field(month_field)

    # Check for special DOW patterns: nth weekday (#), last weekday (5L)
    nth_weekday_result = _try_parse_nth_weekday(
        minute_field, hour_field, dom_field, dow_field, during
    )
    if nth_weekday_result is not None:
        return nth_weekday_result

    # Check for L (last day) or LW (last weekday) in DOM
    last_day_result = _try_parse_last_day(
        minute_field, hour_field, dom_field, dow_field, during
    )
    if last_day_result is not None:
        return last_day_result

    # Check for W (nearest weekday) - not yet supported
    if dom_field.endswith("W") and dom_field != "LW":
        raise HronError.cron("W (nearest weekday) not yet supported")

    # Check for interval patterns: */N or range/N
    interval_result = _try_parse_interval(
        minute_field, hour_field, dom_field, dow_field, during
    )
    if interval_result is not None:
        return interval_result

    # Standard time-based cron
    minute = _parse_single_value(minute_field, "minute", 0, 59)
    hour = _parse_single_value(hour_field, "hour", 0, 23)
    time = TimeOfDay(hour, minute)

    # DOM-based (monthly) - when DOM is specified and DOW is *
    if dom_field != "*" and dow_field == "*":
        target = _parse_dom_field(dom_field)
        schedule = new_schedule_data(
            MonthRepeat(interval=1, target=target, times=(time,))
        )
        schedule.during = during
        return schedule

    # DOW-based (day repeat)
    days = _parse_cron_dow(dow_field)
    schedule = new_schedule_data(DayRepeat(interval=1, days=days, times=(time,)))
    schedule.during = during
    return schedule


def _parse_cron_shortcut(cron: str) -> ScheduleData:
    """Parse @ shortcuts like @daily, @hourly, etc."""
    lower = cron.lower()
    match lower:
        case "@yearly" | "@annually":
            return new_schedule_data(
                YearRepeat(
                    interval=1,
                    target=YearDateTarget(month=MonthName.JAN, day=1),
                    times=(TimeOfDay(0, 0),),
                )
            )
        case "@monthly":
            return new_schedule_data(
                MonthRepeat(
                    interval=1,
                    target=DaysTarget((SingleDay(1),)),
                    times=(TimeOfDay(0, 0),),
                )
            )
        case "@weekly":
            return new_schedule_data(
                DayRepeat(
                    interval=1,
                    days=DayFilterDays((Weekday.SUNDAY,)),
                    times=(TimeOfDay(0, 0),),
                )
            )
        case "@daily" | "@midnight":
            return new_schedule_data(
                DayRepeat(
                    interval=1,
                    days=DayFilterEvery(),
                    times=(TimeOfDay(0, 0),),
                )
            )
        case "@hourly":
            return new_schedule_data(
                IntervalRepeat(
                    interval=1,
                    unit=IntervalUnit.HOURS,
                    from_time=TimeOfDay(0, 0),
                    to_time=TimeOfDay(23, 59),
                    day_filter=None,
                )
            )
        case _:
            raise HronError.cron(f"unknown @ shortcut: {cron}")


def _parse_month_field(field: str) -> tuple[MonthName, ...]:
    """Parse month field into a tuple of MonthName for the `during` clause."""
    if field == "*":
        return ()

    months: list[MonthName] = []

    for part in field.split(","):
        # Check for step values FIRST (e.g., 1-12/3 or */3)
        if "/" in part:
            range_part, step_str = part.split("/", 1)
            if range_part == "*":
                start, end = 1, 12
            elif "-" in range_part:
                s, e = range_part.split("-", 1)
                start = _parse_month_value(s).number
                end = _parse_month_value(e).number
            else:
                raise HronError.cron(f"invalid month step expression: {part}")

            try:
                step = int(step_str)
            except ValueError:
                raise HronError.cron(f"invalid month step value: {step_str}") from None
            if step == 0:
                raise HronError.cron("step cannot be 0")

            n = start
            while n <= end:
                months.append(_month_from_number(n))
                n += step
        elif "-" in part:
            # Range like 1-3 or JAN-MAR
            start_str, end_str = part.split("-", 1)
            start_month = _parse_month_value(start_str)
            end_month = _parse_month_value(end_str)
            start_num = start_month.number
            end_num = end_month.number

            if start_num > end_num:
                raise HronError.cron(f"invalid month range: {start_str} > {end_str}")

            for n in range(start_num, end_num + 1):
                months.append(_month_from_number(n))
        else:
            # Single month
            months.append(_parse_month_value(part))

    return tuple(months)


def _parse_month_value(s: str) -> MonthName:
    """Parse a single month value (number 1-12 or name JAN-DEC)."""
    # Try as number first
    try:
        n = int(s)
        return _month_from_number(n)
    except ValueError:
        pass
    # Try as name
    result = MonthName.try_parse(s)
    if result is None:
        raise HronError.cron(f"invalid month: {s}")
    return result


def _month_from_number(n: int) -> MonthName:
    """Convert month number (1-12) to MonthName."""
    match n:
        case 1:
            return MonthName.JAN
        case 2:
            return MonthName.FEB
        case 3:
            return MonthName.MAR
        case 4:
            return MonthName.APR
        case 5:
            return MonthName.MAY
        case 6:
            return MonthName.JUN
        case 7:
            return MonthName.JUL
        case 8:
            return MonthName.AUG
        case 9:
            return MonthName.SEP
        case 10:
            return MonthName.OCT
        case 11:
            return MonthName.NOV
        case 12:
            return MonthName.DEC
        case _:
            raise HronError.cron(f"invalid month number: {n}")


def _try_parse_nth_weekday(
    minute_field: str,
    hour_field: str,
    dom_field: str,
    dow_field: str,
    during: tuple[MonthName, ...],
) -> ScheduleData | None:
    """Try to parse nth weekday patterns like 1#1 (first Monday) or 5L (last Friday)."""
    # Check for # pattern (nth weekday of month)
    if "#" in dow_field:
        dow_str, nth_str = dow_field.split("#", 1)
        dow_num = _parse_dow_value(dow_str)
        weekday = _cron_dow_to_weekday(dow_num)

        try:
            nth = int(nth_str)
        except ValueError:
            raise HronError.cron(f"nth must be 1-5, got {nth_str}") from None

        if nth < 1 or nth > 5:
            raise HronError.cron(f"nth must be 1-5, got {nth}")

        if dom_field != "*" and dom_field != "?":
            raise HronError.cron("DOM must be * when using # for nth weekday")

        minute = _parse_single_value(minute_field, "minute", 0, 59)
        hour = _parse_single_value(hour_field, "hour", 0, 23)

        ordinal_map: dict[int, OrdinalPosition] = {
            1: OrdinalPosition.FIRST,
            2: OrdinalPosition.SECOND,
            3: OrdinalPosition.THIRD,
            4: OrdinalPosition.FOURTH,
            5: OrdinalPosition.FIFTH,
        }

        schedule = new_schedule_data(
            OrdinalRepeat(
                interval=1,
                ordinal=ordinal_map[nth],
                day=weekday,
                times=(TimeOfDay(hour, minute),),
            )
        )
        schedule.during = during
        return schedule

    # Check for nL pattern (last weekday of month, e.g., 5L = last Friday)
    if dow_field.endswith("L") and len(dow_field) > 1:
        dow_str = dow_field[:-1]
        dow_num = _parse_dow_value(dow_str)
        weekday = _cron_dow_to_weekday(dow_num)

        if dom_field != "*" and dom_field != "?":
            raise HronError.cron("DOM must be * when using nL for last weekday")

        minute = _parse_single_value(minute_field, "minute", 0, 59)
        hour = _parse_single_value(hour_field, "hour", 0, 23)

        schedule = new_schedule_data(
            OrdinalRepeat(
                interval=1,
                ordinal=OrdinalPosition.LAST,
                day=weekday,
                times=(TimeOfDay(hour, minute),),
            )
        )
        schedule.during = during
        return schedule

    return None


def _try_parse_last_day(
    minute_field: str,
    hour_field: str,
    dom_field: str,
    dow_field: str,
    during: tuple[MonthName, ...],
) -> ScheduleData | None:
    """Try to parse L (last day) or LW (last weekday) patterns."""
    if dom_field != "L" and dom_field != "LW":
        return None

    if dow_field != "*" and dow_field != "?":
        raise HronError.cron("DOW must be * when using L or LW in DOM")

    minute = _parse_single_value(minute_field, "minute", 0, 59)
    hour = _parse_single_value(hour_field, "hour", 0, 23)

    target = LastWeekdayTarget() if dom_field == "LW" else LastDayTarget()

    schedule = new_schedule_data(
        MonthRepeat(
            interval=1,
            target=target,
            times=(TimeOfDay(hour, minute),),
        )
    )
    schedule.during = during
    return schedule


def _try_parse_interval(
    minute_field: str,
    hour_field: str,
    dom_field: str,
    dow_field: str,
    during: tuple[MonthName, ...],
) -> ScheduleData | None:
    """Try to parse interval patterns: */N, range/N in minute or hour fields."""
    # Minute interval: */N or range/N
    if "/" in minute_field:
        range_part, step_str = minute_field.split("/", 1)

        try:
            interval = int(step_str)
        except ValueError:
            raise HronError.cron("invalid minute interval value") from None
        if interval == 0:
            raise HronError.cron("step cannot be 0")

        if range_part == "*":
            from_minute, to_minute = 0, 59
        elif "-" in range_part:
            s, e = range_part.split("-", 1)
            try:
                from_minute = int(s)
                to_minute = int(e)
            except ValueError:
                raise HronError.cron("invalid minute range") from None
            if from_minute > to_minute:
                raise HronError.cron(f"range start must be <= end: {from_minute}-{to_minute}")
        else:
            # Single value with step (e.g., 0/15) - treat as starting point
            try:
                from_minute = int(range_part)
            except ValueError:
                raise HronError.cron("invalid minute value") from None
            to_minute = 59

        # Determine the hour window
        if hour_field == "*":
            from_hour, to_hour = 0, 23
        elif "-" in hour_field and "/" not in hour_field:
            s, e = hour_field.split("-", 1)
            try:
                from_hour = int(s)
                to_hour = int(e)
            except ValueError:
                raise HronError.cron("invalid hour range") from None
        elif "/" in hour_field:
            # Hour also has step - complex, skip
            return None
        else:
            try:
                h = int(hour_field)
            except ValueError:
                raise HronError.cron("invalid hour") from None
            from_hour = h
            to_hour = h

        day_filter = None if dow_field == "*" else _parse_cron_dow(dow_field)

        if dom_field == "*" or dom_field == "?":
            # Determine end minute based on context
            if from_minute == 0 and to_minute == 59 and to_hour == 23:
                # Full day: 00:00 to 23:59
                end_minute = 59
            elif from_minute == 0 and to_minute == 59:
                # Partial day with full minutes range: use :00 for cleaner output
                end_minute = 0
            else:
                end_minute = to_minute

            schedule = new_schedule_data(
                IntervalRepeat(
                    interval=interval,
                    unit=IntervalUnit.MIN,
                    from_time=TimeOfDay(from_hour, from_minute),
                    to_time=TimeOfDay(to_hour, end_minute),
                    day_filter=day_filter,
                )
            )
            schedule.during = during
            return schedule

    # Hour interval: 0 */N or 0 range/N
    if "/" in hour_field and minute_field in ("0", "00"):
        range_part, step_str = hour_field.split("/", 1)

        try:
            interval = int(step_str)
        except ValueError:
            raise HronError.cron("invalid hour interval value") from None
        if interval == 0:
            raise HronError.cron("step cannot be 0")

        if range_part == "*":
            from_hour, to_hour = 0, 23
        elif "-" in range_part:
            s, e = range_part.split("-", 1)
            try:
                from_hour = int(s)
                to_hour = int(e)
            except ValueError:
                raise HronError.cron("invalid hour range") from None
            if from_hour > to_hour:
                raise HronError.cron(f"range start must be <= end: {from_hour}-{to_hour}")
        else:
            try:
                from_hour = int(range_part)
            except ValueError:
                raise HronError.cron("invalid hour value") from None
            to_hour = 23

        if (dom_field == "*" or dom_field == "?") and (dow_field == "*" or dow_field == "?"):
            # Use :59 only for full day (00:00 to 23:59), otherwise use :00
            end_minute = 59 if from_hour == 0 and to_hour == 23 else 0

            schedule = new_schedule_data(
                IntervalRepeat(
                    interval=interval,
                    unit=IntervalUnit.HOURS,
                    from_time=TimeOfDay(from_hour, 0),
                    to_time=TimeOfDay(to_hour, end_minute),
                    day_filter=None,
                )
            )
            schedule.during = during
            return schedule

    return None


def _parse_dom_field(field: str) -> DaysTarget:
    """Parse a DOM field into a DaysTarget."""
    specs: list[SingleDay | DayRange] = []

    for part in field.split(","):
        if "/" in part:
            # Step value: 1-31/2 or */5
            range_part, step_str = part.split("/", 1)

            if range_part == "*":
                start, end = 1, 31
            elif "-" in range_part:
                s, e = range_part.split("-", 1)
                try:
                    start = int(s)
                except ValueError:
                    raise HronError.cron(f"invalid DOM range start: {s}") from None
                try:
                    end = int(e)
                except ValueError:
                    raise HronError.cron(f"invalid DOM range end: {e}") from None
                if start > end:
                    raise HronError.cron(f"range start must be <= end: {start}-{end}")
            else:
                try:
                    start = int(range_part)
                except ValueError:
                    raise HronError.cron(f"invalid DOM value: {range_part}") from None
                end = 31

            try:
                step = int(step_str)
            except ValueError:
                raise HronError.cron(f"invalid DOM step: {step_str}") from None
            if step == 0:
                raise HronError.cron("step cannot be 0")

            _validate_dom(start)
            _validate_dom(end)

            d = start
            while d <= end:
                specs.append(SingleDay(d))
                d += step
        elif "-" in part:
            # Range: 1-5
            start_str, end_str = part.split("-", 1)
            try:
                start = int(start_str)
            except ValueError:
                raise HronError.cron(f"invalid DOM range start: {start_str}") from None
            try:
                end = int(end_str)
            except ValueError:
                raise HronError.cron(f"invalid DOM range end: {end_str}") from None
            if start > end:
                raise HronError.cron(f"range start must be <= end: {start}-{end}")
            _validate_dom(start)
            _validate_dom(end)
            specs.append(DayRange(start, end))
        else:
            # Single: 15
            try:
                day = int(part)
            except ValueError:
                raise HronError.cron(f"invalid DOM value: {part}") from None
            _validate_dom(day)
            specs.append(SingleDay(day))

    return DaysTarget(tuple(specs))


def _validate_dom(day: int) -> None:
    """Validate day of month is in valid range."""
    if day < 1 or day > 31:
        raise HronError.cron(f"DOM must be 1-31, got {day}")


def _parse_cron_dow(field: str) -> DayFilter:
    """Parse a DOW field into a DayFilter."""
    if field == "*":
        return DayFilterEvery()

    days: list[Weekday] = []

    for part in field.split(","):
        if "/" in part:
            # Step value: 0-6/2 or */2
            range_part, step_str = part.split("/", 1)

            if range_part == "*":
                start, end = 0, 6
            elif "-" in range_part:
                s, e = range_part.split("-", 1)
                start = _parse_dow_value_raw(s)
                end = _parse_dow_value_raw(e)
                if start > end:
                    raise HronError.cron(f"range start must be <= end: {s}-{e}")
            else:
                start = _parse_dow_value_raw(range_part)
                end = 6

            try:
                step = int(step_str)
            except ValueError:
                raise HronError.cron(f"invalid DOW step: {step_str}") from None
            if step == 0:
                raise HronError.cron("step cannot be 0")

            d = start
            while d <= end:
                normalized = 0 if d == 7 else d
                days.append(_cron_dow_to_weekday(normalized))
                d += step
        elif "-" in part:
            # Range: 1-5 or MON-FRI (parse without normalizing 7 for range checking)
            start_str, end_str = part.split("-", 1)
            start = _parse_dow_value_raw(start_str)
            end = _parse_dow_value_raw(end_str)
            if start > end:
                raise HronError.cron(f"range start must be <= end: {start_str}-{end_str}")
            for d in range(start, end + 1):
                # Normalize 7 to 0 (Sunday) when converting to weekday
                normalized = 0 if d == 7 else d
                days.append(_cron_dow_to_weekday(normalized))
        else:
            # Single: 1 or MON
            dow = _parse_dow_value(part)
            days.append(_cron_dow_to_weekday(dow))

    # Check for special patterns
    if len(days) == 5:
        sorted_days = sorted(days, key=lambda d: d.number)
        sorted_weekdays = sorted(ALL_WEEKDAYS, key=lambda d: d.number)
        if sorted_days == list(sorted_weekdays):
            return DayFilterWeekday()

    if len(days) == 2:
        sorted_days = sorted(days, key=lambda d: d.number)
        sorted_weekend = sorted(ALL_WEEKEND, key=lambda d: d.number)
        if sorted_days == list(sorted_weekend):
            return DayFilterWeekend()

    return DayFilterDays(tuple(days))


def _parse_dow_value(s: str) -> int:
    """Parse a DOW value (number 0-7 or name SUN-SAT), normalizing 7 to 0."""
    raw = _parse_dow_value_raw(s)
    # Normalize 7 to 0 (both mean Sunday)
    return 0 if raw == 7 else raw


def _parse_dow_value_raw(s: str) -> int:
    """Parse a DOW value without normalizing 7 to 0 (for range checking)."""
    # Try as number first
    try:
        n = int(s)
        if n > 7:
            raise HronError.cron(f"DOW must be 0-7, got {n}")
        return n
    except ValueError:
        pass
    # Try as name
    dow_map = {
        "SUN": 0,
        "MON": 1,
        "TUE": 2,
        "WED": 3,
        "THU": 4,
        "FRI": 5,
        "SAT": 6,
    }
    result = dow_map.get(s.upper())
    if result is None:
        raise HronError.cron(f"invalid DOW: {s}")
    return result


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
    """Convert cron DOW number (0-7) to Weekday."""
    result = _CRON_DOW_MAP.get(n)
    if result is None:
        raise HronError.cron(f"invalid DOW number: {n}")
    return result


def _parse_single_value(field: str, name: str, min_val: int, max_val: int) -> int:
    """Parse a single numeric value with validation."""
    try:
        value = int(field)
    except ValueError:
        raise HronError.cron(f"invalid {name} field: {field}") from None
    if value < min_val or value > max_val:
        raise HronError.cron(f"{name} must be {min_val}-{max_val}, got {value}")
    return value
