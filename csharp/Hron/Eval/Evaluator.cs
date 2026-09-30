using Hron.Ast;

namespace Hron.Eval;

/// <summary>
/// Evaluates schedule expressions to compute occurrences.
/// </summary>
/// <remarks>
/// Implements the "Behavioral Semantics" section of spec/README.md.
/// </remarks>
public static class Evaluator
{
    private const int GregorianCycleYears = 400;
    private const int GregorianCycleMonths = GregorianCycleYears * 12;
    private const int GregorianCycleDays = 146097;
    private const int GregorianCycleWeeks = GregorianCycleDays / 7;

    private static readonly DateOnly EpochDate = new(1970, 1, 1);

    private static readonly DateOnly EpochMonday = new(1970, 1, 5);

    // The spec's supported range: its first instant, and the first instant past its end.
    private static readonly DateTimeOffset EarliestSupported = new(1, 1, 2, 0, 0, 0, TimeSpan.Zero);
    private static readonly DateTimeOffset EndOfSupported = new(9999, 12, 30, 0, 0, 0, TimeSpan.Zero);

    private readonly record struct Occurrence(DateTimeOffset At, DateOnly ScheduledDate);

    /// <summary>
    /// Computes the next occurrence strictly after the given time, or null if there is none or
    /// the time is outside the supported range.
    /// </summary>
    public static DateTimeOffset? NextFrom(ScheduleData data, DateTimeOffset now, TimeZoneInfo location)
    {
        return IsSupported(now) ? Next(data, now, location, DateOnly.MaxValue) : null;
    }

    /// <summary>
    /// Computes the next n occurrences strictly after the given time.
    /// </summary>
    public static IReadOnlyList<DateTimeOffset> NextNFrom(ScheduleData data, DateTimeOffset now, int n, TimeZoneInfo location)
    {
        return Occurrences(data, now, location).Take(n).ToList();
    }

    /// <summary>
    /// Returns a lazy enumerable of occurrences strictly after the given time.
    /// </summary>
    public static IEnumerable<DateTimeOffset> Occurrences(ScheduleData data, DateTimeOffset from, TimeZoneInfo location)
    {
        var current = from;
        while (NextFrom(data, current, location) is { } next)
        {
            yield return next;
            current = next;
        }
    }

    /// <summary>
    /// Returns a lazy enumerable of occurrences where from &lt; occurrence &lt;= to, empty when
    /// either bound is outside the supported range.
    /// </summary>
    public static IEnumerable<DateTimeOffset> Between(ScheduleData data, DateTimeOffset from, DateTimeOffset to, TimeZoneInfo location)
    {
        return IsSupported(to) ? Occurrences(data, from, location).TakeWhile(dt => dt <= to) : [];
    }

    /// <summary>
    /// Computes the most recent occurrence strictly before the given time, or null if there is
    /// none or the time is outside the supported range.
    /// </summary>
    public static DateTimeOffset? PreviousFrom(ScheduleData data, DateTimeOffset now, TimeZoneInfo location)
    {
        if (!IsSupported(now))
        {
            return null;
        }

        var today = LocalDate(now, location);
        var last = data.Until is not null ? ResolveUntil(data.Until, today) : DateOnly.MaxValue;
        var limit = SearchLimit(data.Expr, Min(today, last), -1);
        if (data.Anchor is not null)
        {
            limit = Max(limit, DateOnly.Parse(data.Anchor));
        }

        // A fall-back overlap that crosses midnight repeats times of the next date before now.
        var from = Min(AddDaysWithin(today, 1), last);
        return Search(data, now, location, from, limit, -1);
    }

    /// <summary>
    /// Checks if the minute containing a datetime, on the schedule's wall clock, is an occurrence.
    /// False outside the supported range.
    /// </summary>
    public static bool Matches(ScheduleData data, DateTimeOffset dt, TimeZoneInfo location)
    {
        if (!IsSupported(dt))
        {
            return false;
        }
        var wall = TimeZoneInfo.ConvertTime(dt, location).DateTime;
        var minute = dt.AddTicks(-(wall.Ticks % TimeSpan.TicksPerMinute));
        return Next(data, minute.AddTicks(-1), location, DateOnly.FromDateTime(wall)) == minute;
    }

