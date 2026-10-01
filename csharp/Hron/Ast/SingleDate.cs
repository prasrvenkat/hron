namespace Hron.Ast;

public sealed record SingleDate(DateSpec DateSpec, IReadOnlyList<TimeOfDay> Times) : IScheduleExpr;
