using Hron.Ast;

namespace Hron.Eval;

/// <summary>
/// Evaluates schedule expressions to compute next occurrences.
/// </summary>
public static class Evaluator
{
    /// <summary>Maximum iterations to prevent infinite loops.</summary>
    private const int MaxIterations = 1000;

    /// <summary>Epoch date for day/month/year alignment.</summary>
    private static readonly DateOnly EpochDate = new(1970, 1, 1);

    /// <summary>Epoch Monday for week alignment.</summary>
    private static readonly DateOnly EpochMonday = new(1970, 1, 5);

    /// <summary>
    /// Computes the next occurrence after the given time.
    /// </summary>
    public static DateTimeOffset? NextFrom(ScheduleData data, DateTimeOffset now, TimeZoneInfo location)
    {
        for (var i = 0; i < MaxIterations; i++)
        {
            var candidate = NextCandidate(data.Expr, now, location, data.Anchor);
            if (candidate is null)
            {
                return null;
            }

            var t = candidate.Value;

            // Apply modifiers
            // Check exception list
            if (IsExcepted(DateOnly.FromDateTime(t.DateTime), data.Except))
            {
                now = t;
                continue;
            }

            // Check until date
            if (data.Until is not null)
            {
                var untilDate = ResolveUntil(data.Until, DateOnly.FromDateTime(now.DateTime));
                if (DateOnly.FromDateTime(t.DateTime) > untilDate)
                {
                    return null;
                }
            }

            // Check during clause
            if (!MatchesDuring(DateOnly.FromDateTime(t.DateTime), data.During))
            {
                // Skip to next month that matches
                var nextMonth = NextDuringMonth(DateOnly.FromDateTime(t.DateTime), data.During);
                now = AtTimeOnDate(nextMonth, new TimeOfDay(0, 0), location).AddTicks(-1);
                continue;
            }

            return t;
        }

        return null;
    }

    /// <summary>
    /// Computes the next n occurrences after the given time.
    /// </summary>
    public static IReadOnlyList<DateTimeOffset> NextNFrom(ScheduleData data, DateTimeOffset now, int n, TimeZoneInfo location)
    {
        var results = new List<DateTimeOffset>(n);
        var current = now;

        for (var i = 0; i < n && i < MaxIterations; i++)
        {
            var next = NextFrom(data, current, location);
            if (next is null)
            {
                break;
            }
            results.Add(next.Value);
            current = next.Value;
        }

        return results;
    }

    /// <summary>
    /// Checks if a datetime matches the schedule.
    /// </summary>
    public static bool Matches(ScheduleData data, DateTimeOffset dt, TimeZoneInfo location)
    {
        // Check slightly before to see if the next occurrence is at dt
        var beforeDt = dt.AddTicks(-1);
        var next = NextFrom(data, beforeDt, location);
        return next.HasValue && next.Value == dt;
    }

    private static DateTimeOffset? NextCandidate(IScheduleExpr expr, DateTimeOffset now, TimeZoneInfo location, string? anchor)
    {
        return expr switch
        {
            DayRepeat dr => NextDayRepeat(dr, now, location, anchor),
            IntervalRepeat ir => NextIntervalRepeat(ir, now, location),
            WeekRepeat wr => NextWeekRepeat(wr, now, location, anchor),
            MonthRepeat mr => NextMonthRepeat(mr, now, location, anchor),
            OrdinalRepeat or => NextOrdinalRepeat(or, now, location, anchor),
            SingleDate sd => NextSingleDate(sd, now, location),
            YearRepeat yr => NextYearRepeat(yr, now, location, anchor),
            _ => null
        };
    }

