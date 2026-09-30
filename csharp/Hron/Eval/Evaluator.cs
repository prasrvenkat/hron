using Hron.Ast;

namespace Hron.Eval;

/// <summary>
/// Evaluates schedule expressions to compute occurrences.
/// </summary>
/// <remarks>
/// Each occurrence has a scheduled date, the date whose times it fires at, and every clause
/// (day filter, during, except, until) applies to that date. A fixed time that falls in a DST gap
/// shifts forward by the length of the gap, possibly onto the next date, and keeps its scheduled
/// date; an interval slot in a gap is skipped. A time that occurs twice at fall-back resolves to
/// the first occurrence only. Searches cover one full repeat of the calendar and the schedule's
/// interval, within years 1 to 9999.
/// </remarks>
public static class Evaluator
{
    private const int GregorianCycleYears = 400;
    private const int GregorianCycleMonths = GregorianCycleYears * 12;
    private const int GregorianCycleDays = 146097;
    private const int GregorianCycleWeeks = GregorianCycleDays / 7;

    private static readonly DateOnly EpochDate = new(1970, 1, 1);

    private static readonly DateOnly EpochMonday = new(1970, 1, 5);

    private readonly record struct Occurrence(DateTimeOffset At, DateOnly ScheduledDate);

    /// <summary>
    /// Computes the next occurrence strictly after the given time.
    /// </summary>
    public static DateTimeOffset? NextFrom(ScheduleData data, DateTimeOffset now, TimeZoneInfo location)
    {
        var today = LocalDate(now, location);
        var limit = SearchLimit(data.Expr, today, 1);
        if (data.Until is not null)
        {
            limit = Min(limit, ResolveUntil(data.Until, today));
        }

        // A fixed time shifted out of a gap at midnight fires on the day after its scheduled date;
        // interval slots in a gap are skipped instead.
        var from = data.Expr is IntervalRepeat ? today : AddDaysWithin(today, -1);
        Occurrence? best = null;
        foreach (var date in ScheduledDates(data, from, limit, 1))
        {
            if (best is { } found && date.DayNumber > found.ScheduledDate.DayNumber + 1)
            {
                break;
            }
            if (FirstOnDateAfter(data.Expr, date, location, now) is { } t && (best is null || t < best.Value.At))
            {
                best = new Occurrence(t, date);
            }
        }
        return best?.At;
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
    /// Returns a lazy enumerable of occurrences where from &lt; occurrence &lt;= to.
    /// </summary>
    public static IEnumerable<DateTimeOffset> Between(ScheduleData data, DateTimeOffset from, DateTimeOffset to, TimeZoneInfo location)
    {
        return Occurrences(data, from, location).TakeWhile(dt => dt <= to);
    }

    /// <summary>
    /// Computes the most recent occurrence strictly before the given time.
    /// </summary>
    public static DateTimeOffset? PreviousFrom(ScheduleData data, DateTimeOffset now, TimeZoneInfo location)
    {
        var today = LocalDate(now, location);
        var limit = SearchLimit(data.Expr, today, -1);
        if (data.Anchor is not null)
        {
            limit = Max(limit, DateOnly.Parse(data.Anchor));
        }
        var from = data.Until is not null ? Min(today, ResolveUntil(data.Until, today)) : today;

        Occurrence? best = null;
        foreach (var date in ScheduledDates(data, from, limit, -1))
        {
            // A later time on the day before can shift past this date's own times.
            if (best is { } found && date.DayNumber < found.ScheduledDate.DayNumber - 1)
            {
                break;
            }
            if (LastOnDateBefore(data.Expr, date, location, now) is { } t && (best is null || t > best.Value.At))
            {
                best = new Occurrence(t, date);
            }
        }
        return best?.At;
    }

    /// <summary>
    /// Checks if the minute containing a datetime is an occurrence of the schedule.
    /// </summary>
    public static bool Matches(ScheduleData data, DateTimeOffset dt, TimeZoneInfo location)
    {
        var minute = TimeZoneInfo.ConvertTime(dt.AddTicks(-(dt.UtcTicks % TimeSpan.TicksPerMinute)), location);
        var date = DateOnly.FromDateTime(minute.DateTime);
        return IsScheduledAt(data, date, minute, location) ||
            (date > DateOnly.MinValue && IsScheduledAt(data, date.AddDays(-1), minute, location));
    }

    private static bool IsScheduledAt(ScheduleData data, DateOnly date, DateTimeOffset minute, TimeZoneInfo location)
    {
        if (data.Expr is not MonthRepeat && !MatchesDuring(date, data.During))
        {
            return false;
        }

        if (IsExcepted(date, data.Except))
        {
            return false;
        }

        if (data.Until is not null && date > ResolveUntil(data.Until, date))
        {
            return false;
        }

        return data.Expr switch
        {
            DayRepeat dr => MatchesDayRepeat(dr, date, minute, location, data.Anchor),
            IntervalRepeat ir => MatchesIntervalRepeat(ir, date, minute, location),
            WeekRepeat wr => MatchesWeekRepeat(wr, date, minute, location, data.Anchor),
            MonthRepeat mr => MatchesMonthRepeat(mr, date, minute, location, data.Anchor, data.During),
            SingleDate sd => MatchesSingleDate(sd, date, minute, location),
            YearRepeat yr => MatchesYearRepeat(yr, date, minute, location, data.Anchor),
            _ => false
        };
    }

    /// <summary>
    /// Compares instants, so a time shifted out of a DST gap matches and the second pass of a
    /// repeated time does not.
    /// </summary>
    private static bool AnyTimeResolvesTo(DateOnly date, IReadOnlyList<TimeOfDay> times, TimeZoneInfo location, DateTimeOffset dt)
    {
        return times.Any(tod => AtTimeOnDate(date, tod, location) == dt);
    }

    private static bool MatchesDayRepeat(DayRepeat dr, DateOnly date, DateTimeOffset dt, TimeZoneInfo location, string? anchor)
    {
        var anchorDate = anchor is not null ? DateOnly.Parse(anchor) : EpochDate;
        return MatchesDayFilter(date, dr.Days) &&
            AnyTimeResolvesTo(date, dr.Times, location, dt) &&
            (dr.Interval == 1 || IsAligned(date.DayNumber - anchorDate.DayNumber, dr.Interval, anchor));
    }

    private static bool MatchesIntervalRepeat(IntervalRepeat ir, DateOnly date, DateTimeOffset dt, TimeZoneInfo location)
    {
        if (ir.DayFilter is not null && !MatchesDayFilter(date, ir.DayFilter))
        {
            return false;
        }
        var wallTime = new TimeOfDay(dt.Hour, dt.Minute);
        var sinceFrom = wallTime.TotalMinutes - ir.FromTime.TotalMinutes;
        return sinceFrom >= 0 &&
            wallTime.TotalMinutes <= ir.ToTime.TotalMinutes &&
            sinceFrom % IntervalStepMinutes(ir) == 0 &&
            AtTimeOnDate(date, wallTime, location) == dt;
    }

    private static bool MatchesWeekRepeat(WeekRepeat wr, DateOnly date, DateTimeOffset dt, TimeZoneInfo location, string? anchor)
    {
        var anchorMonday = MondayOf(anchor is not null ? DateOnly.Parse(anchor) : EpochMonday);
        var weeks = FloorDiv(MondayOf(date).DayNumber - anchorMonday.DayNumber, 7);
        return wr.WeekDays.Contains(WeekdayExtensions.FromDayOfWeek(date.DayOfWeek)) &&
            AnyTimeResolvesTo(date, wr.Times, location, dt) &&
            IsAligned(weeks, wr.Interval, anchor);
    }

    /// <summary>
    /// A directional nearest weekday can land in the month before or after its target month, and
    /// interval alignment and <c>during</c> apply to the target month.
    /// </summary>
    private static bool MatchesMonthRepeat(MonthRepeat mr, DateOnly date, DateTimeOffset dt, TimeZoneInfo location, string? anchor, IReadOnlyList<MonthName> during)
    {
        if (!AnyTimeResolvesTo(date, mr.Times, location, dt))
        {
            return false;
        }
        var anchorMonth = MonthIndex(anchor is not null ? DateOnly.Parse(anchor) : EpochDate);
        var landingMonth = MonthIndex(date);
        for (var month = landingMonth - 1; month <= landingMonth + 1; month++)
        {
            if (FirstOfMonth(month) is { } first &&
                (mr.Interval == 1 || IsAligned(month - anchorMonth, mr.Interval, anchor)) &&
                MatchesDuring(first, during) &&
                GetTargetDaysInMonth(first.Year, first.Month, mr.Target).Contains(date))
            {
                return true;
            }
        }
        return false;
    }

    /// <summary>
    /// Offsets before the 1970 epoch align backwards (floor); nothing before a starting date aligns.
    /// </summary>
    private static bool IsAligned(long offset, int interval, string? anchor)
    {
        return FloorMod(offset, interval) == 0 && (anchor is null || offset >= 0);
    }

    private static bool MatchesSingleDate(SingleDate sd, DateOnly date, DateTimeOffset dt, TimeZoneInfo location)
    {
        if (!AnyTimeResolvesTo(date, sd.Times, location, dt))
        {
            return false;
        }
        return sd.DateSpec.Kind switch
        {
            DateSpecKind.Iso => date == DateOnly.Parse(sd.DateSpec.Date!),
            DateSpecKind.Named => date.Month == sd.DateSpec.Month!.Value.Number() && date.Day == sd.DateSpec.Day,
            _ => false
        };
    }

    private static bool MatchesYearRepeat(YearRepeat yr, DateOnly date, DateTimeOffset dt, TimeZoneInfo location, string? anchor)
    {
        var anchorYear = anchor is not null ? DateOnly.Parse(anchor).Year : EpochDate.Year;
        return AnyTimeResolvesTo(date, yr.Times, location, dt) &&
            (yr.Interval == 1 || IsAligned(date.Year - anchorYear, yr.Interval, anchor)) &&
            GetYearTargetDay(date.Year, yr.Target) == date;
    }

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

    private static DateTimeOffset? FirstOnDateAfter(IScheduleExpr expr, DateOnly date, TimeZoneInfo location, DateTimeOffset now)
    {
        if (expr is IntervalRepeat ir)
        {
            var earliest = WallMinuteOn(date, now, location);
            return IntervalSlots(ir)
                .Where(slot => slot.TotalMinutes >= earliest)
                .Select(slot => ExistingTimeOnDate(date, slot, location))
                .FirstOrDefault(t => t > now);
        }
        return TimesOf(expr).Select(tod => AtTimeOnDate(date, tod, location)).Where(t => t > now).Min();
    }

    private static DateTimeOffset? LastOnDateBefore(IScheduleExpr expr, DateOnly date, TimeZoneInfo location, DateTimeOffset now)
    {
        if (expr is IntervalRepeat ir)
        {
            var latest = WallMinuteOn(date, now, location) + (HasTransition(date, location) ? OverlapMarginMinutes : 0);
            return IntervalSlots(ir)
                .Reverse()
                .Where(slot => slot.TotalMinutes <= latest)
                .Select(slot => ExistingTimeOnDate(date, slot, location))
                .FirstOrDefault(t => t < now);
        }
        return TimesOf(expr).Select(tod => AtTimeOnDate(date, tod, location)).Where(t => t < now).Max();
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
        if (direction > 0 && anchor is not null && start < anchorMonday)
        {
            start = anchorMonday;
        }

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
            if (FirstOfMonth(month) is not { } firstDay || !MatchesDuring(firstDay, during))
            {
                continue;
            }
            var days = GetTargetDaysInMonth(firstDay.Year, firstDay.Month, mr.Target);
            foreach (var day in direction > 0 ? days : days.Reverse())
            {
                yield return day;
            }
        }
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

    private static IEnumerable<TimeOfDay> IntervalSlots(IntervalRepeat ir)
    {
        for (var m = ir.FromTime.TotalMinutes; m <= ir.ToTime.TotalMinutes; m += IntervalStepMinutes(ir))
        {
            yield return new TimeOfDay(m / 60, m % 60);
        }
    }

    // Slots are skipped by wall-clock minute before resolving them, which is the costly part.
    // A slot with an earlier wall time is always an earlier instant (gap slots are skipped and
    // overlap slots take their first pass), but on a transition day a later wall time can be an
    // earlier instant, so looking back keeps a margin wider than any overlap (at most two hours,
    // Antarctica/Troll).
    private const int OverlapMarginMinutes = 180;

    private static bool HasTransition(DateOnly date, TimeZoneInfo location)
    {
        var start = new DateTimeOffset(date.ToDateTime(TimeOnly.MinValue), TimeSpan.Zero);
        return location.GetUtcOffset(start.AddDays(-1)) != location.GetUtcOffset(start.AddDays(2));
    }

    private static int WallMinuteOn(DateOnly date, DateTimeOffset now, TimeZoneInfo location)
    {
        var local = TimeZoneInfo.ConvertTime(now, location).DateTime;
        var nowDate = DateOnly.FromDateTime(local);
        if (date == nowDate)
        {
            return local.Hour * 60 + local.Minute;
        }
        return date < nowDate ? int.MaxValue / 2 : int.MinValue / 2;
    }

    private static int IntervalStepMinutes(IntervalRepeat ir) => ir.Interval * (ir.Unit == IntervalUnit.Minutes ? 1 : 60);

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

    private static DateTimeOffset? ExistingTimeOnDate(DateOnly date, TimeOfDay tod, TimeZoneInfo location)
    {
        var wallTime = date.ToDateTime(new TimeOnly(tod.Hour, tod.Minute));
        return location.IsInvalidTime(wallTime) ? null : AtTimeOnDate(date, tod, location);
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
    /// Creates a DateTimeOffset at the given date and time in the given timezone, or null if that
    /// instant is outside the range DateTimeOffset supports.
    /// Handles DST: spring forward pushes non-existent times forward by the gap duration.
    /// </summary>
    private static DateTimeOffset? AtTimeOnDate(DateOnly date, TimeOfDay tod, TimeZoneInfo location)
    {
        var dt = new DateTime(date.Year, date.Month, date.Day, tod.Hour, tod.Minute, 0, DateTimeKind.Unspecified);

        if (location.IsInvalidTime(dt))
        {
            // TimeZoneInfo doesn't expose the gap itself; the adjustment rule's DaylightDelta is its length.
            var adjustmentRules = location.GetAdjustmentRules();
            TimeSpan gapDuration = TimeSpan.FromHours(1); // fallback

            foreach (var rule in adjustmentRules)
            {
                if (rule.DateStart <= dt && dt <= rule.DateEnd)
                {
                    gapDuration = rule.DaylightDelta;
                    if (gapDuration < TimeSpan.Zero)
                    {
                        gapDuration = -gapDuration;
                    }
                    break;
                }
            }

            dt = dt.Add(gapDuration);
        }

        // For ambiguous times (DST fall back), use the earlier offset (first occurrence)
        var offset = location.GetUtcOffset(dt);
        if (location.IsAmbiguousTime(dt))
        {
            var offsets = location.GetAmbiguousTimeOffsets(dt);
            offset = offsets.Max(); // Earlier time uses larger offset
        }

        var utcTicks = dt.Ticks - offset.Ticks;
        if (utcTicks < DateTimeOffset.MinValue.UtcTicks || utcTicks > DateTimeOffset.MaxValue.UtcTicks)
        {
            return null;
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