    /// <summary>
    /// The first occurrence after <paramref name="now"/> scheduled on or before
    /// <paramref name="lastDate"/>.
    /// </summary>
    private static DateTimeOffset? Next(ScheduleData data, DateTimeOffset now, TimeZoneInfo location, DateOnly lastDate)
    {
        var today = LocalDate(now, location);
        var first = data.Anchor is not null ? DateOnly.Parse(data.Anchor) : DateOnly.MinValue;
        var limit = Min(SearchLimit(data.Expr, Max(today, first), 1), lastDate);
        if (data.Until is not null)
        {
            limit = Min(limit, ResolveUntil(data.Until, today));
        }

        // A fixed time shifted out of a gap at midnight fires on the day after its scheduled date.
        var from = Max(AddDaysWithin(today, -1), first);
        return Search(data, now, location, from, limit, 1);
    }

    /// <summary>
    /// The occurrence nearest to <paramref name="now"/> in the given direction, 1 forward or -1
    /// back, scheduled between <paramref name="from"/> and <paramref name="limit"/>.
    /// </summary>
    private static DateTimeOffset? Search(ScheduleData data, DateTimeOffset now, TimeZoneInfo location, DateOnly from, DateOnly limit, int direction)
    {
        Occurrence? best = null;
        foreach (var date in ScheduledDates(data, from, limit, direction))
        {
            // A time shifted out of a gap lands on the next date, so the date after the nearest
            // hit (before it, searching back) can still hold a nearer occurrence.
            if (best is { } found && direction * (date.DayNumber - found.ScheduledDate.DayNumber) > 1)
            {
                break;
            }
            if (NearestOnDate(data.Expr, date, location, now, direction) is { } t &&
                (best is null || direction * t.CompareTo(best.Value.At) < 0))
            {
                best = new Occurrence(t, date);
            }
        }
        return best?.At;
    }

    private static bool IsSupported(DateTimeOffset t) => t >= EarliestSupported && t < EndOfSupported;

    /// <summary>
    /// The last date to search, <paramref name="direction"/> 1 forward or -1 back. The Gregorian
    /// calendar repeats every 400 years, so a schedule with an interval of n days, weeks, months
    /// or years repeats after lcm(400 years, n of those units), always a whole number of years.
    /// An ISO date is searched for wherever it is.
    /// </summary>
    private static DateOnly SearchLimit(IScheduleExpr expr, DateOnly from, int direction)
    {
        var years = expr switch
        {
            DayRepeat dr => Lcm(GregorianCycleDays, dr.Interval) / GregorianCycleDays * GregorianCycleYears,
            WeekRepeat wr => Lcm(GregorianCycleWeeks, wr.Interval) / GregorianCycleWeeks * GregorianCycleYears,
            MonthRepeat mr => Lcm(GregorianCycleMonths, mr.Interval) / GregorianCycleMonths * GregorianCycleYears,
            YearRepeat yr => Lcm(GregorianCycleYears, yr.Interval),
            SingleDate { DateSpec.Kind: DateSpecKind.Iso } => DateOnly.MaxValue.Year,
            _ => GregorianCycleYears
        };
        var year = from.Year + direction * years;
        if (year > DateOnly.MaxValue.Year)
        {
            return DateOnly.MaxValue;
        }
        if (year < DateOnly.MinValue.Year)
        {
            return DateOnly.MinValue;
        }
        return from.AddYears((int)(year - from.Year));
    }

