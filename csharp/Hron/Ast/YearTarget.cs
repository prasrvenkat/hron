namespace Hron.Ast;

/// <summary>
/// Represents which day within a year a schedule fires on.
/// </summary>
public sealed record YearTarget(
    YearTargetKind Kind,
    MonthName Month,
    int Day,
    OrdinalPosition? Ordinal,
    Weekday? WeekdayValue)
{
    /// <summary>
    /// Creates a year target for a specific month and day.
    /// </summary>
    public static YearTarget Date(MonthName month, int day)
        => new(YearTargetKind.Date, month, day, null, null);

    /// <summary>
    /// Creates a year target for an ordinal weekday in a month.
    /// </summary>
    public static YearTarget OrdinalWeekday(OrdinalPosition ordinal, Weekday weekday, MonthName month)
        => new(YearTargetKind.OrdinalWeekday, month, 0, ordinal, weekday);

    /// <summary>
    /// Creates a year target for a specific day of a month.
    /// </summary>
    public static YearTarget DayOfMonth(int day, MonthName month)
        => new(YearTargetKind.DayOfMonth, month, day, null, null);

    /// <summary>
    /// Creates a year target for the last weekday of a month.
    /// </summary>
    public static YearTarget LastWeekday(MonthName month)
        => new(YearTargetKind.LastWeekday, month, 0, null, null);
}

/// <summary>
/// The type of year target.
/// </summary>
public enum YearTargetKind
{
    /// <summary>A specific month and day (e.g., dec 25).</summary>
    Date,
    /// <summary>An ordinal weekday in a month (e.g., first monday of march).</summary>
    OrdinalWeekday,
    /// <summary>A specific day of a month (e.g., the 15th of march).</summary>
    DayOfMonth,
    /// <summary>The last weekday of a month.</summary>
    LastWeekday
}
