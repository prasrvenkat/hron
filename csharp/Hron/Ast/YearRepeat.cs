namespace Hron.Ast;

internal sealed record YearRepeat(int Interval, YearTarget Target, IReadOnlyList<TimeOfDay> Times) : IScheduleExpr;