    /// <summary>
    /// The dates the schedule fires on, from <paramref name="from"/> to <paramref name="limit"/>
    /// inclusive in the given direction, with during and except applied.
    /// </summary>
    private static IEnumerable<DateOnly> ScheduledDates(ScheduleData data, DateOnly from, DateOnly limit, int direction)
    {
        var candidates = data.Expr switch
        {
            DayRepeat dr => DayRepeatDates(dr, data.Anchor, from, limit, direction),
            IntervalRepeat ir => DayRepeatDates(new DayRepeat(1, ir.DayFilter ?? DayFilter.Every(), []), null, from, limit, direction),
            WeekRepeat wr => WeekRepeatDates(wr, data.Anchor, from, limit, direction),
            MonthRepeat mr => MonthRepeatDates(mr, data.Anchor, data.During, from, limit, direction),
            SingleDate sd => SingleDateDates(sd, from, limit, direction),
            YearRepeat yr => YearRepeatDates(yr, data.Anchor, from, limit, direction),
            _ => []
        };
        return candidates
            .SkipWhile(d => direction * d.CompareTo(from) < 0)
            .TakeWhile(d => direction * d.CompareTo(limit) <= 0)
            .Where(d => (data.Expr is MonthRepeat || MatchesDuring(d, data.During)) && !IsExcepted(d, data.Except));
    }

    /// <summary>
    /// The first occurrence on <paramref name="date"/> after <paramref name="now"/>, or searching
    /// back the last one before it.
    /// </summary>
    private static DateTimeOffset? NearestOnDate(IScheduleExpr expr, DateOnly date, TimeZoneInfo location, DateTimeOffset now, int direction)
    {
        bool IsBeyondNow(DateTimeOffset? t) => t is { } instant && direction * instant.CompareTo(now) > 0;

        if (expr is IntervalRepeat ir)
        {
            var (earliest, latest) = WallMinutesWorthResolving(date, now, location, direction);
            return IntervalSlots(ir, earliest, latest, direction)
                .Select(slot => ExistingTimeOnDate(date, slot, location))
                .FirstOrDefault(IsBeyondNow);
        }
        var instants = TimesOf(expr).Select(tod => AtTimeOnDate(date, tod, location)).Where(IsBeyondNow);
        return direction > 0 ? instants.Min() : instants.Max();
    }

    /// <summary>
    /// The wall-clock minutes of <paramref name="date"/> that can hold an occurrence after (or,
    /// searching back, before) <paramref name="now"/>. A wall time w fires at w − o for one of the
    /// day's offsets o, so it is after now only if w &gt; now + min(o) and before now only if
    /// w &lt; now + max(o); resolving the other slots, the costly part, is skipped.
    /// </summary>
    private static (long Earliest, long Latest) WallMinutesWorthResolving(DateOnly date, DateTimeOffset now, TimeZoneInfo location, int direction)
    {
        var midnight = date.ToDateTime(TimeOnly.MinValue).Ticks;
        var before = OffsetAt(midnight - TimeSpan.TicksPerDay, location).Ticks;
        var after = OffsetAt(midnight + 2 * TimeSpan.TicksPerDay, location).Ticks;
        var sinceMidnight = now.UtcTicks - midnight;
        return direction > 0
            ? (FloorDiv(sinceMidnight + Math.Min(before, after), TimeSpan.TicksPerMinute), long.MaxValue)
            : (long.MinValue, -FloorDiv(-(sinceMidnight + Math.Max(before, after)), TimeSpan.TicksPerMinute));
    }

    private static IReadOnlyList<TimeOfDay> TimesOf(IScheduleExpr expr)
    {
        return expr switch
        {
            DayRepeat dr => dr.Times,
            WeekRepeat wr => wr.Times,
            MonthRepeat mr => mr.Times,
            SingleDate sd => sd.Times,
            YearRepeat yr => yr.Times,
            _ => []
        };
    }

    private static IEnumerable<DateOnly> DayRepeatDates(DayRepeat dr, string? anchor, DateOnly from, DateOnly limit, int direction)
    {
        var anchorDay = (anchor is not null ? DateOnly.Parse(anchor) : EpochDate).DayNumber;
        var first = from.DayNumber + direction * FloorMod(direction * (anchorDay - from.DayNumber), dr.Interval);

        for (var day = first; direction * (day - limit.DayNumber) <= 0; day += direction * dr.Interval)
        {
            var date = DateOnly.FromDayNumber((int)day);
            if (MatchesDayFilter(date, dr.Days))
            {
                yield return date;
            }
        }
    }

