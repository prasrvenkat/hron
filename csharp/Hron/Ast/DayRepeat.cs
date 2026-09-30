namespace Hron.Ast;

/// <summary>
/// An expression that fires every day or every N days, optionally only on certain days.
/// </summary>
/// <param name="Interval">The number of days between occurrences (1 for every day)</param>
/// <param name="Days">The day filter (every, weekday, weekend, or specific days)</param>
/// <param name="Times">The times of day to fire</param>
public sealed record DayRepeat(int Interval, DayFilter Days, IReadOnlyList<TimeOfDay> Times) : IScheduleExpr;