    private static DateTimeOffset? NextDayRepeat(DayRepeat dr, DateTimeOffset now, TimeZoneInfo location, string? anchor)
    {
        var anchorDate = anchor is not null ? DateOnly.Parse(anchor) : EpochDate;
        var day = DateOnly.FromDateTime(now.DateTime);

        for (var i = 0; i < MaxIterations; i++)
        {
            if (dr.Interval > 1)
            {
                // Check alignment
                var daysFromAnchor = day.DayNumber - anchorDate.DayNumber;
                var mod = daysFromAnchor % dr.Interval;
                if (mod < 0) mod += dr.Interval;
                if (mod != 0)
                {
                    day = day.AddDays(dr.Interval - mod);
                    continue;
                }
            }

            if (MatchesDayFilter(day, dr.Days))
            {
                var time = EarliestFutureTime(day, dr.Times, location, now);
                if (time.HasValue)
                {
                    return time;
                }
            }

            day = day.AddDays(dr.Interval > 1 ? dr.Interval : 1);
        }

        return null;
    }

    private static DateTimeOffset? NextIntervalRepeat(IntervalRepeat ir, DateTimeOffset now, TimeZoneInfo location)
    {
        var day = DateOnly.FromDateTime(now.DateTime);

        for (var i = 0; i < MaxIterations; i++)
        {
            if (ir.DayFilter is not null && !MatchesDayFilter(day, ir.DayFilter))
            {
                day = day.AddDays(1);
                continue;
            }

            var fromMinutes = ir.FromTime.TotalMinutes;
            var toMinutes = ir.ToTime.TotalMinutes;

            // Iterate through the window
            var step = ir.Interval * (ir.Unit == IntervalUnit.Minutes ? 1 : 60);
            for (var m = fromMinutes; m <= toMinutes; m += step)
            {
                var hour = m / 60;
                var minute = m % 60;
                var t = AtTimeOnDate(day, new TimeOfDay(hour, minute), location);

                if (t > now)
                {
                    return t;
                }
            }

            day = day.AddDays(1);
        }

        return null;
    }

    private static DateTimeOffset? NextWeekRepeat(WeekRepeat wr, DateTimeOffset now, TimeZoneInfo location, string? anchor)
    {
        var anchorDate = anchor is not null ? DateOnly.Parse(anchor) : EpochMonday;
        // Find Monday of anchor date
        var anchorMonday = anchorDate.AddDays(-((int)anchorDate.DayOfWeek == 0 ? 6 : (int)anchorDate.DayOfWeek - 1));

        var day = DateOnly.FromDateTime(now.DateTime);
        // Find Monday of current week
        var currentMonday = day.AddDays(-((int)day.DayOfWeek == 0 ? 6 : (int)day.DayOfWeek - 1));

        // Sort target weekdays for earliest-first matching
        var sortedDays = wr.WeekDays.OrderBy(w => w.Number()).ToList();

        for (var i = 0; i < 54; i++)
        {
            var daysBetween = currentMonday.DayNumber - anchorMonday.DayNumber;
            var weeks = daysBetween / 7;

            // Skip weeks before anchor
            if (weeks < 0)
            {
                var skip = (-weeks + wr.Interval - 1) / wr.Interval;
                currentMonday = currentMonday.AddDays((int)(skip * wr.Interval * 7));
                continue;
            }

            if (weeks % wr.Interval == 0)
            {
                // Aligned week - try each target weekday
                foreach (var wd in sortedDays)
                {
                    var dayOffset = wd.Number() - 1; // Monday=1, so offset = 0 for Monday
                    var targetDate = currentMonday.AddDays(dayOffset);
                    var time = EarliestFutureTime(targetDate, wr.Times, location, now);
                    if (time.HasValue)
                    {
                        return time;
                    }
                }
            }

            // Skip to next aligned week
            var remainder = weeks % wr.Interval;
            var skipWeeks = wr.Interval;
            if (remainder != 0)
            {
                skipWeeks = (int)(wr.Interval - remainder);
            }
            currentMonday = currentMonday.AddDays(skipWeeks * 7);
        }

        return null;
    }