    private static IEnumerable<DateOnly> WeekRepeatDates(WeekRepeat wr, string? anchor, DateOnly from, DateOnly limit, int direction)
    {
        var anchorMonday = MondayOf(anchor is not null ? DateOnly.Parse(anchor) : EpochMonday).DayNumber;
        var start = MondayOf(from).DayNumber;

        var offsets = wr.WeekDays.Select(w => w.Number() - 1).Order().ToList();
        if (direction < 0)
        {
            offsets.Reverse();
        }
        var step = 7L * wr.Interval;
        var first = start + direction * FloorMod(direction * (anchorMonday - start), step);

        for (var monday = first; direction * (monday - limit.DayNumber) <= 7; monday += direction * step)
        {
            foreach (var offset in offsets)
            {
                var day = monday + offset;
                if (day >= DateOnly.MinValue.DayNumber && day <= DateOnly.MaxValue.DayNumber)
                {
                    yield return DateOnly.FromDayNumber((int)day);
                }
            }
        }
    }

    /// <summary>
    /// Steps through target months, starting one month early (late when searching back) because
    /// a directional nearest weekday can land in the adjacent month.
    /// </summary>
    private static IEnumerable<DateOnly> MonthRepeatDates(MonthRepeat mr, string? anchor, IReadOnlyList<MonthName> during, DateOnly from, DateOnly limit, int direction)
    {
        var anchorMonth = MonthIndex(anchor is not null ? DateOnly.Parse(anchor) : EpochDate);
        var start = MonthIndex(from) - direction;
        var first = start + direction * FloorMod(direction * (anchorMonth - start), mr.Interval);

        for (var month = first; direction * (month - MonthIndex(limit)) <= 1; month += direction * mr.Interval)
        {
            var days = TargetDaysInMonth(month, mr.Target, during);
            foreach (var day in direction > 0 ? days : days.Reverse())
            {
                yield return day;
            }
        }
    }

    /// <summary>
    /// The target days of the month with the given index, if <c>during</c> allows it. DateOnly
    /// cannot hold year 0, but a nearest weekday targeted in December of year 0 can land on
    /// 0001-01-01; the calendar repeats every 400 years, so such a month is taken 400 years
    /// inside and its days moved back (year 10000 is handled the same way for symmetry).
    /// </summary>
    private static IReadOnlyList<DateOnly> TargetDaysInMonth(long monthIndex, MonthTarget target, IReadOnlyList<MonthName> during)
    {
        var shiftYears = monthIndex < MonthIndex(DateOnly.MinValue) ? GregorianCycleYears
            : monthIndex > MonthIndex(DateOnly.MaxValue) ? -GregorianCycleYears
            : 0;
        if (FirstOfMonth(monthIndex + shiftYears * 12) is not { } first || !MatchesDuring(first, during))
        {
            return [];
        }
        var shiftDays = (long)shiftYears / GregorianCycleYears * GregorianCycleDays;
        return GetTargetDaysInMonth(first.Year, first.Month, target)
            .Select(day => day.DayNumber - shiftDays)
            .Where(day => day >= DateOnly.MinValue.DayNumber && day <= DateOnly.MaxValue.DayNumber)
            .Select(day => DateOnly.FromDayNumber((int)day))
            .ToList();
    }

    private static IEnumerable<DateOnly> YearRepeatDates(YearRepeat yr, string? anchor, DateOnly from, DateOnly limit, int direction)
    {
        var anchorYear = (anchor is not null ? DateOnly.Parse(anchor) : EpochDate).Year;
        var first = from.Year + direction * FloorMod(direction * (anchorYear - from.Year), yr.Interval);

        for (var year = first; direction * (year - limit.Year) <= 0; year += direction * yr.Interval)
        {
            if (GetYearTargetDay((int)year, yr.Target) is { } day)
            {
                yield return day;
            }
        }
    }

    private static IEnumerable<DateOnly> SingleDateDates(SingleDate sd, DateOnly from, DateOnly limit, int direction)
    {
        if (sd.DateSpec.Kind == DateSpecKind.Iso)
        {
            yield return DateOnly.Parse(sd.DateSpec.Date!);
            yield break;
        }
        for (var year = from.Year; direction * (year - limit.Year) <= 0; year += direction)
        {
            if (TryCreateDate(year, sd.DateSpec.Month!.Value.Number(), sd.DateSpec.Day) is { } day)
            {
                yield return day;
            }
        }
    }

