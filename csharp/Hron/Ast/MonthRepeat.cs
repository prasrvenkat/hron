namespace Hron.Ast;

internal sealed record MonthRepeat(int Interval, MonthTarget Target, IReadOnlyList<TimeOfDay> Times) : IScheduleExpr;
