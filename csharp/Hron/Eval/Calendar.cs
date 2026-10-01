using Hron.Ast;

namespace Hron.Eval;

/// <summary>
/// Date arithmetic on the proleptic Gregorian calendar: no time zones, no schedules.
/// </summary>
internal static class Calendar
{
    public const int DaysPer400Years = 146097;

    public const int MonthsPer400Years = 400 * 12;

    public static DateOnly? FromDayNumber(long dayNumber)
    {
        return dayNumber >= DateOnly.MinValue.DayNumber && dayNumber <= DateOnly.MaxValue.DayNumber
            ? DateOnly.FromDayNumber((int)dayNumber)
            : null;
    }

    public static DateOnly? AddDays(DateOnly date, long days) => FromDayNumber(date.DayNumber + days);

    public static DateOnly? FirstOfYear(long year)
    {
        return year >= DateOnly.MinValue.Year && year <= DateOnly.MaxValue.Year ? new DateOnly((int)year, 1, 1) : null;
    }

    /// <summary>
    /// Months since January of year 0.
    /// </summary>
    public static int MonthIndex(DateOnly date) => date.Year * 12 + date.Month - 1;

    /// <summary>
    /// The month, 1 to 12, of the month <paramref name="monthIndex"/> months after January of year 0.
    /// </summary>
    public static int MonthOf(long monthIndex) => (int)FloorMod(monthIndex, 12) + 1;

    public static DateOnly? FirstOfMonth(long monthIndex)
    {
        return FirstOfYear(FloorDiv(monthIndex, 12))?.AddMonths(MonthOf(monthIndex) - 1);
    }

    public static DateOnly MondayOf(DateOnly date)
    {
        return DateOnly.FromDayNumber(date.DayNumber - ((int)date.DayOfWeek + 6) % 7);
    }

    public static DateOnly? TryCreateDate(int year, int month, int day)
    {
        return day <= DateTime.DaysInMonth(year, month) ? new DateOnly(year, month, day) : null;
    }

    public static bool MatchesDayFilter(DateOnly date, DayFilter filter) => filter.Kind switch
    {
        DayFilterKind.Every => true,
        DayFilterKind.Weekday => !IsWeekend(date),
        DayFilterKind.Weekend => IsWeekend(date),
        DayFilterKind.Days => filter.Days.Contains(WeekdayExtensions.FromDayOfWeek(date.DayOfWeek)),
        _ => false
    };

    /// <summary>
    /// The dates a monthly target names in the month <paramref name="monthIndex"/>, earliest first.
    /// DateOnly cannot hold year 0, yet a nearest weekday in its December can land on 0001-01-01;
    /// the calendar repeats every 400 years, so a month of year 0 is taken 400 years later and its
    /// dates moved back.
    /// </summary>
    public static IReadOnlyList<DateOnly> MonthTargetDates(long monthIndex, MonthTarget target)
    {
        var shifted = monthIndex < MonthIndex(DateOnly.MinValue);
        if (FirstOfMonth(shifted ? monthIndex + MonthsPer400Years : monthIndex) is not { } first)
        {
            return [];
        }
        var (year, month) = (first.Year, first.Month);
        var dates = target.Kind switch
        {
            MonthTargetKind.Days => DaysOfMonth(year, month, target),
            MonthTargetKind.LastDay => [LastDayOfMonth(year, month)],
            MonthTargetKind.LastWeekday => [LastWeekdayOfMonth(year, month)],
            MonthTargetKind.NearestWeekday => NearestWeekday(year, month, target.NearestWeekdayDay, target.NearestWeekdayDirection) is { } date ? [date] : [],
            MonthTargetKind.OrdinalWeekday => OrdinalWeekday(year, month, target.OrdinalValue!.Value, target.WeekdayValue!.Value) is { } date ? [date] : [],
            _ => []
        };
        if (!shifted)
        {
            return dates;
        }
        return dates.Select(date => AddDays(date, -DaysPer400Years)).OfType<DateOnly>().ToList();
    }

    public static DateOnly? YearTargetDate(int year, YearTarget target) => target.Kind switch
    {
        YearTargetKind.Date or YearTargetKind.DayOfMonth => TryCreateDate(year, target.Month.Number(), target.Day),
        YearTargetKind.OrdinalWeekday => OrdinalWeekday(year, target.Month.Number(), target.Ordinal!.Value, target.WeekdayValue!.Value),
        YearTargetKind.LastWeekday => LastWeekdayOfMonth(year, target.Month.Number()),
        _ => null
    };

    public static long FloorMod(long a, long n) => ((a % n) + n) % n;

    public static long FloorDiv(long a, long n) => (a - FloorMod(a, n)) / n;

    private static bool IsWeekend(DateOnly date) => date.DayOfWeek is DayOfWeek.Saturday or DayOfWeek.Sunday;

    private static List<DateOnly> DaysOfMonth(int year, int month, MonthTarget target)
    {
        var dates = new List<DateOnly>();
        foreach (var day in target.ExpandDays())
        {
            if (TryCreateDate(year, month, day) is { } date)
            {
                dates.Add(date);
            }
        }
        dates.Sort();
        return dates;
    }

    private static DateOnly LastDayOfMonth(int year, int month)
    {
        return new DateOnly(year, month, DateTime.DaysInMonth(year, month));
    }

    /// <summary>
    /// The last Monday to Friday of a month.
    /// </summary>
    private static DateOnly LastWeekdayOfMonth(int year, int month)
    {
        var last = LastDayOfMonth(year, month);
        return last.AddDays(last.DayOfWeek switch
        {
            DayOfWeek.Saturday => -1,
            DayOfWeek.Sunday => -2,
            _ => 0
        });
    }

    private static DateOnly? OrdinalWeekday(int year, int month, OrdinalPosition ordinal, Weekday weekday)
    {
        var target = (int)weekday.ToDayOfWeek();
        if (ordinal == OrdinalPosition.Last)
        {
            var last = LastDayOfMonth(year, month);
            return last.AddDays(-(((int)last.DayOfWeek - target + 7) % 7));
        }
        var first = (int)new DateOnly(year, month, 1).DayOfWeek;
        return TryCreateDate(year, month, 1 + (target - first + 7) % 7 + (ordinal.ToN() - 1) * 7);
    }

    /// <summary>
    /// The weekday nearest <paramref name="day"/> of a month, or null when the month is shorter.
    /// Without a direction it stays in the month, as cron's W does; with one it can cross into the
    /// adjacent month (spec/README.md, "Nearest weekday and `during`").
    /// </summary>
    private static DateOnly? NearestWeekday(int year, int month, int day, NearestDirection? toward)
    {
        if (TryCreateDate(year, month, day) is not { } date)
        {
            return null;
        }
        return date.AddDays((date.DayOfWeek, toward) switch
        {
            (DayOfWeek.Saturday, NearestDirection.Next) => 2,
            (DayOfWeek.Saturday, NearestDirection.Previous) => -1,
            (DayOfWeek.Saturday, null) when day == 1 => 2,
            (DayOfWeek.Saturday, null) => -1,
            (DayOfWeek.Sunday, NearestDirection.Next) => 1,
            (DayOfWeek.Sunday, NearestDirection.Previous) => -2,
            (DayOfWeek.Sunday, null) when day == DateTime.DaysInMonth(year, month) => -2,
            (DayOfWeek.Sunday, null) => 1,
            _ => 0
        });
    }
}