    /// <summary>
    /// The window's slots whose wall minute is within [earliest, latest], in the given direction.
    /// </summary>
    private static IEnumerable<TimeOfDay> IntervalSlots(IntervalRepeat ir, long earliest, long latest, int direction)
    {
        var step = (long)ir.Interval * (ir.Unit == IntervalUnit.Minutes ? 1 : 60);
        var from = ir.FromTime.TotalMinutes;
        var low = Math.Max(from, earliest);
        var high = Math.Min(ir.ToTime.TotalMinutes, latest);
        if (low > high)
        {
            yield break;
        }
        var first = from + (low - from + step - 1) / step * step;
        var last = from + (high - from) / step * step;
        for (var m = direction > 0 ? first : last; m >= first && m <= last; m += direction * step)
        {
            yield return new TimeOfDay((int)(m / 60), (int)(m % 60));
        }
    }

    private static bool MatchesDayFilter(DateOnly d, DayFilter f)
    {
        var dow = d.DayOfWeek;
        return f.Kind switch
        {
            DayFilterKind.Every => true,
            DayFilterKind.Weekday => dow is >= DayOfWeek.Monday and <= DayOfWeek.Friday,
            DayFilterKind.Weekend => dow is DayOfWeek.Saturday or DayOfWeek.Sunday,
            DayFilterKind.Days => f.Days.Contains(WeekdayExtensions.FromDayOfWeek(dow)),
            _ => false
        };
    }

    private static DateOnly LocalDate(DateTimeOffset t, TimeZoneInfo location)
    {
        return DateOnly.FromDateTime(TimeZoneInfo.ConvertTime(t, location).DateTime);
    }

    private static DateOnly AddDaysWithin(DateOnly date, int days)
    {
        var dayNumber = Math.Clamp((long)date.DayNumber + days, DateOnly.MinValue.DayNumber, DateOnly.MaxValue.DayNumber);
        return DateOnly.FromDayNumber((int)dayNumber);
    }

    private static DateOnly Min(DateOnly a, DateOnly b) => a < b ? a : b;

    private static DateOnly Max(DateOnly a, DateOnly b) => a > b ? a : b;

    private static DateOnly MondayOf(DateOnly date)
    {
        return DateOnly.FromDayNumber(date.DayNumber - (((int)date.DayOfWeek + 6) % 7));
    }

    private static int MonthIndex(DateOnly date) => date.Year * 12 + date.Month - 1;

    private static DateOnly? FirstOfMonth(long monthIndex)
    {
        var year = FloorDiv(monthIndex, 12);
        return year >= DateOnly.MinValue.Year && year <= DateOnly.MaxValue.Year
            ? new DateOnly((int)year, (int)FloorMod(monthIndex, 12) + 1, 1)
            : null;
    }

    private static long FloorMod(long a, long n) => ((a % n) + n) % n;

    private static long FloorDiv(long a, long n) => (a - FloorMod(a, n)) / n;

    private static long Lcm(long a, long b) => a / Gcd(a, b) * b;

    private static long Gcd(long a, long b) => b == 0 ? a : Gcd(b, a % b);

    /// <summary>
    /// The instant a fixed time fires at: the first pass of a repeated wall time, or, in a gap,
    /// the wall time shifted forward by the gap. Null outside the supported range.
    /// </summary>
    private static DateTimeOffset? AtTimeOnDate(DateOnly date, TimeOfDay tod, TimeZoneInfo location)
    {
        var (utcTicks, _) = Resolve(date, tod, location);
        return InstantInRange(utcTicks, location);
    }

    /// <summary>
    /// The instant an interval slot fires at, or null when the slot is in a gap or outside the
    /// supported range.
    /// </summary>
    private static DateTimeOffset? ExistingTimeOnDate(DateOnly date, TimeOfDay tod, TimeZoneInfo location)
    {
        var (utcTicks, inGap) = Resolve(date, tod, location);
        return inGap ? null : InstantInRange(utcTicks, location);
    }

