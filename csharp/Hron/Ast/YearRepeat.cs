namespace Hron.Ast;

public sealed record YearRepeat(int Interval, YearTarget Target, IReadOnlyList<TimeOfDay> Times) : IScheduleExpr;
