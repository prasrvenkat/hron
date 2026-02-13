namespace Hron.Ast;

/// <summary>
/// Represents which day(s) within a month a schedule fires on.
/// </summary>
public sealed record MonthTarget(MonthTargetKind Kind, IReadOnlyList<DayOfMonthSpec> Specs)
{
    /// <summary>
    /// Creates a month target for specific days.
    /// </summary>
    public static MonthTarget Days(IReadOnlyList<DayOfMonthSpec> specs) => new(MonthTargetKind.Days, specs);

    /// <summary>
    /// Creates a month target for the last day of the month.
    /// </summary>
    public static MonthTarget LastDay() => new(MonthTargetKind.LastDay, []);

    /// <summary>
    /// Creates a month target for the last weekday of the month.
    /// </summary>
    public static MonthTarget LastWeekday() => new(MonthTargetKind.LastWeekday, []);

    /// <summary>
    /// Returns all days specified by this target (for DAYS kind only).
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
    /// <summary>Specific days of the month.</summary>
    Days,
    /// <summary>The last day of the month.</summary>
    LastDay,
    /// <summary>The last weekday (Mon-Fri) of the month.</summary>
    LastWeekday
}