    /// <summary>
    /// Resolves a wall time from UTC offsets, which TimeZoneInfo reports correctly even where
    /// IsInvalidTime and its adjustment rules do not (base-offset changes such as Pyongyang 2018
    /// and Caracas 2016). The wall time exists at wall − o for each offset o around it that is in
    /// force at that instant; with none it is in a gap, shifted by the offset from before it.
    /// Assumes at most one offset change within a day of the wall time, and gaps and overlaps of
    /// at most a day (tzdata 2026c has no transitions closer than about 95 hours).
    /// </summary>
    private static (long UtcTicks, bool InGap) Resolve(DateOnly date, TimeOfDay tod, TimeZoneInfo location)
    {
        var wall = date.ToDateTime(new TimeOnly(tod.Hour, tod.Minute)).Ticks;
        var before = OffsetAt(wall - TimeSpan.TicksPerDay, location);
        var after = OffsetAt(wall + TimeSpan.TicksPerDay, location);
        long? firstPass = null;
        foreach (var offset in new[] { before, after })
        {
            var utc = wall - offset.Ticks;
            if (OffsetAt(utc, location) == offset && (firstPass is null || utc < firstPass))
            {
                firstPass = utc;
            }
        }
        return firstPass is { } ticks ? (ticks, false) : (wall - before.Ticks, true);
    }

    private static TimeSpan OffsetAt(long utcTicks, TimeZoneInfo location)
    {
        var clamped = Math.Clamp(utcTicks, DateTime.MinValue.Ticks, DateTime.MaxValue.Ticks);
        return location.GetUtcOffset(new DateTime(clamped, DateTimeKind.Utc));
    }

    private static DateTimeOffset? InstantInRange(long utcTicks, TimeZoneInfo location)
    {
        if (utcTicks < EarliestSupported.UtcTicks || utcTicks >= EndOfSupported.UtcTicks)
        {
            return null;
        }
        return TimeZoneInfo.ConvertTime(new DateTimeOffset(utcTicks, TimeSpan.Zero), location);
    }

    private static IReadOnlyList<DateOnly> GetTargetDaysInMonth(int year, int month, MonthTarget target)
    {
        return target.Kind switch
        {
            MonthTargetKind.LastDay => [LastDayOfMonth(year, month)],
            MonthTargetKind.LastWeekday => [LastWeekdayOfMonth(year, month)],
            MonthTargetKind.Days => target.ExpandDays()
                .Select(day => TryCreateDate(year, month, day))
                .Where(d => d.HasValue)
                .Select(d => d!.Value)
                .Order()
                .ToList(),
            MonthTargetKind.NearestWeekday =>
                NearestWeekday(year, month, target.NearestWeekdayDay, target.NearestWeekdayDirection) is { } nw
                    ? [nw]
                    : [],
            MonthTargetKind.OrdinalWeekday =>
                NthWeekdayOfMonth(year, month, target.WeekdayValue!.Value, target.OrdinalValue!.Value) is { } ow
                    ? [ow]
                    : [],
            _ => []
        };
    }

    private static DateOnly? NthWeekdayOfMonth(int year, int month, Weekday weekday, OrdinalPosition ordinal)
    {
        if (ordinal == OrdinalPosition.Last)
        {
            return LastWeekdayInMonth(year, month, weekday);
        }

        var firstDow = (int)new DateOnly(year, month, 1).DayOfWeek;
        var day = 1 + ((int)weekday.ToDayOfWeek() - firstDow + 7) % 7 + (ordinal.ToN() - 1) * 7;
        return TryCreateDate(year, month, day);
    }

    private static DateOnly LastDayOfMonth(int year, int month)
    {
        return new DateOnly(year, month, DateTime.DaysInMonth(year, month));
    }

    private static DateOnly LastWeekdayOfMonth(int year, int month)
    {
        var d = LastDayOfMonth(year, month);
        while (d.DayOfWeek is DayOfWeek.Saturday or DayOfWeek.Sunday)
        {
            d = d.AddDays(-1);
        }
        return d;
    }

