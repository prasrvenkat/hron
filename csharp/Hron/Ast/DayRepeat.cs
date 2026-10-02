namespace Hron.Ast;

internal sealed record DayRepeat(int Interval, DayFilter Days, IReadOnlyList<TimeOfDay> Times) : IScheduleExpr;
