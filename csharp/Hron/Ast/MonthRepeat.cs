namespace Hron.Ast;

public sealed record MonthRepeat(int Interval, MonthTarget Target, IReadOnlyList<TimeOfDay> Times) : IScheduleExpr;
