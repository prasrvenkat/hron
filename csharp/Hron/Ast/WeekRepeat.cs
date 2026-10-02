namespace Hron.Ast;

internal sealed record WeekRepeat(int Interval, IReadOnlyList<Weekday> WeekDays, IReadOnlyList<TimeOfDay> Times) : IScheduleExpr;
