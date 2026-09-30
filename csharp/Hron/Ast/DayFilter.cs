namespace Hron.Ast;

/// <summary>
/// Represents a filter for which days a schedule applies to.
/// </summary>
public sealed record DayFilter(DayFilterKind Kind, IReadOnlyList<Weekday> Days)
{
    public static DayFilter Every() => new(DayFilterKind.Every, []);

    public static DayFilter Weekday() => new(DayFilterKind.Weekday, []);

    public static DayFilter Weekend() => new(DayFilterKind.Weekend, []);

    public static DayFilter SpecificDays(IReadOnlyList<Weekday> days) => new(DayFilterKind.Days, days);
}

/// <summary>
/// The type of day filter.
/// </summary>
public enum DayFilterKind
{
    Every,
    /// <summary>Matches weekdays (Monday-Friday).</summary>
    Weekday,
    /// <summary>Matches weekend days (Saturday-Sunday).</summary>
    Weekend,
    Days
}
