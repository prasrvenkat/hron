namespace Hron.Ast;

internal sealed record SingleDate(DateSpec DateSpec, IReadOnlyList<TimeOfDay> Times) : IScheduleExpr;
