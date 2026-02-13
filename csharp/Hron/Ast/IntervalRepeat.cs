namespace Hron.Ast;

/// <summary>
/// An interval-based repeat expression like "every 30 min from 09:00 to 17:00".
/// </summary>
/// <param name="Interval">The interval value</param>
/// <param name="Unit">The interval unit (minutes or hours)</param>
/// <param name="FromTime">The start time of the daily window</param>
/// <param name="ToTime">The end time of the daily window</param>
/// <param name="DayFilter">Optional day filter to restrict which days apply</param>
public sealed record IntervalRepeat(
    int Interval,
    IntervalUnit Unit,
    TimeOfDay FromTime,
    TimeOfDay ToTime,
    DayFilter? DayFilter) : IScheduleExpr;
