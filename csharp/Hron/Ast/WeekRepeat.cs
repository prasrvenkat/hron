namespace Hron.Ast;

public sealed record WeekRepeat(int Interval, IReadOnlyList<Weekday> WeekDays, IReadOnlyList<TimeOfDay> Times) : IScheduleExpr
{
    public int Interval { get; } = Interval;

    public IReadOnlyList<Weekday> WeekDays { get; } = PartList<Weekday>.Of(WeekDays);

    public IReadOnlyList<TimeOfDay> Times { get; } = PartList<TimeOfDay>.Of(Times);
}
