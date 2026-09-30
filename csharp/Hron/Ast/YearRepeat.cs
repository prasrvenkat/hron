namespace Hron.Ast;

/// <summary>
/// An expression that fires on one day of the year, every year or every N years.
/// </summary>
/// <param name="Interval">The number of years between occurrences (1 for every year)</param>
/// <param name="Target">The day within the year to fire</param>
/// <param name="Times">The times of day to fire</param>
public sealed record YearRepeat(int Interval, YearTarget Target, IReadOnlyList<TimeOfDay> Times) : IScheduleExpr;
