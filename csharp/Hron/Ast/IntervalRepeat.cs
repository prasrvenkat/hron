namespace Hron.Ast;

/// <summary>
/// An expression that fires every N minutes or hours within a daily window.
/// </summary>
/// <param name="Interval">The interval value</param>
/// <param name="Unit">The interval unit (minutes or hours)</param>
/// <param name="FromTime">The start time of the daily window</param>
/// <param name="ToTime">The end time of the daily window</param>
/// <param name="DayFilter">The days the window applies on, or null for every day</param>
public sealed record IntervalRepeat(
    int Interval,
    IntervalUnit Unit,
    TimeOfDay FromTime,
    TimeOfDay ToTime,
    DayFilter? DayFilter) : IScheduleExpr;