    private static DateOnly LastWeekdayInMonth(int year, int month, Weekday weekday)
    {
        var targetDow = weekday.ToDayOfWeek();
        var d = LastDayOfMonth(year, month);
        while (d.DayOfWeek != targetDow)
        {
            d = d.AddDays(-1);
        }
        return d;
    }

    /// <summary>
    /// Returns the weekday nearest to targetDay, or null if the month has no such day. A null
    /// direction never leaves the month (cron W); Next and Previous may.
    /// </summary>
    private static DateOnly? NearestWeekday(int year, int month, int targetDay, NearestDirection? direction)
    {
        var last = LastDayOfMonth(year, month);
        var lastDay = last.Day;

        if (targetDay > lastDay)
        {
            return null;
        }

        var date = new DateOnly(year, month, targetDay);
        var dow = date.DayOfWeek;

        if (dow is >= DayOfWeek.Monday and <= DayOfWeek.Friday)
        {
            return date;
        }

        if (dow == DayOfWeek.Saturday)
        {
            return direction switch
            {
                NearestDirection.Next =>
                    date.AddDays(2),
                NearestDirection.Previous =>
                    date.AddDays(-1),
                _ =>
                    targetDay == 1 ? date.AddDays(2) : date.AddDays(-1)
            };
        }

        if (dow == DayOfWeek.Sunday)
        {
            return direction switch
            {
                NearestDirection.Next =>
                    date.AddDays(1),
                NearestDirection.Previous =>
                    date.AddDays(-2),
                _ =>
                    targetDay >= lastDay ? date.AddDays(-2) : date.AddDays(1)
            };
        }

        return date;
    }

    private static DateOnly? GetYearTargetDay(int year, YearTarget target)
    {
        return target.Kind switch
        {
            YearTargetKind.Date => TryCreateDate(year, target.Month.Number(), target.Day),
            YearTargetKind.OrdinalWeekday => NthWeekdayOfMonth(year, target.Month.Number(), target.WeekdayValue!.Value, target.Ordinal!.Value),
            YearTargetKind.DayOfMonth => TryCreateDate(year, target.Month.Number(), target.Day),
            YearTargetKind.LastWeekday => LastWeekdayOfMonth(year, target.Month.Number()),
            _ => null
        };
    }

    private static DateOnly? TryCreateDate(int year, int month, int day)
    {
        return day <= DateTime.DaysInMonth(year, month) ? new DateOnly(year, month, day) : null;
    }

    private static bool IsExcepted(DateOnly d, IReadOnlyList<ExceptionSpec> exceptions)
    {
        foreach (var exc in exceptions)
        {
            switch (exc.Kind)
            {
                case ExceptionSpecKind.Named:
                    if (d.Month == exc.Month!.Value.Number() && d.Day == exc.Day)
                    {
                        return true;
                    }
                    break;
                case ExceptionSpecKind.Iso:
                    var excDate = DateOnly.Parse(exc.Date!);
                    if (d == excDate)
                    {
                        return true;
                    }
                    break;
            }
        }
        return false;
    }

    private static bool MatchesDuring(DateOnly d, IReadOnlyList<MonthName> during)
    {
        if (during.Count == 0)
        {
            return true;
        }
        foreach (var m in during)
        {
            if (d.Month == m.Number())
            {
                return true;
            }
        }
        return false;
    }

    private static DateOnly ResolveUntil(UntilSpec until, DateOnly now)
    {
        return until.Kind switch
        {
            UntilSpecKind.Iso => DateOnly.Parse(until.Date!),
            UntilSpecKind.Named => GetNamedDate(until.Month!.Value.Number(), until.Day, now),
            _ => now
        };
    }

    private static DateOnly GetNamedDate(int month, int day, DateOnly now)
    {
        var d = new DateOnly(now.Year, month, day);
        if (d < now)
        {
            d = now.Year < DateOnly.MaxValue.Year ? new DateOnly(now.Year + 1, month, day) : DateOnly.MaxValue;
        }
        return d;
    }
}
