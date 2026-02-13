namespace Hron.Ast;

/// <summary>
/// An ordinal-based repeat expression like "first monday of every month at 10:00".
/// </summary>
/// <param name="Interval">The number of months between occurrences (1 for every month)</param>
/// <param name="Ordinal">The ordinal position (first, second, ..., last)</param>
/// <param name="WeekdayValue">The day of the week</param>
/// <param name="Times">The times of day to fire</param>
public sealed record OrdinalRepeat(
    int Interval,
    OrdinalPosition Ordinal,
    Weekday WeekdayValue,
    IReadOnlyList<TimeOfDay> Times) : IScheduleExpr;
