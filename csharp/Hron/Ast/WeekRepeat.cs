namespace Hron.Ast;

/// <summary>
/// An expression that fires on named days of the week, every week or every N weeks.
/// </summary>
/// <param name="Interval">The number of weeks between occurrences</param>
/// <param name="WeekDays">The days of the week to fire</param>
/// <param name="Times">The times of day to fire</param>
public sealed record WeekRepeat(int Interval, IReadOnlyList<Weekday> WeekDays, IReadOnlyList<TimeOfDay> Times) : IScheduleExpr;
