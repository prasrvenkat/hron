namespace Hron.Ast;

/// <summary>
/// A day-based repeat expression like "every day at 9:00" or "every 3 days at 09:00".
/// </summary>
/// <param name="Interval">The number of days between occurrences (1 for every day)</param>
/// <param name="Days">The day filter (every, weekday, weekend, or specific days)</param>
/// <param name="Times">The times of day to fire</param>
public sealed record DayRepeat(int Interval, DayFilter Days, IReadOnlyList<TimeOfDay> Times) : IScheduleExpr;
