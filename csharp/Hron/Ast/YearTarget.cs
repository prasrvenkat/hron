namespace Hron.Ast;

/// <summary>
/// <c>Kind</c> says which fields hold the target besides <c>Month</c>: <c>Day</c> for
/// <see cref="YearTargetKind.Date"/> and <see cref="YearTargetKind.DayOfMonth"/>; <c>Ordinal</c> and
/// <c>WeekdayValue</c> for <see cref="YearTargetKind.OrdinalWeekday"/>; none for
/// <see cref="YearTargetKind.LastWeekday"/>. The fields the kind does not use are 0 or null.
/// </summary>
public sealed record YearTarget(
    YearTargetKind Kind,
    MonthName Month,
    int Day,
    OrdinalPosition? Ordinal,
    Weekday? WeekdayValue)
{
    public YearTargetKind Kind { get; } = Kind;

    public MonthName Month { get; } = Month;

    public int Day { get; } = Day;

    public OrdinalPosition? Ordinal { get; } = Ordinal;

    public Weekday? WeekdayValue { get; } = WeekdayValue;

    internal static YearTarget Date(MonthName month, int day)
        => new(YearTargetKind.Date, month, day, null, null);

    internal static YearTarget OrdinalWeekday(OrdinalPosition ordinal, Weekday weekday, MonthName month)
        => new(YearTargetKind.OrdinalWeekday, month, 0, ordinal, weekday);

    internal static YearTarget DayOfMonth(int day, MonthName month)
        => new(YearTargetKind.DayOfMonth, month, day, null, null);

    internal static YearTarget LastWeekday(MonthName month)
        => new(YearTargetKind.LastWeekday, month, 0, null, null);
}

public enum YearTargetKind
{
    /// <summary>A specific month and day (e.g., dec 25).</summary>
    Date,
    OrdinalWeekday,
    /// <summary>A specific day of a month (e.g., the 15th of march).</summary>
    DayOfMonth,
    LastWeekday
}
