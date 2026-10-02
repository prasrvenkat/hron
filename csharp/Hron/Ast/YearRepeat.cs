namespace Hron.Ast;

public sealed record YearRepeat(int Interval, YearTarget Target, IReadOnlyList<TimeOfDay> Times) : IScheduleExpr
{
    public int Interval { get; } = Interval;

    public YearTarget Target { get; } = Target;

    public IReadOnlyList<TimeOfDay> Times { get; } = PartList<TimeOfDay>.Of(Times);
}
