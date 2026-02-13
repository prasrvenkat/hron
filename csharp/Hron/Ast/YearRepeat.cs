namespace Hron.Ast;

/// <summary>
/// A year-based repeat expression like "every year on dec 25 at 00:00".
/// </summary>
/// <param name="Interval">The number of years between occurrences (1 for every year)</param>
/// <param name="Target">The day within the year to fire</param>
/// <param name="Times">The times of day to fire</param>
public sealed record YearRepeat(int Interval, YearTarget Target, IReadOnlyList<TimeOfDay> Times) : IScheduleExpr;
