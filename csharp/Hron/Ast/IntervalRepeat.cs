namespace Hron.Ast;

/// <summary>
/// <c>DayFilter</c> is the days the window applies on, or null for every day.
/// </summary>
public sealed record IntervalRepeat(
    int Interval,
    IntervalUnit Unit,
    TimeOfDay FromTime,
    TimeOfDay ToTime,
    DayFilter? DayFilter) : IScheduleExpr
{
    public int Interval { get; } = Interval;

    public IntervalUnit Unit { get; } = Unit;

    public TimeOfDay FromTime { get; } = FromTime;

    public TimeOfDay ToTime { get; } = ToTime;

    public DayFilter? DayFilter { get; } = DayFilter;
}