    private static DateTimeOffset? NextMonthRepeat(MonthRepeat mr, DateTimeOffset now, TimeZoneInfo location, string? anchor)
    {
        var anchorDate = anchor is not null ? DateOnly.Parse(anchor) : EpochDate;
        var day = DateOnly.FromDateTime(now.DateTime);

        for (var i = 0; i < MaxIterations; i++)
        {
            // Check month alignment
            if (mr.Interval > 1)
            {
                var monthsFromAnchor = (day.Year - anchorDate.Year) * 12 + (day.Month - anchorDate.Month);
                var mod = monthsFromAnchor % mr.Interval;
                if (mod < 0) mod += mr.Interval;
                if (mod != 0)
                {
                    day = new DateOnly(day.Year, day.Month, 1).AddMonths(mr.Interval - mod);
                    continue;
                }
            }

            // Get target days for this month
            var targetDays = GetTargetDaysInMonth(day.Year, day.Month, mr.Target);

            foreach (var targetDay in targetDays)
            {
                if (targetDay < day) continue;

                var time = EarliestFutureTime(targetDay, mr.Times, location, now);
                if (time.HasValue)
                {
                    return time;
                }
            }

            // Move to next month
            day = new DateOnly(day.Year, day.Month, 1).AddMonths(mr.Interval > 1 ? mr.Interval : 1);
        }

        return null;
    }

    private static DateTimeOffset? NextOrdinalRepeat(OrdinalRepeat or, DateTimeOffset now, TimeZoneInfo location, string? anchor)
    {
        var anchorDate = anchor is not null ? DateOnly.Parse(anchor) : EpochDate;
        var day = DateOnly.FromDateTime(now.DateTime);

        for (var i = 0; i < MaxIterations; i++)
        {
            // Check month alignment
            if (or.Interval > 1)
            {
                var monthsFromAnchor = (day.Year - anchorDate.Year) * 12 + (day.Month - anchorDate.Month);
                var mod = monthsFromAnchor % or.Interval;
                if (mod < 0) mod += or.Interval;
                if (mod != 0)
                {
                    day = new DateOnly(day.Year, day.Month, 1).AddMonths(or.Interval - mod);
                    continue;
                }
            }

            // Find the ordinal weekday in this month
            var targetDay = NthWeekdayOfMonth(day.Year, day.Month, or.WeekdayValue, or.Ordinal);

            if (targetDay.HasValue && targetDay.Value >= day)
            {
                var time = EarliestFutureTime(targetDay.Value, or.Times, location, now);
                if (time.HasValue)
                {
                    return time;
                }
            }

            // Move to next month
            day = new DateOnly(day.Year, day.Month, 1).AddMonths(or.Interval > 1 ? or.Interval : 1);
        }

        return null;
    }

    private static DateTimeOffset? NextSingleDate(SingleDate sd, DateTimeOffset now, TimeZoneInfo location)
    {
        var startYear = now.Year;

        switch (sd.DateSpec.Kind)
        {
            case DateSpecKind.Iso:
                var d = DateOnly.Parse(sd.DateSpec.Date!);
                return EarliestFutureTime(d, sd.Times, location, now);

            case DateSpecKind.Named:
                for (var y = 0; y < 8; y++)
                {
                    var year = startYear + y;
                    var date = TryCreateDate(year, sd.DateSpec.Month!.Value.Number(), sd.DateSpec.Day);
                    // Skip invalid dates (e.g., Feb 30)
                    if (date is null)
                    {
                        continue;
                    }
                    var time = EarliestFutureTime(date.Value, sd.Times, location, now);
                    if (time.HasValue)
                    {
                        return time;
                    }
                }
                return null;

            default:
                return null;
        }
    }

