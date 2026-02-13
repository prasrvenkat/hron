namespace Hron.Ast;

/// <summary>
/// A month-based repeat expression like "every month on the 1st at 9:00".
/// </summary>
/// <param name="Interval">The number of months between occurrences (1 for every month)</param>
/// <param name="Target">The day(s) within the month to fire</param>
/// <param name="Times">The times of day to fire</param>
public sealed record MonthRepeat(int Interval, MonthTarget Target, IReadOnlyList<TimeOfDay> Times) : IScheduleExpr;
