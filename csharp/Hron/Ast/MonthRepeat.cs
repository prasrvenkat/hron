namespace Hron.Ast;

public sealed record MonthRepeat(int Interval, MonthTarget Target, IReadOnlyList<TimeOfDay> Times) : IScheduleExpr
{
    public int Interval { get; } = Interval;

    public MonthTarget Target { get; } = Target;

    public IReadOnlyList<TimeOfDay> Times { get; } = PartList<TimeOfDay>.Of(Times);
}
