namespace Hron.Ast;

public sealed record DayRepeat(int Interval, DayFilter Days, IReadOnlyList<TimeOfDay> Times) : IScheduleExpr;
