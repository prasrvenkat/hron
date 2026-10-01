namespace Hron.Ast;

public sealed record WeekRepeat(int Interval, IReadOnlyList<Weekday> WeekDays, IReadOnlyList<TimeOfDay> Times) : IScheduleExpr;
