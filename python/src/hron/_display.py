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
    IsoDate,
    IsoException,
    IsoUntil,
    LastDayTarget,
    LastWeekdayTarget,
    MonthRepeat,
    NamedDate,
    NamedException,
    NamedUntil,
    NearestDirection,
    NearestWeekdayTarget,
    OrdinalRepeat,
    ScheduleData,
    ScheduleExpr,
    SingleDateExpr,
    SingleDay,
    TimeOfDay,
    WeekRepeat,
    YearDateTarget,
    YearDayOfMonthTarget,
    YearLastWeekdayTarget,
    YearOrdinalWeekdayTarget,
    YearRepeat,
)


def display(schedule: ScheduleData) -> str:
    out = _display_expr(schedule.expr)

    if schedule.except_:
        parts: list[str] = []
        for exc in schedule.except_:
            match exc:
                case NamedException(month=m, day=d):
                    parts.append(f"{m} {d}")
                case IsoException(date=d):
                    parts.append(d)
        out += " except " + ", ".join(parts)

    if schedule.until:
        match schedule.until:
            case IsoUntil(date=d):
                out += f" until {d}"
            case NamedUntil(month=m, day=d):
                out += f" until {m} {d}"

    if schedule.anchor:
        out += f" starting {schedule.anchor}"

    if schedule.during:
        out += " during " + ", ".join(str(m) for m in schedule.during)

    if schedule.timezone:
        out += f" in {schedule.timezone}"

    return out


def _display_expr(expr: ScheduleExpr) -> str:
    match expr:
        case IntervalRepeat(interval=interval, unit=unit, from_time=ft, to_time=tt, day_filter=df):
            out = f"every {interval} {_unit_display(interval, unit)}"
            out += f" from {ft} to {tt}"
            if df is not None:
                out += f" on {_display_day_filter(df)}"
            return out

        case DayRepeat(interval=interval, days=days, times=times):
            if interval > 1:
                return f"every {interval} days at {_format_time_list(times)}"
            return f"every {_display_day_filter(days)} at {_format_time_list(times)}"

        case WeekRepeat(interval=interval, days=days, times=times):
            day_str = ", ".join(str(d) for d in days)
            return f"every {interval} weeks on {day_str} at {_format_time_list(times)}"

        case MonthRepeat(interval=interval, target=target, times=times):
            match target:
                case DaysTarget(specs=specs):
                    target_str = _format_ordinal_day_specs(specs)
                case LastDayTarget():
                    target_str = "last day"
                case LastWeekdayTarget():
                    target_str = "last weekday"
                case NearestWeekdayTarget(day=day, direction=direction):
                    prefix = ""
                    if direction == NearestDirection.NEXT:
                        prefix = "next "
                    elif direction == NearestDirection.PREVIOUS:
                        prefix = "previous "
                    target_str = f"{prefix}nearest weekday to {day}{_ordinal_suffix(day)}"
                case _:
                    target_str = "last weekday"
            if interval > 1:
                return f"every {interval} months on the {target_str} at {_format_time_list(times)}"
            return f"every month on the {target_str} at {_format_time_list(times)}"

        case OrdinalRepeat(interval=interval, ordinal=ordinal, day=day, times=times):
            if interval > 1:
                return f"{ordinal} {day} of every {interval} months at {_format_time_list(times)}"
            return f"{ordinal} {day} of every month at {_format_time_list(times)}"

        case SingleDateExpr(date=date_spec, times=times):
            match date_spec:
                case NamedDate(month=m, day=d):
                    date_str = f"{m} {d}"
                case IsoDate(date=d):
                    date_str = d
            return f"on {date_str} at {_format_time_list(times)}"

        case YearRepeat(interval=interval, target=target, times=times):
            match target:
                case YearDateTarget(month=m, day=d):
                    target_str = f"{m} {d}"
                case YearOrdinalWeekdayTarget(ordinal=o, weekday=w, month=m):
                    target_str = f"the {o} {w} of {m}"
                case YearDayOfMonthTarget(day=d, month=m):
                    target_str = f"the {d}{_ordinal_suffix(d)} of {m}"
                case YearLastWeekdayTarget(month=m):
                    target_str = f"the last weekday of {m}"
            if interval > 1:
                return f"every {interval} years on {target_str} at {_format_time_list(times)}"
            return f"every year on {target_str} at {_format_time_list(times)}"

    # Should be unreachable
    raise ValueError(f"unknown expression type: {type(expr)}")  # pragma: no cover


def _display_day_filter(f: DayFilter) -> str:
    match f:
        case DayFilterEvery():
            return "day"
        case DayFilterWeekday():
            return "weekday"
        case DayFilterWeekend():
            return "weekend"
        case DayFilterDays(days=days):
            return ", ".join(str(d) for d in days)


def _format_time_list(times: tuple[TimeOfDay, ...]) -> str:
    return ", ".join(str(t) for t in times)


def _format_ordinal_day_specs(specs: tuple[SingleDay | DayRange, ...]) -> str:
    parts: list[str] = []
    for spec in specs:
        match spec:
            case SingleDay(day=d):
                parts.append(f"{d}{_ordinal_suffix(d)}")
            case DayRange(start=s, end=e):
                parts.append(f"{s}{_ordinal_suffix(s)} to {e}{_ordinal_suffix(e)}")
    return ", ".join(parts)


def _ordinal_suffix(n: int) -> str:
    mod100 = n % 100
    if 11 <= mod100 <= 13:
        return "th"
    match n % 10:
        case 1:
            return "st"
        case 2:
            return "nd"
        case 3:
            return "rd"
        case _:
            return "th"


def _unit_display(interval: int, unit: IntervalUnit) -> str:
    if unit == IntervalUnit.MIN:
        return "minute" if interval == 1 else "min"
    return "hour" if interval == 1 else "hours"
