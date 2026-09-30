namespace Hron.Ast;

/// <summary>
/// An expression that fires on one date.
/// </summary>
/// <param name="DateSpec">The date specification</param>
/// <param name="Times">The times of day to fire</param>
public sealed record SingleDate(DateSpec DateSpec, IReadOnlyList<TimeOfDay> Times) : IScheduleExpr;
