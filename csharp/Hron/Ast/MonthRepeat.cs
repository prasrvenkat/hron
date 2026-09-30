namespace Hron.Ast;

/// <summary>
/// An expression that fires on certain days of the month, every month or every N months.
/// </summary>
/// <param name="Interval">The number of months between occurrences (1 for every month)</param>
/// <param name="Target">The day(s) within the month to fire</param>
/// <param name="Times">The times of day to fire</param>
public sealed record MonthRepeat(int Interval, MonthTarget Target, IReadOnlyList<TimeOfDay> Times) : IScheduleExpr;
