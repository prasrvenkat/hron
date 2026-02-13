namespace Hron.Ast;

/// <summary>
/// A single-date expression like "on feb 14 at 9:00" or "on 2026-03-15 at 14:30".
/// </summary>
/// <param name="DateSpec">The date specification</param>
/// <param name="Times">The times of day to fire</param>
public sealed record SingleDate(DateSpec DateSpec, IReadOnlyList<TimeOfDay> Times) : IScheduleExpr;