    private static DateTimeOffset? NextYearRepeat(YearRepeat yr, DateTimeOffset now, TimeZoneInfo location, string? anchor)
    {
        var anchorDate = anchor is not null ? DateOnly.Parse(anchor) : EpochDate;
        var year = now.Year;

        for (var i = 0; i < MaxIterations; i++)
        {
            // Check year alignment
            if (yr.Interval > 1)
            {
                var yearsFromAnchor = year - anchorDate.Year;
                var mod = yearsFromAnchor % yr.Interval;
                if (mod < 0) mod += yr.Interval;
                if (mod != 0)
                {
                    year += yr.Interval - mod;
                    continue;
                }
            }

            var targetDay = GetYearTargetDay(year, yr.Target);

            if (targetDay.HasValue)
            {
                var day = targetDay.Value;
                if (day >= DateOnly.FromDateTime(now.DateTime))
                {
                    var time = EarliestFutureTime(day, yr.Times, location, now);
                    if (time.HasValue)
                    {
                        return time;
                    }
                }
            }

            year += yr.Interval > 1 ? yr.Interval : 1;
        }

        return null;
    }

    // Helper methods

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

    private static DateTimeOffset? EarliestFutureTime(DateOnly day, IReadOnlyList<TimeOfDay> times, TimeZoneInfo location, DateTimeOffset now)
    {
        DateTimeOffset? best = null;
        foreach (var tod in times)
        {
            var candidate = AtTimeOnDate(day, tod, location);
            if (candidate > now)
            {
                if (best is null || candidate < best)
                {
                    best = candidate;
                }
            }
        }
        return best;
    }

    /// <summary>
    /// Creates a DateTimeOffset at the given date and time in the given timezone.
    /// Handles DST: spring forward pushes non-existent times forward by the gap duration.
    /// </summary>
    private static DateTimeOffset AtTimeOnDate(DateOnly date, TimeOfDay tod, TimeZoneInfo location)
    {
        var dt = new DateTime(date.Year, date.Month, date.Day, tod.Hour, tod.Minute, 0, DateTimeKind.Unspecified);

        // Check if the time is invalid (DST gap)
        if (location.IsInvalidTime(dt))
        {
            // Push forward by the DST gap duration (typically 1 hour)
            // This preserves the minutes component: 02:30 -> 03:30
            dt = dt.AddHours(1);
        }

        // For ambiguous times (DST fall back), use the earlier offset (first occurrence)
        var offset = location.GetUtcOffset(dt);
        if (location.IsAmbiguousTime(dt))
        {
            var offsets = location.GetAmbiguousTimeOffsets(dt);
            offset = offsets.Max(); // Earlier time uses larger offset
        }

        return new DateTimeOffset(dt, offset);
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
                .ToList(),
            _ => []
        };
    }

    private static DateOnly? NthWeekdayOfMonth(int year, int month, Weekday weekday, OrdinalPosition ordinal)
    {
        if (ordinal == OrdinalPosition.Last)
        {
            return LastWeekdayInMonth(year, month, weekday);
        }

        var n = ordinal.ToN();
        var targetDow = weekday.ToDayOfWeek();

        var d = new DateOnly(year, month, 1);
        while (d.DayOfWeek != targetDow)
        {
            d = d.AddDays(1);
        }

        d = d.AddDays((n - 1) * 7);

        if (d.Month != month)
        {
            return null;
        }

        return d;
    }

    private static DateOnly LastDayOfMonth(int year, int month)
    {
        return new DateOnly(year, month, 1).AddMonths(1).AddDays(-1);
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
        try
        {
            return new DateOnly(year, month, day);
        }
        catch (ArgumentOutOfRangeException)
        {
            return null;
        }
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

    private static DateOnly NextDuringMonth(DateOnly d, IReadOnlyList<MonthName> during)
    {
        var currentMonth = d.Month;

        // Sort months
        var months = during.Select(m => m.Number()).OrderBy(m => m).ToList();

        // Find next month after current
        foreach (var m in months)
        {
            if (m > currentMonth)
            {
                return new DateOnly(d.Year, m, 1);
            }
        }

        // Wrap to first month of next year
        return new DateOnly(d.Year + 1, months[0], 1);
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
            d = new DateOnly(now.Year + 1, month, day);
        }
        return d;
    }
}
