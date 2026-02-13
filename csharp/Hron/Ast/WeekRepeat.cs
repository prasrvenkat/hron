namespace Hron.Ast;

/// <summary>
/// A week-based repeat expression like "every 2 weeks on monday at 9:00".
/// </summary>
/// <param name="Interval">The number of weeks between occurrences</param>
/// <param name="WeekDays">The days of the week to fire</param>
/// <param name="Times">The times of day to fire</param>
public sealed record WeekRepeat(int Interval, IReadOnlyList<Weekday> WeekDays, IReadOnlyList<TimeOfDay> Times) : IScheduleExpr;
