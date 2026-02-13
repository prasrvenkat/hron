namespace Hron.Ast;

/// <summary>
/// Represents a filter for which days a schedule applies to.
/// </summary>
public sealed record DayFilter(DayFilterKind Kind, IReadOnlyList<Weekday> Days)
{
    /// <summary>
    /// Creates a filter that matches every day.
    /// </summary>
    public static DayFilter Every() => new(DayFilterKind.Every, []);

    /// <summary>
    /// Creates a filter that matches weekdays (Mon-Fri).
    /// </summary>
    public static DayFilter Weekday() => new(DayFilterKind.Weekday, []);

    /// <summary>
    /// Creates a filter that matches weekends (Sat-Sun).
    /// </summary>
    public static DayFilter Weekend() => new(DayFilterKind.Weekend, []);

    /// <summary>
    /// Creates a filter that matches specific days.
    /// </summary>
    public static DayFilter SpecificDays(IReadOnlyList<Weekday> days) => new(DayFilterKind.Days, days);
}

/// <summary>
/// The type of day filter.
/// </summary>
public enum DayFilterKind
{
    /// <summary>Matches every day.</summary>
    Every,
    /// <summary>Matches weekdays (Monday-Friday).</summary>
    Weekday,
    /// <summary>Matches weekend days (Saturday-Sunday).</summary>
    Weekend,
    /// <summary>Matches specific days of the week.</summary>
    Days
}
