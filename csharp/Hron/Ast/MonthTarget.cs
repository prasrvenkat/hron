namespace Hron.Ast;

/// <summary>
/// Direction for nearest weekday (hron extension beyond cron W).
/// </summary>
public enum NearestDirection
{
    /// <summary>Always prefer following weekday (can cross to next month).</summary>
    Next,
    /// <summary>Always prefer preceding weekday (can cross to prev month).</summary>
    Previous
}

/// <summary>
/// Represents which day(s) within a month a schedule fires on.
/// </summary>
public sealed record MonthTarget(
    MonthTargetKind Kind,
    IReadOnlyList<DayOfMonthSpec> Specs,
    int NearestWeekdayDay = 0,
    NearestDirection? NearestWeekdayDirection = null,
    OrdinalPosition? OrdinalValue = null,
    Weekday? WeekdayValue = null)
{
    public static MonthTarget Days(IReadOnlyList<DayOfMonthSpec> specs) =>
        new(MonthTargetKind.Days, specs);

    public static MonthTarget LastDay() =>
        new(MonthTargetKind.LastDay, []);

    public static MonthTarget LastWeekday() =>
        new(MonthTargetKind.LastWeekday, []);

    /// <summary>
    /// Creates a month target for the nearest weekday to a given day.
    /// </summary>
    /// <param name="day">The target day of month (1-31).</param>
    /// <param name="direction">Optional direction preference (null for standard cron W behavior).</param>
    public static MonthTarget NearestWeekday(int day, NearestDirection? direction = null) =>
        new(MonthTargetKind.NearestWeekday, [], day, direction);

    public static MonthTarget OrdinalWeekday(OrdinalPosition ordinal, Weekday weekday) =>
        new(MonthTargetKind.OrdinalWeekday, [], OrdinalValue: ordinal, WeekdayValue: weekday);

    /// <summary>
    /// Returns all days specified by this target, or an empty list unless Kind is Days.
    /// </summary>
    public IReadOnlyList<int> ExpandDays()
    {
        if (Kind != MonthTargetKind.Days)
        {
            return [];
        }

        var days = new List<int>();
        foreach (var spec in Specs)
        {
            days.AddRange(spec.Expand());
        }
        return days;
    }
}

/// <summary>
/// The type of month target.
/// </summary>
public enum MonthTargetKind
{
    Days,
    LastDay,
    /// <summary>The last weekday (Mon-Fri) of the month.</summary>
    LastWeekday,
    /// <summary>Nearest weekday to a given day of the month.</summary>
    NearestWeekday,
    /// <summary>Ordinal weekday of month (e.g., first monday, last friday).</summary>
    OrdinalWeekday
}
