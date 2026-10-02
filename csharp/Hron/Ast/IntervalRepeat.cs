namespace Hron.Ast;

/// <param name="DayFilter">The days the window applies on, or null for every day</param>
internal sealed record IntervalRepeat(
    int Interval,
    IntervalUnit Unit,
    TimeOfDay FromTime,
    TimeOfDay ToTime,
    DayFilter? DayFilter) : IScheduleExpr;
